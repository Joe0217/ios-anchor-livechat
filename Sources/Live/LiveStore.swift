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
    // 独立 ObservableObject，避免高频（2s/次）写触发 LiveRoomView 整树重渲染。
    // 仅 DebugNetworkPanel 订阅 networkDebugStore；LiveStore 自身不再 @Published 持有。
    let networkDebugStore = NetworkDebugStore()

    // ─── 直播时长计时器（M1 起，原在 LiveRoomView 内 Timer.publish + @State 驱动）
    // 独立 ObservableObject 隔离 1Hz 高频 @Published 写；attachLiving 启动 / teardown 停止。
    let elapsedTimerStore = LiveTimerStore()

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

    /// G 里程碑 spec §3.5：PKStore 通过本访问器订阅 NQM `$currentLevel` 拦截 forceEnd 改切 .pkLow。
    /// 仅暴露读取，避免外部替换 monitor 实例。
    var networkMonitor: NetworkQualityMonitor { monitor }

    /// D 里程碑新增：直播 RTC 实例的 weak 引用，wire 时由 LiveRoomView 注入。
    /// 用途：pauseForCall 内调 agora?.leave() 离开直播频道；resumeCall 内调 agora?.join() 回直播。
    /// weak：LiveStore 不强持有，LiveRoomView 销毁时自动清理。
    private weak var agora: AgoraManager?

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
        elapsedTimerStore.start()
        logger.info("attachLiving roomId=\(roomInfo.id ?? -1)")
    }

    /// 注入 AgoraManager + CameraManager 双向引用：
    /// - agora.liveStore = self（token 续期失败回调）
    /// - agora.networkMonitor = monitor（networkQuality 转发）
    /// - monitor.agora / monitor.camera（v5.1 降级时同时切 agora 编码档位 + camera 推帧节流）
    /// - **D 里程碑新增**：`self.agora = agora` 让 LiveStore 能在 pauseForCall/resumeCall 内
    ///   主动 leave/join 直播 RTC 频道（不强持有，LiveRoomView 销毁时自动清理）
    func wire(_ agora: AgoraManager, camera: CameraManager? = nil) {
        self.agora = agora
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
        elapsedTimerStore.stop()
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

    /// v5.1：NetworkQualityMonitor 每次 report 后调用更新调试信息（LiveRoomView 调试面板实时显示）。
    /// 转发到独立的 NetworkDebugStore，避免 LiveStore.objectWillChange 触发 LiveRoomView 整树重渲染。
    func updateNetworkDebug(_ block: (inout NetworkDebugInfo) -> Void) {
        networkDebugStore.update(block)
    }

    /// 直播态下收到 RTM VideoCall → 暂停直播 → 委托 CallStore 自动接听。
    /// 对齐 H5 useCallApi.callInEnter 中 "if (isLiving) await livingEnd(false)" 路径。
    /// 详见 `docs/plan/D-直播转私call状态机-spec-202606201400.md` §3.2。
    func pauseForCall(msg: CallMessage) async {
        guard state == .living, callState == 0 else {
            logger.warning("pauseForCall 跳过 state=\(String(describing: self.state)) callState=\(self.callState)")
            return
        }
        logger.info("pauseForCall: 暂停直播 → 接听 from=\(msg.fromUserId)")

        // 1) 停心跳 + 网络监控（B 已落地的 stop/start；stop 内自动重置 failureCount=0）+ 暂停直播时长计时
        heartbeat.stop()
        monitor.stop()
        elapsedTimerStore.stop()

        // 2) RTC leave 直播频道（保留 roomId/agoraChannelId/rtcToken 字段以备 resumeCall 回 join）
        //    agora 是 weak 引用，nil 时静默跳过（防御性）。
        //    v5.4：await 等 didLeaveChannelWith 回调，避免紧接的通话 join 拿到半销毁 singleton。
        await agora?.leave()

        // 3) 切换状态标志
        callState = 1

        // 4) 在线态联动（D-M0 已落地的 WSHeartbeat 接口；通话期 onlineStatus=CALLING(10000)）
        WSHeartbeat.shared.notifyCallStateChanged(callState: 1)

        // 5) 委托 CallStore 自动接听（D-M1 已落地）
        await CallStore.shared.acceptIncomingFromLive(msg: msg)
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

// MARK: - D 里程碑：通话挂断回直播完整实现（M2）

extension LiveStore {
    /// 通话挂断后由 CallStoreObserver 回调触发，启动 15s 倒计时回直播。
    /// 对齐 H5 liveSetting/components/liveRoom.vue:218-227（returnLiveCountdown=15 + setInterval 1s）。
    /// 详见 `docs/plan/D-直播转私call状态机-spec-202606201400.md` §3.3。
    func resumeCall() async {
        guard callState == 1 else { return }
        guard !isWaitingReturnLive else { return }  // 防重复触发（CallStoreObserver 多次回调时幂等）

        logger.info("resumeCall: 启动 15s 倒计时回直播")
        isWaitingReturnLive = true
        returnLiveCountdown = 15

        // 取消可能的旧倒计时 task（防御性）
        returnLiveTask?.cancel()
        returnLiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 15s 倒计时（每秒 -1，UI 显示用；可被 cancel）
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if self.returnLiveCountdown > 0 { self.returnLiveCountdown -= 1 }
            }

            // 倒计时归 0：rejoin 直播频道 + 恢复心跳/监控
            await self.rejoinLiveChannel()
            self.heartbeat.start()   // start 内会先 stop 再启动，failureCount 重置为 0
            self.monitor.start()
            self.elapsedTimerStore.start()   // 恢复直播时长计时（保留已累加值，继续累加）
            self.callState = 0
            self.isWaitingReturnLive = false
            WSHeartbeat.shared.notifyCallStateChanged(callState: 0)
            self.logger.info("已恢复直播 channelId=\(self.agoraChannelId ?? "-")")
        }
    }

    /// 用保留的 channelId + rtcToken 重新 join 直播 RTC 频道。
    /// rtcToken 长时通话可能过期（H5 24h），无 token 或失败时主动续期。
    private func rejoinLiveChannel() async {
        guard let channelId = agoraChannelId,
              let uid = SessionStore.shared.user?.userId else {
            logger.warning("rejoinLiveChannel: 缺 channelId(\(self.agoraChannelId ?? "nil")) 或 uid")
            return
        }

        // 优先用保留的 token，无效时主动续
        var token = rtcToken ?? ""
        if token.isEmpty {
            do {
                let tokenRes = try await LiveService.getAgoraRtmToken()
                token = tokenRes.rtcToken ?? ""
            } catch {
                logger.error("rejoinLiveChannel: 续 rtcToken 失败 err=\(String(describing: error))")
                return
            }
        }
        guard !token.isEmpty else {
            logger.warning("rejoinLiveChannel: token 空")
            return
        }

        // RTC join（对齐 attachLiving 内的直播 profile）
        agora?.join(channelId: channelId, token: token, uid: UInt(uid), profile: .liveBroadcasting)
        logger.info("rejoinLiveChannel: 已请求 join channelId=\(channelId)")
    }
}

// MARK: - D 里程碑：CallStoreObserver（监听通话结束触发 resumeCall）

extension LiveStore: CallStoreObserver {
    /// 仅关心"通话态 → 结束态"的转换；只在直播私 call（callState=1）期间触发 resumeCall。
    func callStore(_ store: CallStore, stateDidChange newState: CallState, previous: CallState) {
        let wasInCall = (previous == .calling || previous == .connecting || previous == .connected)
        let nowEnded = (newState == .ended || newState == .idle)
        guard wasInCall, nowEnded, callState == 1 else { return }
        logger.info("CallStore 通话结束 (\(String(describing: previous)) → \(String(describing: newState))) → 启动 resumeCall")
        Task { await resumeCall() }
    }
}

// MARK: - LiveTimerStore：直播时长 1Hz 计时（独立 ObservableObject）
//
// 原 LiveRoomView 内 Timer.publish + @State elapsed 模式违反 CLAUDE.md 实现纪律
// （"Timer 业务计时器应收敛进 Store"）；拆出后 LiveStore 显式 start/stop，
// 仅 LiveElapsedCapsule 子 view 订阅 elapsedSeconds 字段，1Hz 写不波及 LiveRoomView 整树。

@MainActor
final class LiveTimerStore: ObservableObject {
    @Published private(set) var elapsedSeconds: Int = 0
    private var task: Task<Void, Never>?

    /// 启动 1Hz 计时（不重置 elapsedSeconds，支持暂停-恢复）。
    /// 重复调 start 幂等：先 cancel 旧 task 再起新 task。
    func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self?.elapsedSeconds += 1
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func reset() {
        stop()
        elapsedSeconds = 0
    }
}
