import Foundation
import UIKit
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
    /// 单例（H-2 refactor uncommitted 已引用 [MainTabView.swift:55](../Home/MainTabView.swift#L55) `LiveStore.shared.reset()`）。
    ///
    /// **注意** — LiveRoomView 目前仍用 `@StateObject private var store = LiveStore()` 各自创建实例，
    /// 与本 shared 单例**不同实例**。H-2 refactor 会话需决定：是否把 LiveRoomView 改用 `LiveStore.shared`
    /// （对齐 session-scoped-store-refresh rule 模式）+ SessionStore.logout 挂 clear。本处仅补 shared
    /// 让 build 通过，不做 wiring 变更（避免越界改架构）
    static let shared = LiveStore()

    // ─── 状态 ───────────────────────────────────────
    @Published private(set) var state: LiveState = .idle {
        didSet {
            guard oldValue != state else { return }
            // IM 场景闸门 wiring：进入/退出 .living 同步 IMSceneGate（直播相关 sysMsg 过滤）。
            // 详见 Sources/Live/NIM/IMSceneFilter.swift §设计核心。
            let wasLiving = (oldValue == .living)
            let isLiving = (state == .living)
            if !wasLiving && isLiving {
                IMSceneGate.shared.enter(.live)
            } else if wasLiving && !isLiving {
                IMSceneGate.shared.exit(.live)
            }
        }
    }
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

    // ─── 结果页 spec §2.4：本场直播的起止时间戳（毫秒），传给 queryLiveStat
    //  - attachLiving 时写 begin（每次新开播覆盖）
    //  - endLive / forceEnd 尾部（state=.ended 之后）写 end
    //  - pauseForCall / resumeCall 不改（通话不算真下播）
    //  - LiveResultView 消费一次后由 reset() 清；否则下一场开播 begin 覆盖即可
    @Published private(set) var beginTimestamp: Int64?
    @Published private(set) var endTimestamp: Int64?

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
    private lazy var backgroundMonitor: BackgroundMonitor = {
        let m = BackgroundMonitor()
        m.store = self
        return m
    }()

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
        // 结果页 spec §2.4：记开播时间戳（毫秒）；覆盖上一场（reset 兜底）
        self.beginTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        self.endTimestamp = nil
        heartbeat.start()
        monitor.start()
        backgroundMonitor.start()
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
        endTimestamp = Int64(Date().timeIntervalSince1970 * 1000)   // 结果页 spec §2.4
        UserDefaults.standard.set(Date(), forKey: LastEndLiveTracker.key)  // §8.3 用
    }

    /// 重置状态（LiveResultView back 时调用，切 Home Tab 前清干净）。
    /// - 状态机：`.ended` → `.idle`
    /// - 字段：begin/endTimestamp、endType、roomId 等房间上下文清空
    /// - **不**主动 leave RTC / NIM / 停心跳：LiveRoomView.onDisappear 已负责
    func reset() {
        guard state == .ended else {
            logger.warning("reset ignored in state=\(String(describing: self.state))")
            return
        }
        beginTimestamp = nil
        endTimestamp = nil
        endType = nil
        roomId = nil
        agoraChannelId = nil
        rtcToken = nil
        yxRoomId = nil
        callState = 0
        inFlightEnd = false
        state = .idle
        logger.info("LiveStore reset → idle")
    }
}

// MARK: - 强制下播 + 同步 CAS + 优先级仲裁（spec §2.5 + §2.5b）

extension LiveStore {
    func forceEnd(reason: ForceEndReason, subSource: String? = nil) async {
        let sub = subSource ?? "-"
        // 【归因日志】直播被强制结束入口统一记录：搜索 🛑 [forceEnd] 一眼看到 reason + 触发路径栈
        // callState=1 时命中 = 通话中被下播（异常）；isWaitingReturnLive=true 时命中 = 通话结束返回直播路径中
        logger.notice("🛑 [forceEnd] reason=\(String(describing: reason)) sub=\(sub) state=\(String(describing: self.state)) callState=\(self.callState) isWaitingReturnLive=\(self.isWaitingReturnLive)")
        guard tryEnterForceEnding(reason) else { return }
        do {
            try await LiveService.endLiveRoom(endType: reason.code)
        } catch {
            logger.error("endLiveRoom failed during forceEnd: \(String(describing: error))")
        }
        await teardown()
        state = .ended
        endType = reason.code
        endTimestamp = Int64(Date().timeIntervalSince1970 * 1000)   // 结果页 spec §2.4
        UserDefaults.standard.set(Date(), forKey: LastEndLiveTracker.key)  // 60s 冷却对齐 endLive（LiveSettings §1.3）
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
        backgroundMonitor.stop()
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
        logger.notice("🟢 [pauseForCall] 直播 → 私 call 起点 from=\(msg.fromUserId) roomId=\(msg.fromRoomId ?? "-") liveState=\(String(describing: self.state)) callState_before=\(self.callState)")

        // 1) 提前切换 callState 闸门（BackgroundMonitor 检查此字段，避免 leave await 期间用户切后台
        //    时被误计入 backgroundCount；红队 🟠-4 修复）。
        //    副作用：pauseForCall 期间 heartbeat/monitor 尚未 stop，callState=1 会传给心跳接口 —
        //    这与 D 里程碑通话期 callState=1 语义一致，服务端接受。
        callState = 1

        // 2) 【真根因修复 v5】通话中**不停 heartbeat**（对齐 H5 anchor-livechat-h5/src/views/liveSetting/index.vue:266-271
        //    keepLiving 6s 一直发送，只在 handleLiveEnd 主动下播时 clearHeartBeatTimer）。
        //    HeartbeatController.tick 内会读 store.callState 动态字段，callState=1 时 liveHeartBeatV2
        //    上报 callState=1 让服务端知道"主播端活跃，通话正常"。
        //    之前 stop heartbeat 导致服务端 5 分钟未收到主播心跳 → 判定异常 → 服务端下发 sysMsg
        //    通知用户端触发 hangup（每次精确 297s = 服务端 300s 上限 - 主播端接通耗时）。
        // heartbeat.stop()   ← 移除：通话中继续发心跳保持服务端认可
        monitor.stop()
        elapsedTimerStore.stop()
        // 直播转私 call 回归修复双保险：若 pauseForCall 前已有 20s watcher 在跑
        // （相机 runtimeError 与 pauseForCall 时序竞争），强制清 watcher 避免通话中 fire forceEnd 下播。
        stopCameraFailureWatcher()

        // 3) RTC leave 直播频道（保留 roomId/agoraChannelId/rtcToken 字段以备 resumeCall 回 join）
        //    agora 是 weak 引用，nil 时静默跳过（防御性）。
        //    v5.4：await 等 didLeaveChannelWith 回调，避免紧接的通话 join 拿到半销毁 singleton。
        await agora?.leave()

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
            // 直播转私 call 回归修复：通话/PK/派对房场景（callState != 0）不启动 20s watcher。
            // 声网 SDK 切 channelProfile (.liveBroadcasting → .communication) 触发 AVCaptureSession
            // 内部 reconfigure → sessionRuntimeError → 若无守卫会误触 forceEnd(.cameraFailure) 下播。
            // 对齐 BackgroundMonitor / HeartbeatController 通话中 stop 的语义。
            // 【归因日志】相机异常入口 —— sessionRuntimeError / wasInterrupted 都走这里
            logger.notice("🎥 [onCameraError] err=\(String(describing: error)) callState=\(self.callState) liveState=\(String(describing: self.state)) isWaitingReturnLive=\(self.isWaitingReturnLive)")
            guard callState == 0 else {
                logger.notice("🎥 [onCameraError] SKIP watcher: callState=\(self.callState) (in call/pk/match)")
                return
            }
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
            // v5.10 真根因修复（用户日志实证 forceEnd sub=camera_runtime_20s 即命中此路径）：
            // Task.sleep 在后台不挂起，20s 后可能在后台/inactive 状态唤醒；也可能在回前台
            // 瞬间 InterruptionEnded 清 watcher 之前抢先执行 → 误触 endType=5 自动下播。
            //
            // 三层守卫：
            //   1. yield + 500ms grace：让 pending 的 handleInterruptionEnded 派发到 main queue 的 block 优先跑
            //   2. applicationState==.active：非 active 静默重置 watcher，等 interruptionEnded 决策
            //   3. 立即清 flag：防止重入
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.cameraFailureStartedAt != nil else { return }
                guard UIApplication.shared.applicationState == .active else {
                    logger.info("camera watcher fired but app not active; reset watcher and wait for interruptionEnded")
                    self.cameraFailureStartedAt = nil
                    return
                }
                self.cameraFailureStartedAt = nil
                self.cameraFailureWatcher = nil
                logger.notice("🛑 [cameraWatcher] 20s 已到 + app 前台 + state=\(String(describing: self.state)) callState=\(self.callState) → forceEnd(.cameraFailure)")
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
        guard callState == 1 else {
            logger.notice("🟢 [resumeCall] 跳过：callState=\(self.callState) != 1")
            return
        }
        guard !isWaitingReturnLive else {
            logger.notice("🟢 [resumeCall] 跳过：isWaitingReturnLive=true（幂等保护）")
            return
        }

        logger.notice("🟢 [resumeCall] 启动 15s 倒计时回直播 liveState=\(String(describing: self.state))")
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
            // 倒计时归 0 自动回直播
            await self.finishReturnLive()
        }
    }

    /// 用户点弹窗"Return to live"按钮：跳过剩余倒计时，立刻回直播。
    /// 对齐 H5 [liveSetting/components/liveRoom.vue:245-251](anchor-livechat-h5) `returnLive()`：
    /// 清定时器 + beginLiveOpen + emit returnLive。
    func returnLiveNow() async {
        guard isWaitingReturnLive else {
            logger.notice("🟢 [returnLiveNow] 跳过：isWaitingReturnLive=false")
            return
        }
        logger.notice("🟢 [returnLiveNow] 用户点按钮立刻回直播 (剩余倒计时=\(self.returnLiveCountdown)s)")
        returnLiveTask?.cancel()
        returnLiveTask = nil
        await finishReturnLive()
    }

    /// resumeCall 倒计时归 0 or returnLiveNow 手动触发时的收尾：rejoin + 恢复网络监控 + 状态复位。
    /// 【真根因修复 v5】heartbeat 通话中未 stop，callState 从 1 → 0 后 tick 自动上报 callState=0，无需 restart。
    private func finishReturnLive() async {
        await rejoinLiveChannel()
        monitor.start()
        elapsedTimerStore.start()   // 恢复直播时长计时（保留已累加值，继续累加）
        callState = 0
        isWaitingReturnLive = false
        returnLiveCountdown = 0
        WSHeartbeat.shared.notifyCallStateChanged(callState: 0)
        logger.info("已恢复直播 channelId=\(self.agoraChannelId ?? "-")")
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
        // 【归因日志】所有 CallStore state 迁移的观察点（无论是否触发 resumeCall）
        logger.info("🔍 [Observer] CallState \(previous.rawValue) → \(newState.rawValue) (liveState=\(String(describing: self.state)) callState=\(self.callState) isWaitingReturnLive=\(self.isWaitingReturnLive))")
        let wasInCall = (previous == .calling || previous == .connecting || previous == .connected)
        let nowEnded = (newState == .ended || newState == .idle)
        guard wasInCall, nowEnded, callState == 1 else { return }
        logger.notice("🟢 [Observer] 私 call 结束 (\(previous.rawValue) → \(newState.rawValue)) → 启动 resumeCall 15s 倒计时回直播")
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
                // 复查 202607012202 S-11：外部释放后立即退出 loop，避免每秒 nil 写空转
                guard let self, !Task.isCancelled else { return }
                self.elapsedSeconds += 1
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
