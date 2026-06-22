import Foundation
import os

/// 直播态唯一收口（B 里程碑 spec §2）。
///
/// 收敛副作用：心跳 / 强制下播 / 网络监控 / 相机错误 / 美颜可用性 / 公屏在线人数 / 折扣池标记。
/// View 只读 `@Published`，业务逻辑全部在本 Store。
///
/// **M1/M2 已接入**：心跳 + 下播 CAS + 优先级仲裁 + 网络监控 + 相机错误 + 美颜降级 + token 续期。
/// **M3 待接入**：NIM 公屏 attachType 分发；M4 完整 startLive 三接口串行。
@MainActor
final class LiveStore: ObservableObject {
    // ─── 状态 ───────────────────────────────────────
    @Published private(set) var state: LiveState = .idle
    @Published private(set) var callState: Int = 0     // 0 直播 / 1 通话 / 2 匹配 / 3 PK；阶段一恒为 0
    @Published private(set) var endType: Int?          // 仅 ended 态有值

    // ─── 房间上下文（attachLiving/startLive 阶段填充）────────────
    @Published private(set) var roomId: Int?
    @Published private(set) var agoraChannelId: String?
    @Published private(set) var rtcToken: String?
    @Published private(set) var yxRoomId: Int?

    // ─── 公屏/合规/折扣 字段（NIMChatroomManager 通过 §12 入口写入；M3 接入）
    @Published private(set) var onlineCount: Int = 0
    @Published private(set) var warningToast: String?
    @Published private(set) var boostingExposure: Bool = false

    // ─── 网络弱网提示（M2 v5 NetworkQualityMonitor 分层降级触发）
    @Published private(set) var networkWarningToast: String?

    // ─── 调试用：网络监控实时计数（v5.1 显示到 LiveRoomView 调试面板）
    @Published private(set) var networkDebugInfo = NetworkDebugInfo()

    // ─── 美颜可用性（§6 fallback；M2 接入）─────
    @Published private(set) var beautyAvailable: Bool = true

    // ─── 权限拒绝对外提示（M2 接入）─────────────
    @Published var permissionDeniedAlert: Bool = false

    // ─── D 里程碑：通话挂断后回直播倒计时（15s，对齐 H5 liveRoom.vue:220）─
    @Published private(set) var isWaitingReturnLive: Bool = false
    @Published private(set) var returnLiveCountdown: Int = 0

    // ─── 监控内部状态 ────────────────────────────
    private var cameraFailureStartedAt: Date?
    private var cameraFailureWatcher: Task<Void, Never>?
    private var warningToastClearTask: Task<Void, Never>?
    /// D 里程碑：waitingReturnLive 倒计时 task。下播/再次进入 D 流程必须 cancel 防幽灵 rejoin。
    private var returnLiveTask: Task<Void, Never>?

    // ─── 并发原子标志（§2.5 同步 CAS）───────────
    private var inFlightEnd: Bool = false

    // ─── 子模块（lazy 避免 init 内 self 循环）───
    private lazy var heartbeat: HeartbeatController = HeartbeatController(store: self)
    private lazy var monitor: NetworkQualityMonitor = NetworkQualityMonitor(store: self)

    /// D 里程碑跨会话过渡占位（B 会话临时加，B build 不被 D 阻塞）。
    /// D-spec 最终采用 **weak ref 对齐 AgoraManager.liveStore 模式**（见 `CallStore.swift:50-52` 注释），
    /// `CallStore.swift:L435/L437` 的 `LiveStore.shared.*` 引用是 D-spec 早期草案，**待 D 会话清理**。
    /// ⚠️ 本 shared 与 LiveRoomView 内 @StateObject 持有的 store 是不同对象——`.state == .living` 检查永远 false，
    /// 安全副作用：L435 条件永远不成立，CallStore 走 L443+ 的 weak ref 流程。
    static let shared = LiveStore()

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveStore")

    init() {}
}

// MARK: - 生命周期入口（spec §2.4）

extension LiveStore {
    /// idle → preparing。LivePrepareView 启动 onAppear 调用。
    func prepare() {
        guard state == .idle else { return }
        state = .preparing
    }

    /// M1 临时入口：LiveRoomView 接力 LivePrepareView 已建立的房间，启动心跳 + 网络监控。
    /// M4 重构：startLive 内部完整三接口串行后删除本入口。
    func attachLiving(roomInfo: LiveRoomInfo) {
        guard state == .idle || state == .preparing else {
            logger.warning("attachLiving ignored in state=\(String(describing: self.state))")
            return
        }
        self.roomId = roomInfo.id
        self.agoraChannelId = roomInfo.agoraChannelId
        self.rtcToken = roomInfo.rtcToken
        self.yxRoomId = roomInfo.yxRoomId
        self.state = .living
        heartbeat.start()
        monitor.start()
        logger.info("attachLiving roomId=\(roomInfo.id ?? -1)")
    }

    /// 注入 AgoraManager + CameraManager 双向引用：
    /// - agora.liveStore = self（token 续期失败回调）
    /// - agora.networkMonitor = monitor（networkQuality 转发）
    /// - monitor.agora / monitor.camera（v5.1 降级时同时切 agora 编码档位 + camera 推帧节流）
    func wire(_ agora: AgoraManager, camera: CameraManager? = nil) {
        agora.liveStore = self
        agora.networkMonitor = monitor
        monitor.agora = agora
        monitor.camera = camera
    }

    /// preparing → starting → living。M4 完整实现。
    func startLive(title: String) async {
        // TODO(M4): spec §8.2 + §14 任务 11；M1 用 attachLiving 替代
        logger.warning("LiveStore.startLive not implemented yet (M4); use attachLiving")
    }

    /// living → ending → ended(endType=1)。LiveRoomView 点结束直播调用。
    func endLive() async {
        guard tryEnterEnding() else { return }
        do {
            try await LiveService.endLiveRoom(endType: 1)
        } catch {
            logger.error("endLiveRoom failed during endLive: \(String(describing: error))")
        }
        await teardown()
        state = .ended
        endType = 1
        UserDefaults.standard.set(Date(), forKey: "lastEndAt")  // §8.3 用
    }
}

// MARK: - 强制下播 + 同步 CAS + 优先级仲裁（spec §2.5 + §2.5b）

extension LiveStore {
    func forceEnd(reason: ForceEndReason, subSource: String? = nil) async {
        let sub = subSource ?? "-"
        logger.info("forceEnd request reason=\(String(describing: reason)) sub=\(sub)")
        guard tryEnterForceEnding(reason) else { return }
        do {
            try await LiveService.endLiveRoom(endType: reason.code)
        } catch {
            logger.error("endLiveRoom failed during forceEnd: \(String(describing: error))")
        }
        await teardown()
        state = .ended
        endType = reason.code
    }

    private func tryEnterForceEnding(_ reason: ForceEndReason) -> Bool {
        if inFlightEnd {
            if case .forceEnding(let current) = state,
               reason.priority > current.priority {
                state = .forceEnding(reason: reason)
                endType = reason.code
                logger.info("forceEnd reason upgraded: \(String(describing: current)) → \(String(describing: reason))（接口不重发）")
            }
            return false
        }
        switch state {
        case .living:
            inFlightEnd = true
            state = .forceEnding(reason: reason)
            return true
        case .starting:
            state = .idle
            return false
        default:
            return false
        }
    }

    private func tryEnterEnding() -> Bool {
        guard !inFlightEnd, case .living = state else { return false }
        inFlightEnd = true
        state = .ending
        return true
    }

    private func teardown() async {
        heartbeat.stop()
        monitor.stop()
        cameraFailureWatcher?.cancel()
        cameraFailureWatcher = nil
        cameraFailureStartedAt = nil
        warningToastClearTask?.cancel()
        warningToastClearTask = nil
        // D 里程碑：清理倒计时 task + 字段复位，防止 endLive 后倒计时仍触发 rejoin
        returnLiveTask?.cancel()
        returnLiveTask = nil
        isWaitingReturnLive = false
        returnLiveCountdown = 0
        callState = 0
    }
}

// MARK: - NIMChatroomManager 调用入口（spec §12 契约；M3 接入）

extension LiveStore {
    func warn(message: String) {
        warningToast = message
        warningToastClearTask?.cancel()
        warningToastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.warningToast = nil }
        }
    }

    func markBoostingExposure(_ enabled: Bool) {
        boostingExposure = enabled
    }

    func setOnlineCount(_ count: Int) {
        onlineCount = max(0, count)
    }

    func adjustOnlineCount(by delta: Int) {
        onlineCount = max(0, onlineCount + delta)
    }

    /// NetworkQualityMonitor 调用：弱网降级时写文案；恢复时传 nil 清空。
    func setNetworkWarning(_ text: String?) {
        networkWarningToast = text
    }

    /// v5.1：NetworkQualityMonitor 每次 report 后调用更新调试信息（LiveRoomView 调试面板实时显示）
    func updateNetworkDebug(_ block: (inout NetworkDebugInfo) -> Void) {
        var info = networkDebugInfo
        block(&info)
        networkDebugInfo = info
    }

    /// D 里程碑跨会话过渡 stub（B 会话临时；待 D 会话清理 CallStore.swift L435/L437）。
    /// 真实实现见 D-spec §X（D 会话权限）。
    func pauseForCall(msg: CallMessage) async {
        logger.warning("LiveStore.pauseForCall called via shared stub (CallStore L437 过渡代码), no-op")
    }
}

// MARK: - 美颜/相机错误回调入口（CameraManager / BeautyRenderer 调用；M2）

extension LiveStore {
    /// CameraManager 错误回调入口（spec §5.3）。
    /// - permissionDenied：立即弹 alert + 中止 starting
    /// - sessionRuntimeError / wasInterrupted：启动 20s watcher
    /// - interruptionEnded：清零 watcher
    func onCameraError(_ error: CameraManager.CameraError) {
        switch error {
        case .permissionDenied:
            permissionDeniedAlert = true
            if case .starting = state { state = .idle }
        case .sessionRuntimeError, .wasInterrupted:
            startCameraFailureWatcher()
        case .interruptionEnded:
            stopCameraFailureWatcher()
        }
    }

    private func startCameraFailureWatcher() {
        guard cameraFailureStartedAt == nil else { return }
        cameraFailureStartedAt = Date()
        cameraFailureWatcher = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // 仍未恢复 → forceEnd 采集失败（spec §11 endType=5）
            await MainActor.run {
                guard self.cameraFailureStartedAt != nil else { return }
                Task { await self.forceEnd(reason: .cameraFailure, subSource: "camera_runtime_20s") }
            }
        }
    }

    private func stopCameraFailureWatcher() {
        cameraFailureStartedAt = nil
        cameraFailureWatcher?.cancel()
        cameraFailureWatcher = nil
    }

    /// FaceUnity setup 失败时由 CameraManager 调用（spec §6.2）。
    func markBeautyUnavailable() {
        beautyAvailable = false
        logger.error("Beauty fallback to passthrough")
    }
}

// MARK: - 状态字段写入（D/G 里程碑调用）

extension LiveStore {
    func setCallState(_ value: Int) {
        guard state == .living else { return }
        callState = value
    }
}

// MARK: - D 里程碑：通话挂断回直播 stub（M2 完整实现）

extension LiveStore {
    /// 通话挂断后由 CallStoreObserver 回调触发，启动 15s 倒计时回直播。
    /// **M2 T3 填充完整实现**：
    ///   1) isWaitingReturnLive=true + returnLiveCountdown=15
    ///   2) 15s 倒计时（每秒 -1，可取消）
    ///   3) rejoinLiveChannel() 用保留的 channelId+rtcToken 重 join
    ///   4) heartbeat.start() / monitor.start() / callState=0 / WSHeartbeat.notifyCallStateChanged(0)
    func resumeCall() async {
        // TODO(M2-T3)：完整实现 spec §3.3
        logger.warning("LiveStore.resumeCall called (M1 stub; M2 will implement)")
    }
}
