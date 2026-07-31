import Foundation
import SwiftUI
import Combine
import Network
import UIKit  // C-4 Wave2 gap-critic-005：UIApplication.didEnterBackgroundNotification
import os
import NIMSDK  // sendCallText 走 P2P NIMCustomObject attachType=-1

// MARK: - D 里程碑：CallStore 状态变化观察者协议
//
// 设计目的：CallStore.state 变化通知外部（如 LiveStore），实现单向回调，CallStore 不引用 LiveStore 类型。
// 典型实现：LiveStore conform 此协议，监听 connected/connecting → ended 后启动 resumeCall 15s 倒计时。
@MainActor
protocol CallStoreObserver: AnyObject {
    func callStore(_ store: CallStore, stateDidChange newState: CallState, previous: CallState)
}

/// 1v1 通话单层状态机（合并 H5 CallStateType + callGameStatus，采纳安卓 SDK 风格）。
///
/// 责任：
/// - 维护 `state` 和 `current`，把"按钮点击 / RTM 信令 / 计时器"统一收敛
/// - 主/被叫两条主流程的串行编排
/// - RTC 建链交给 AgoraManager；信令交给 CallSignaling；接口交给 CallService
///
/// 信令协议与 H5 声网 CallAPI `ICallMessage` 严格对齐：
/// 主叫端 `callOut` 生成 callId（UUID），整轮通话共享；被叫端从 `CallMessage.callId` 读出存下来，
/// 后续 accept/reject/hangup 时都要把同一个 callId 带回去。channelId 在主叫端来自 createCall，
/// 在被叫端来自 `CallMessage.fromRoomId`（主叫 RTC channel）。
@MainActor
final class CallStore: ObservableObject {
    static let shared = CallStore()

    // MARK: - 对外状态

    @Published private(set) var state: CallState = .idle {
        // D 里程碑：state 变化通知 observer（LiveStore 监听 connected/connecting → ended 触发 resumeCall）。
        // didSet 在 @Published publish 之后调用，满足 SwiftUI 渲染先于业务回调的顺序。
        didSet {
            guard oldValue != state else { return }
            updateAppSoundsForStateTransition()
            // F refactor：多观察者数组（原单 weak var observer 已改为 NSHashTable，spec §3.4 P0-2）
            notifyObservers { $0.callStore(self, stateDidChange: state, previous: oldValue) }
            updateElapsedTimer(prev: oldValue)
            updateIMSceneGate(prev: oldValue, next: state)
            // C-4 Wave1 gap-009：私 call 首次转 .connected 时初始化 300s 收益横幅倒计时。
            // frontGameType 在 callOut/handleIncomingVideoCall/acceptIncomingFromLive 时已置定。
            // F-spec：派对房私 call 同款 5min 锁定期（对齐直播私 call · 用户诉求）
            if state == .connected, oldValue != .connected,
               (current.frontGameType == .live || current.frontGameType == .party) {
                liveCallCountdown = 300
                // C-4 Wave4 A1 gap-008：直播私 call 双头像会合动画（H5 livingCallAnimation 特效，派对房不启用）
                if current.frontGameType == .live {
                    livingCallIntroToken = UUID()
                }
            }
            if state == .connected, oldValue != .connected {
                sendConnectedNimSignalIfPossible()
            }
            // C-4 Wave2 gap-critic-004：AudioSession 生命周期挂载
            // - 首次进入 .connecting/.connected 时 activate（直播私 call 走 LiveStore 主导，不激活）
            // - 转 .idle 时 deactivate（endLocally scheduleEndedToIdle 500ms 后）
            let wasCallActive = (oldValue == .connecting || oldValue == .connected)
            let isCallActive = (state == .connecting || state == .connected)
            if !wasCallActive, isCallActive, current.frontGameType != .live {
                CallAudioSessionController.shared.activate(
                    onInterruptionBegan: { [weak self] in self?.handleAudioInterruptionBegan() },
                    onInterruptionEnded: { [weak self] in self?.handleAudioInterruptionEnded() }
                )
            }
            if state == .idle, oldValue != .idle {
                CallAudioSessionController.shared.deactivate()
            }
        }
    }

    /// 机器人通话在 `createCall` 网络请求期间也必须视为真人通话忙碌，防止两个流程抢占 Agora 单例。
    var blocksRobotCall: Bool { state != .idle || isStartingDirectCall }

    /// IM 场景闸门 wiring：state 离开/进入 .idle 同步 IMSceneGate（通话相关 sysMsg 过滤）。
    ///
    /// **exit 8s grace**：state → .idle 后延迟 8s 才真退场景，接收挂断后尾消息——
    /// callRechargeReward 等 server 异步推送可能在挂断后几秒到达。详见 IMSceneFilter §设计核心 5。
    private func updateIMSceneGate(prev: CallState, next: CallState) {
        let wasActive = (prev != .idle)
        let isActive = (next != .idle)
        if !wasActive && isActive {
            IMSceneGate.shared.enter(.call)
        } else if wasActive && !isActive {
            IMSceneGate.shared.exit(.call, delay: 8.0)
        }
    }
    /// 通话计时（秒）。CallWaitingView 用作主叫超时圆环；CallFaceTimeView 用作通话时长。
    /// 规则：`.calling` 进入从 0 累加 → `.connected` 切换时重置为 0（通话时长起点）→
    /// `.ended` / `.idle` 停止 + 归 0。view 端只读 store 字段，不在 view 内持 `Timer.publish`
    /// （违反 `.claude/rules` 副作用收敛进 Store；且 struct view 重建会重生 publisher 引发多 timer
    /// 并发 tick 跳秒）。
    @Published private(set) var callElapsed: Int = 0
    @Published private(set) var current: CurrentCallInfo = CurrentCallInfo()
    @Published private(set) var lastError: String = ""
    /// 通话媒体权限弹窗由 RootView 承载，避免主叫尚未进入 CallView 时没有反馈。
    @Published var mediaPermissionAlertRequirement: MediaPermissionGate.Requirement?
    private var pendingMediaPermissionAction: (() async -> Void)?
    /// RTM client 是否已 login（永真直到 stop）。语义：login 已建立 → 信令通道存在。
    /// **注意**：不等于"RTM 连接当前可用"——断网/重连中时仍为 true。UI 用 `rtmConnectionState` 判定实时连接态。
    @Published private(set) var isSignalingReady: Bool = false
    /// RTM 实时连接状态（镜像 RtmReconnect.state，由 SDK connectionChangedToState 驱动）。
    /// HomeView 用此字段显示"已就绪/重连中/断连"。
    @Published private(set) var rtmConnectionState: RtmConnState = .idle

    // MARK: - H M4：sysMsg 通道字段（待 C 期 backlog UI 绑订）

    /// sysMsg -6 通话充值等待状态（type 0/1/2/3/4；0 表示未在等待）
    @Published private(set) var callWaitState: Int = 0
    /// sysMsg 90 通话充值累计钻石奖励
    @Published private(set) var callWaitBonus: Int = 0
    /// sysMsg -1 最近一条远端文字（通话公屏以 `callChatMessages` 为单一渲染数据源）。
    @Published private(set) var callRecentRemoteText: String?
    /// sysMsg -1 远端文字附带的 chatBubble 九宫格图片 URL。
    @Published private(set) var callChatBubble: String?

    /// 公屏消息历史队列（对齐 H5 `homeStore.talkListInCall[]`）。上限 50 防增长；追加即修剪。
    /// - 消费者：CallMessageScroller（左侧 270×300 可滚动区域）
    /// - 生产者：
    ///   - handleRemoteText（sysMsg -1）→ 追加对方 text
    ///   - handleRemoteGiftFromP2P（P2P SEND_GIFT）→ 追加对方 gift + 触发特效
    ///   - sendCallText / echoLocalChatText → 主播自己发送后本地回显
    ///   - appendWaitBonus 可选追加 bonus（当前未启用，等 UI 决定）
    @Published private(set) var callChatMessages: [CallChatMessage] = []
    private let callChatMessagesLimit = 50

    // MARK: - C-5 充值锁定流程（gap-011+012+017+critic-013）

    /// 充值锁定倒计时视觉倒计时（60→0；PAY_SUCCESS 清；到期 5s fallback 后 hangup）。
    @Published private(set) var callWaitCountdown: Int = 0
    /// PAY_SUCCESS Congrats 弹窗 trigger token（`.sheet(isPresented:)` 消费）
    @Published private(set) var congratsBonusToken: UUID?
    /// Congrats 弹窗当次显示的 bonus 值（PAY_SUCCESS 时快照 callWaitBonus）
    @Published private(set) var lastCongratsBonus: Int = 0

    /// callWaitState == 1 或 3 时 UI 需展示 WaitRechargeTips 顶部蒙层 + 隐藏底部普通 pill
    var isCallWaitLocked: Bool { callWaitState == 1 || callWaitState == 3 }

    private var callWaitTimerTask: Task<Void, Never>?

    private static let callWaitPrimarySeconds = 60
    private static let callWaitFallbackSeconds = 5
    private static let congratsBonusDelaySeconds: TimeInterval = 2

    /// L 里程碑：最近一次 joinCall 返回的 source 字段（'matchV4' / 'liveCall' / nil / 其他）。
    /// **Single source of truth**：MatchStore 只读订阅此字段,不本地缓存副本。
    /// - 两处 joinCall 调用（acceptIncomingFromLive Line ~466 + handleIncomingVideoCall Line ~785）成功后 assign
    /// - joinCall 失败 → 置 nil（fallback）
    /// - state 转 .idle 时不主动重置（保留最近一次值供 MatchStore 判定"通话结束回 .matching 是否合法"）
    @Published private(set) var lastJoinCallSource: String?

    // MARK: - C 里程碑通话中控制状态

    /// 麦克风静音状态（UI 反馈用）。CallView bottomBar 按钮图标 mic ⇄ mic.slash。
    /// 每次 endLocally 强制 reset 到 false 避免下次通话继承静音。
    @Published private(set) var isMicMuted: Bool = false

    /// 前置摄像头状态（UI 反馈用，暂时未使用图标反馈但保留字段供 view 决策）。
    /// endLocally 时 reset 到 true。直播私 call 场景下不切换（CallStore.switchCamera 已 guard）。
    @Published private(set) var isUsingFrontCamera: Bool = true

    /// C 里程碑弱网 toast trigger token。每次 emit 一个新 UUID，CallView.CallNetworkToast 通过
    /// `.task(id:)` 消费该值 → 显示 2s toast。设计参考 CallHudOverlay 里 `.task(id: callRecentRemoteText)`。
    @Published private(set) var weakNetworkToastToken: UUID?

    /// 连续坏质量（≥5）计数。阈值 = 30 次（≈60s 声网 2s/次）对齐 H5 `networkMonitor.js`（详见 spec §0.4）。
    /// 中间任一次质量 ≤4 立即清零。
    private var weakNetworkConsecutiveCount: Int = 0
    private let weakNetworkThreshold = 30
    /// toast 触发冷却：2s 内不重复，避免弱网抖动时多次 toast。
    private var lastWeakNetworkToastAt: Date?

    // MARK: - C-3 通话异常自检（H5 g-faceTime/topBar.vue tenSecondsCB + secondsToZero）

    /// 当前展示的异常 alert reason；nil 表示无 alert。CallFaceTimeView `.alert(isPresented:)` 消费此字段。
    /// 一次通话内同 reason 只弹一次（由 alertedAbnormalReasons 记忆）。
    @Published private(set) var callAbnormalReason: CallAbnormalReason?

    /// 黑屏空房间检测倒计时剩余秒数（DM-20260616-003）；nil = 不展示弹窗。
    /// 由 `emptyRoomDetector.$countdownRemaining` 转发；CallView 观察后展示 10s 不可取消的倒计时弹窗。
    @Published private(set) var emptyRoomCountdownRemaining: Int?

    /// v22（2026-07-10）：主播 askForGift 被用户拒绝时触发 toast 的 token（UUID 变化 = 触发展示 2s）
    /// sysMsg attachType=16 (giftRequestRejected) → GiftEffectSysMsgRouter → showAskForGiftRejected()
    @Published private(set) var askForGiftRejectedToken: UUID?

    /// 展示 askForGift 被拒 toast（token 变化即触发）
    func showAskForGiftRejected() {
        askForGiftRejectedToken = UUID()
        AppLogger.call.info("[CallStore] askForGiftRejected → show toast")
    }

    /// 本轮通话已弹过的 reason 集合，避免同 reason 连续骚扰；endLocally 时清空。
    private var alertedAbnormalReasons: Set<CallAbnormalReason> = []

    // MARK: - C-4 Wave1 gap-009 直播私 call 300s 收益横幅倒计时（H5 g-faceTime/index.vue streamerCountdown）

    // MARK: - C-4 Wave4 A1 gap-008 · 直播私 call 双头像会合动画 trigger

    /// LivingCallIntroAnimation 播放 trigger（H5 g-faceTime/livingCallAnimation.vue）。
    /// state 首次转 .connected + frontGameType==.live 时 emit UUID；view 层 `.task(id:)` 播 1s 旋转合流 + 2s 后自消。
    @Published private(set) var livingCallIntroToken: UUID?

    /// 直播私 call 剩余多少秒达到"分钟收入=通话价格"（300 递减到 0）。
    /// 仅 frontGameType==.live 且 state==.connected 时递减；endLocally 归 0。
    /// CallFaceTimeView.liveCallBanner 分档：>0 显示带 %d 的横幅，=0 显示原静态文案。
    @Published private(set) var liveCallCountdown: Int = 0

    /// RTC 管理器（CallView 用它做远端渲染 + push 美颜后的帧）
    let agora = AgoraManager()

    /// 当前独立 1v1 通话使用的相机。直播私 call 复用直播相机，结束通话后仍要回直播，
    /// 因此只关闭由通话自身创建的相机。
    private weak var localCamera: CameraManager?
    private var ownsLocalCamera = false

    // MARK: - 内部

    private var signaling: CallSignaling?
    private var myUserId: Int = 0
    /// `createCall` 尚未返回时也占用真人通话入场权；否则机器人来电可在 await 间隙启动 RTC。
    private var isStartingDirectCall = false
    private var callOutTimeoutTask: Task<Void, Never>?
    /// H5 g-waitingCall 对来电也执行 30s 自动结束；独立任务避免干扰主叫超时桶。
    private var callInTimeoutTask: Task<Void, Never>?
    /// 避免 RTC 状态/资料回填同时触发时对同一通话重复发送 CONNECTED 辅助信令。
    private var nimConnectedSignalCallId: String?
    /// endLocally 内含 await（RTC leave / callRate）；期间其它信令可能重入，必须只允许一个收尾事务。
    private var isEndingCall = false
    /// ended → idle 的延迟切换 task。被 stop()/新 callOut 触发时必须 cancel，否则会异步把
    /// 已经被新通话覆盖的 state 重置回 .idle。
    private var endedToIdleTask: Task<Void, Never>?
    /// callElapsed 计时 task（每秒 +1）。state didSet 内启停 + 重置。
    private var elapsedTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// RTM 状态订阅句柄。CallStore 是单例 stop/start 可反复调用，订阅必须独立管理避免累积。
    private var rtmStateCancellable: AnyCancellable?
    /// 网络可达性监听器。冷启动无网→有网时自动 retry start。
    private var nwMonitor: NWPathMonitor?
    /// start 失败的 5s 兜底重试 task（即便无网络变化事件也能爬出来）。
    private var startRetryTask: Task<Void, Never>?
    /// 网络是否可达（NWPathMonitor 回调更新；用于避开"无网时还做 5s 重试"的浪费）。
    /// 初值 false：保守假设——冷启动时 NWPathMonitor 还未首次回调，按"无网"判定走 10s 兜底
    /// 节奏，等首次回调后再切换。避免 start 失败首次重试用 5s 触发又一次浪费。
    private var isNetworkAvailable: Bool = false
    /// start 防重入标志。start 是 async 含多个 await 点（getAgoraRtmToken / login）；
    /// NWPathMonitor、startRetryTask、RootView 都会触发 start，必须串行化避免双 CallSignaling
    /// 实例 + 双 RTM client 泄漏。
    private var isStarting: Bool = false
    /// callRate 上报开关（C 范围默认关，避免与后端联调相互干扰）
    // D 里程碑：callRate 上报开启（C 验证通过 + 后端契约确认 callRate 接口已上线）
    private var callRateEnabled = true

    /// D 里程碑：LiveStore weak 引用（对齐 AgoraManager.liveStore 模式）。
    /// 注入时机：LiveRoomView.onAppear 或 RootView 直播态分支；解绑：LiveRoomView 销毁。
    /// 用途：handleIncomingVideoCall 内判定 .living 时委托 LiveStore.pauseForCall 走直播私 call 流程。
    weak var liveStore: LiveStore?
    /// G M6：PK 状态机弱引用；handleIncomingVideoCall 在 PK 期一律 busy reject 避免脏跳。
    weak var pkStore: PKStore?

    /// D+F 里程碑：状态变化观察者数组（CallStoreObserver 协议 T4）。
    ///
    /// F 期 refactor（spec §3.4 P0-2 决策）：从 `weak var observer: CallStoreObserver?` 单槽 →
    /// `NSHashTable.weakObjects()` 多观察者，支持 LiveStore + PartyStore + 未来场景各自 attach 而不互相踩踏。
    ///
    /// - 使用 attach / detach 而非直接赋值
    /// - NSHashTable weakObjects 自动清理已销毁的观察者
    /// - notifyObservers 按 allObjects 快照顺序遍历（顺序不保证，观察者不能相互依赖顺序）
    private let observers = NSHashTable<AnyObject>.weakObjects()

    /// 注册状态观察者（幂等：NSHashTable 内含即忽略）
    func attach(_ observer: CallStoreObserver) {
        observers.add(observer as AnyObject)
    }

    /// 注销状态观察者（幂等：不存在时 no-op）。view dismiss 后 weak 会自动 nil，仍推荐显式调用。
    func detach(_ observer: CallStoreObserver) {
        observers.remove(observer as AnyObject)
    }

    /// 内部通知辅助：遍历当前存活观察者
    private func notifyObservers(_ block: (CallStoreObserver) -> Void) {
        observers.allObjects.compactMap { $0 as? CallStoreObserver }.forEach(block)
    }

    /// 黑屏空房间检测状态机(DM-20260616-003)。init 后由 `setupEmptyRoomDetector()` 构造并挂 Combine assign。
    /// 每 10s 心跳查询 `POST /api/agora/live/channelUserCount`;连续 3 次异常弹 10s 倒计时自动挂断。
    private var emptyRoomDetector: CallEmptyRoomDetector!

    private init() {
        AppSoundPlayer.shared.preload()
        // 远端用户加入 RTC channel 时 → state 切 .connected（声网 didJoinedOfUid 触发）
        // 远端用户离开 → 兜底切 ended（一般已被 RTM hangup 提前处理，这里只防消息丢失）
        agora.$remoteUid
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uid in
                guard let self else { return }
                Task { @MainActor in await self.handleRemoteRtcChange(uid: uid) }
            }
            .store(in: &cancellables)

        // C 里程碑：通话侧独立弱网 counter；reportCallNetworkQuality 内自带 state guard，
        // idle/ended/calling 阶段 no-op → 常挂无副作用。
        agora.callNetworkQualityHandler = { [weak self] worst in
            self?.reportCallNetworkQuality(worst: worst)
        }

        // C-4 Wave2 gap-critic-005：app 切后台/前台推流管理。
        // 单例 CallStore 常挂 observers；handler 内 state guard + frontGameType!=.live 保护，
        // idle/直播私 call 阶段无副作用。用闭包版避免 @objc + NSObject 派生约束。
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAppDidEnterBackground() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAppWillEnterForeground() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAppDidBecomeActive() }
        }

        // 黑屏空房间检测状态机构造（DM-20260616-003）
        // - getChannelId 读 current.channelId（通话结束后为空 → detector.tick 内 guard 短路）
        // - canShowPopup 与 RTC 本地异常框互斥（callAbnormalReason 非空时抑制倒计时弹窗）
        // - onHangup 使用系统心跳异常结束原因（对齐 H5 systemAbnormal）
        emptyRoomDetector = CallEmptyRoomDetector(
            getChannelId: { [weak self] in self?.current.channelId },
            canShowPopup: { [weak self] in self?.callAbnormalReason == nil },
            onHangup: { [weak self] _ in
                Task { @MainActor in await self?.hangupForSystemHeartbeatFailure() }
            },
            onReport: { status in
                AppLogger.call.info("🩺 [EmptyRoom] report status=\(status, privacy: .public)")
            }
        )
        // 转发 detector 倒计时状态到 CallStore.@Published，避免 CallView 双订阅
        emptyRoomDetector.$countdownRemaining
            .receive(on: DispatchQueue.main)
            .assign(to: &$emptyRoomCountdownRemaining)
        AppLogger.call.notice("🩺 [CallStore] emptyRoomDetector 初始化完成（DM-20260616-003）")
    }

    /// 远端 RTC 状态变化 → state 升级 / 兜底挂断。
    ///
    /// ⚠️ 关键设计：必须 state == .connecting 才升级到 .connected，**不能从 .calling 直接升**。
    /// 原因：用户端实现是"收到 VideoCall 立即 RTC join（占位/订阅模式，等用户点接听后才推流）"，
    /// 如果在 .calling 时看到远端 join 就切 .connected，会出现"对端没接听但主播 UI 已是 FaceTime"
    /// 的灵异现象。.connecting 必须由对端 Accept 信令显式触发（handleRemoteAccept）。
    private func handleRemoteRtcChange(uid: UInt) async {
        if uid != 0 {
            guard state == .connecting else {
                AppLogger.call.debug("📍 [CallStore] 远端 uid=\(uid, privacy: .public) 加入但本端 state=\(self.state.rawValue, privacy: .public)，等待 Accept 信令")
                return
            }
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            AppLogger.call.info("✅ [CallStore] 远端 uid=\(uid, privacy: .public) 加入 + 已收 Accept → state=connected")
        } else {
            // 远端离开：仅在通话中兜底（一般已被对端 hangup 信令提前处理）
            guard state == .connected else { return }
            AppLogger.call.notice("⚠️ [CallStore] 远端离开 RTC（兜底挂断）")
            await endLocally(reason: .remoteHangUp, rateCategory: nil, rateType: .caller, answerTime: 0, abnormal: 0)
        }
    }

    // MARK: - 生命周期

    /// 登录后由 RootView 调用：拉 rtmToken，初始化 RTM client。
    /// 重复调用安全（已就绪直接 return）。
    /// **失败兜底**：① NWPathMonitor 监听网络恢复立刻 retry ② 5s 定时兜底 retry（即便无网络事件）。
    func start(myUserId: Int) async {
        if isSignalingReady { return }
        // 防重入：start 有 2 个 await 点（getAgoraRtmToken / login），NWPathMonitor 与
        // startRetryTask 任一进入会引发"双 CallSignaling 实例 + 双 RTM client"泄漏。
        if isStarting {
            AppLogger.call.notice("⚠️ [CallStore] start 已在进行中，跳过 uid=\(myUserId, privacy: .private)")
            return
        }
        isStarting = true
        defer { isStarting = false }

        self.myUserId = myUserId
        // 首次进入 start 时启动网络监听（一次性，stop 才销毁）
        if nwMonitor == nil { startNetworkMonitor() }
        do {
            let tokenRes = try await LiveService.getAgoraRtmToken()
            guard let rtm = tokenRes.rtmToken, !rtm.isEmpty else {
                lastError = L10n.callErrorRtmTokenEmpty
                scheduleStartRetry(myUserId: myUserId, reason: "empty_token")
                return
            }
            let s = CallSignaling(myUserId: myUserId)
            s.delegate = self
            try await s.login(token: rtm, refreshToken: { [weak self] in
                guard self != nil else { return nil }
                return try? await LiveService.getAgoraRtmToken().rtmToken
            })
            signaling = s
            isSignalingReady = true
            lastError = ""
            cancelStartRetry()  // 成功后取消兜底 retry
            // 订阅 RTM 实时连接状态：login 成功后 reconnect.bind 已设 .connected，
            // 后续 SDK connectionChangedToState 回调驱动 .reconnecting/.disconnected/.connected 变化。
            rtmStateCancellable = s.rtmStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] new in
                    guard let self else { return }
                    if self.rtmConnectionState != new {
                        AppLogger.rtm.debug("📡 [CallStore] rtmConnectionState \(self.rtmConnectionState.rawValue, privacy: .public) → \(new.rawValue, privacy: .public)")
                    }
                    self.rtmConnectionState = new
                }
            AppLogger.call.info("✅ [CallStore] start 成功 uid=\(myUserId, privacy: .private)")
        } catch let e as APIError {
            let msg = "CallStore.start 失败: \(e.message)(\(e.code))"
            lastError = msg
            AppLogger.call.error("❌ [CallStore] \(msg, privacy: .private)")
            scheduleStartRetry(myUserId: myUserId, reason: "api_\(e.code)")
        } catch {
            let msg = "CallStore.start 异常: \(error.localizedDescription)"
            lastError = msg
            AppLogger.call.error("❌ [CallStore] \(msg, privacy: .private)")
            scheduleStartRetry(myUserId: myUserId, reason: "exception")
        }
    }

    // MARK: - start 失败兜底重试

    /// 调度 5s 后再 try start。若期间网络恢复（NWPathMonitor 触发），会被 cancel 由网络回调立刻 retry。
    private func scheduleStartRetry(myUserId: Int, reason: String) {
        cancelStartRetry()
        let delay: TimeInterval = isNetworkAvailable ? 5 : 10  // 无网络时等长一点，省电
        AppLogger.call.debug("🔄 [CallStore] scheduleStartRetry reason=\(reason, privacy: .public) delay=\(delay, privacy: .public)s (net=\(self.isNetworkAvailable, privacy: .public))")
        startRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self, !self.isSignalingReady, self.myUserId == myUserId else { return }
            await self.start(myUserId: myUserId)
        }
    }

    private func cancelStartRetry() {
        startRetryTask?.cancel()
        startRetryTask = nil
    }

    // MARK: - 网络可达性监听（NWPathMonitor）

    /// 监听网络可达性，从 unsatisfied → satisfied 时若 RTM 未就绪则立即 retry start。
    /// 解决"冷启动无网 → 用户开网后 RTM 永远停在 idle"的死锁。
    private func startNetworkMonitor() {
        let m = NWPathMonitor()
        // NWPathMonitor.start 后会立即首次回调当前实际网络状态。初值 isNetworkAvailable=false
        // 与"网络恢复"边沿（was=false → satisfied=true）匹配，会触发一次不必要的 retry 调度
        // （isStarting 守卫挡住但产生噪音日志）。用 firstCallback flag 跳过首次仅同步初值。
        // Swift 6 严格并发禁止 var 被 @Sendable 闭包捕获后修改，用引用类型 box 包装；
        // pathUpdateHandler 由 NWPathMonitor 在单一 queue 串行回调，无需额外锁。
        final class FirstCallbackBox: @unchecked Sendable { var value = true }
        let firstCallback = FirstCallbackBox()
        m.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            let firstShot = firstCallback.value
            firstCallback.value = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                let was = self.isNetworkAvailable
                self.isNetworkAvailable = satisfied
                if firstShot {
                    AppLogger.rtm.debug("📶 [CallStore] NWPathMonitor 首次回调 satisfied=\(satisfied, privacy: .public)（仅同步初值）")
                    return
                }
                if !was && satisfied {
                    if !self.isSignalingReady, self.myUserId != 0 {
                        // 冷启动失败 → 立即 retry start（已 login 之前的路径）
                        AppLogger.rtm.debug("📶 [CallStore] 网络恢复 → 立即 retry start uid=\(self.myUserId, privacy: .private)")
                        self.cancelStartRetry()
                        await self.start(myUserId: self.myUserId)
                    } else if self.isSignalingReady, let s = self.signaling {
                        // 已 login → 通知 RtmReconnect 立即重连（消除慢重试 5s tick 等待）
                        AppLogger.rtm.debug("📶 [CallStore] 网络恢复 → 通知 RTM 立即重连")
                        s.notifyNetworkResumed(reason: "network_resume")
                    } else {
                        AppLogger.rtm.debug("📶 [CallStore] 网络恢复（未登录，忽略）")
                    }
                } else if was && !satisfied {
                    AppLogger.rtm.debug("📶 [CallStore] 网络断开 status=\(String(describing: path.status), privacy: .public)")
                }
            }
        }
        // Apple 文档推荐用专用 queue 避免回调被其他全局任务阻塞。qos 选 .userInitiated：
        // 网络变化是用户感知事件，闭包应尽快被调度（vs .utility 偏后台）。
        m.start(queue: DispatchQueue(label: "com.anchor.livechat.nwpath", qos: .userInitiated))
        nwMonitor = m
        AppLogger.rtm.debug("📶 [CallStore] NWPathMonitor 已启动")
    }

    /// 登录态结束或完整主播能力撤销时清理 RTM + RTC + 状态。
    /// D 里程碑修复（v5.4）：改 async，等 `agora.leave()` 真正完成（didLeaveChannelWith 回调）
    /// 再做后续清理，避免下次 start 拿到半销毁 SDK singleton。
    ///
    /// - Parameter destroySharedAgoraEngine: 仅登出/完全受限时为 true。107 Party-only 账号降级时
    ///   Party 房仍在使用同一进程级 Agora 引擎，必须只退出通话而保留该引擎。
    func stop(destroySharedAgoraEngine: Bool = true) async {
        AppSoundPlayer.shared.stopIncomingCallRingtone()
        cancelCallOutTimeout()
        cancelCallInTimeout()
        cancelStartRetry()
        nwMonitor?.cancel()
        nwMonitor = nil
        endedToIdleTask?.cancel()
        endedToIdleTask = nil
        rtmStateCancellable?.cancel()
        rtmStateCancellable = nil
        stopOwnedLocalCamera()
        if state != .idle { await agora.leave() }
        signaling?.logout()
        signaling = nil
        isSignalingReady = false
        rtmConnectionState = .idle
        myUserId = 0
        state = .idle
        current = CurrentCallInfo()
        isEndingCall = false
        isStartingDirectCall = false
        if destroySharedAgoraEngine {
            // 退登/完全受限链路：销毁 AgoraRtcEngineKit 全局单例，
            // 下次登录时 sharedEngine(with:) 会拿到干净的新 singleton。
            AgoraManager.destroyEngine()
        }
    }

    // MARK: - 主叫：拨号
    //
    // 严格对齐 H5 主播端 useCallApi.handleCallOutFunc + callApi.call：
    //   1) await apiCreateCall(beCallUserId, callType) → 拿后端真 channelId + 对方资料
    //      （fromRoomId 必须是后端真实 channelId，否则用户端 apiJoinCall 查不到 → 浮层闪一下消失）
    //   2) 端侧 UUID 生成 callId
    //   3) _autoCancelCall(true) 启动 30s 超时
    //   4) _rtcJoinAndPublish() —— 不 await，与 publish 并发
    //   5) await _publishMessage({action=videoCall, fromRoomId=后端channelId})
    //
    // 1111 错误 "current status unable to make a call" 不是"主播角色被禁"，是 WSHeartbeat
    // 上报的 onlineStatus 错误。后端要求 CALL_END(10001) 才放行 createCall；FOREGROUND(10002)
    // 被拒。已在 WSHeartbeat 调整为 .callEnd。
    func callOut(remoteUserId: String) async {
        // P 项目权限管理：三层防护 Store 层 · 走统一 gate helper（不 assertionFailure 避 race crash · Finding 4/8）
        // v2 code-review: gate 拒绝时 set lastError 让 view 层可 observe（对齐同函数其他 preflight 失败分支）
        // 用通用 networkError 文案避免暴露 blacklist 状态（spec §6.1 fail-secure）
        guard SelfPermissionBridge.shared.gate(.call, action: "callOut") else {
            lastError = L10n.userProfileNetworkError
            return
        }
        guard !RobotCallStore.shared.blocksOtherCalls else {
            lastError = L10n.callErrorLocalBusy
            AppLogger.call.notice("[CallStore] callOut blocked: robot call is active")
            return
        }
        // 最小化 Party 房仍占用 RTC/NIM；主动拨打前先完整退房，避免通话初始化被旧会话干扰。
        if PartyStore.shared.isMinimized {
            await PartyStore.shared.leaveMinimizedRoom()
        }
        guard isSignalingReady, let signaling, acquireDirectCallAdmission() else {
            if lastError.isEmpty { lastError = L10n.userProfileNetworkError }
            AppLogger.call.notice("⚠️ [CallStore] callOut 跳过 state=\(self.state.rawValue, privacy: .public) starting=\(self.isStartingDirectCall, privacy: .public) signaling=\(self.signaling != nil, privacy: .public)")
            return
        }
        defer { isStartingDirectCall = false }
        guard await requireMediaAccess(.liveStream, retry: { [weak self] in
            await self?.callOut(remoteUserId: remoteUserId)
        }) else { return }
        // code-review Finding 5：内部化 preflight 让 caller 简化（原 4 处 caller preflight 分裂：POCDebug 无 / ChatDetail 缺 isSignalingReady / LiveList+UserProfile 全套）
        // signaling 未就绪 / 通话中 / calling → set lastError 让 view 层 observe → 统一反馈路径
        guard let remoteUid = Int(remoteUserId), remoteUid > 0 else {
            lastError = L10n.callErrorInvalidRemoteUserId
            return
        }

        // 1) 调 createCall 拿后端真 channelId + 对方资料
        let res: CreateCallResult
        do {
            res = try await CallService.createCall(beCallUserId: remoteUid)
        } catch let e as APIError {
            lastError = e.message
            AppLogger.call.error("❌ [CallStore] createCall 失败 code=\(e.code, privacy: .public) msg=\(e.message, privacy: .private)")
            return
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard let channelId = res.channelId, !channelId.isEmpty else {
            lastError = L10n.callErrorCreateFailed
            return
        }
        guard state == .idle, self.signaling === signaling, !RobotCallStore.shared.blocksOtherCalls else {
            lastError = L10n.callErrorLocalBusy
            AppLogger.call.notice("[CallStore] callOut abandoned after createCall: another call acquired RTC")
            return
        }

        // 2) 初始化 currentCallInfo（含 createCall 返回的对方资料）
        var info = CurrentCallInfo()
        info.frontGameType = .direct
        info.inOrOut = .out
        info.channelId = channelId                   // 后端真 channelId = fromRoomId
        info.callId = UUID().uuidString              // 端侧 UUID（H5 _callMessage.setCallId 等价）
        info.remoteUserId = remoteUid
        info.remoteYxAccid = res.yxAccid ?? ""
        info.remoteNickname = res.nickname ?? ""
        info.remoteIcon = res.icon ?? ""
        info.remoteLevelName = res.levelName ?? ""
        info.remoteAge = res.age ?? 0
        info.remoteCountryCode = res.countryCode ?? ""
        info.remoteVideoPrice = res.videoPrice ?? 0
        info.callStartTime = Date().timeIntervalSince1970 * 1000
        current = info
        state = .calling

        // 3) 启动 30s 超时（H5 _autoCancelCall(true)）
        startCallOutTimeout()

        // 4) 主叫立刻 join 自己一侧 RTC（H5 _rtcJoinAndPublish 不 await）
        let channelToJoin = info.channelId
        Task { @MainActor [weak self] in
            await self?.joinRtc(channel: channelToJoin, rateType: .caller)
        }

        // 5) 发 RTM VideoCall（H5 await _publishMessage）
        let ok = await signaling.publish(buildMessage(action: .videoCall))
        guard state == .calling, current.callId == info.callId else { return }
        if !ok {
            lastError = L10n.callErrorSendFailed
            sendCallNimSignal(.cancel)
            // H5 callOutCancel L1065/1076：主动取消桶 answerTime=0
            await endLocally(reason: .beginCallError, rateCategory: .canceled, rateType: .caller, answerTime: 0, abnormal: 1)
            return
        }
    }

    // MARK: - 主叫：取消（未接通前用户主动撤回）

    func cancel() async {
        guard state == .calling, current.inOrOut == .out else { return }
        cancelCallOutTimeout()
        if let signaling {
            _ = await signaling.publish(buildMessage(action: .cancel))
        }
        sendCallNimSignal(.cancel)
        // H5 callOutCancel L1065/1076：主动取消桶 answerTime=0
        await endLocally(reason: .localHangUp, rateCategory: .canceled, rateType: .caller, answerTime: 0, abnormal: 0)
    }

    // MARK: - L 里程碑：匹配态自动接听判定 closure（由 App 层注入）

    /// 判断"当前是否处于匹配态"—— handleIncomingVideoCall 据此走自动接听路径。
    /// 由 RootView.syncSessionDependent 挂载，读 MatchStore.shared.state == .matching。
    /// 用 closure 而非直接引 MatchStore：避免 CallStore 与 MatchStore 相互依赖 + test target 隔离
    var isMatchActive: (() -> Bool)?

    /// 所有真人通话入口在任何 await 之前先抢占 admission，避免机器人通话或另一通来电穿过异步窗口。
    private func acquireDirectCallAdmission() -> Bool {
        guard state == .idle,
              !isStartingDirectCall,
              !RobotCallStore.shared.blocksOtherCalls
        else {
            return false
        }
        isStartingDirectCall = true
        return true
    }

    private func requireMediaAccess(
        _ requirement: MediaPermissionGate.Requirement,
        retry: @escaping () async -> Void
    ) async -> Bool {
        guard await MediaPermissionGate.requestAccess(for: requirement) else {
            mediaPermissionAlertRequirement = requirement
            pendingMediaPermissionAction = retry
            return false
        }
        return true
    }

    func retryMediaPermissionFromAlert(_ requirement: MediaPermissionGate.Requirement) async {
        let action = pendingMediaPermissionAction
        mediaPermissionAlertRequirement = nil
        pendingMediaPermissionAction = nil
        if await MediaPermissionGate.requestAccess(for: requirement) {
            await action?()
        } else {
            MediaPermissionGate.openAppSettings()
        }
    }

    // MARK: - 被叫：接受 / 拒绝

    /// L 里程碑：匹配态收到 videoCall 时的自动接听入口（对齐 H5 useCallApi.js:437-441）。
    /// 由 handleIncomingVideoCall 内 `isMatchActive?() == true` 分支调用，不弹浮层。
    /// 与 acceptIncomingFromLive 的差异：`frontGameType = .direct`（走标准 CallView g-waitingCall→g-faceTime 分支）
    func acceptIncomingFromMatch(msg: CallMessage) async {
        guard acquireDirectCallAdmission() else {
            await publishRejectBusy(msg: msg, reason: "busy")
            return
        }
        defer { isStartingDirectCall = false }
        guard let signaling else {
            AppLogger.call.notice("⚠️ [CallStore] acceptIncomingFromMatch 跳过 state=\(self.state.rawValue, privacy: .public)")
            return
        }
        guard let fromRoomId = msg.fromRoomId, !fromRoomId.isEmpty else {
            AppLogger.call.notice("⚠️ [CallStore] acceptIncomingFromMatch 缺 fromRoomId")
            return
        }
        guard await requireMediaAccess(.liveStream, retry: { [weak self] in
            await self?.acceptIncomingFromMatch(msg: msg)
        }) else { return }

        // 1) 初始化 currentCallInfo（被叫 in / frontGameType=.direct，让 CallView 走标准分支）
        var info = CurrentCallInfo()
        info.frontGameType = .direct
        info.inOrOut = .in
        info.channelId = fromRoomId
        info.callId = msg.callId
        info.remoteUserId = msg.fromUserId
        info.callStartTime = Date().timeIntervalSince1970 * 1000
        current = info
        state = .calling

        // 2) 立刻发 Accept
        let ok = await signaling.publish(buildMessage(action: .accept))
        guard ok else {
            lastError = L10n.callErrorAcceptFailed
            sendCallNimSignal(.reject)
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: .callee, answerTime: 0, abnormal: 1)
            return
        }
        state = .connecting

        // 3) join RTC
        await joinRtc(channel: fromRoomId, rateType: .callee)

        // 4) 主叫端可能已在频道（同 acceptIncomingFromLive Step 4）
        if agora.remoteUid != 0, state == .connecting {
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            AppLogger.call.info("✅ [CallStore] 匹配自动接听后远端已在频道 → state=connected")
        }

        // 5) 接通率上报
        await reportRate(category: .answered, type: .callee,
                         answerTime: current.sinceStartDuration, abnormal: 0)

        // 6) 异步拉对方资料（joinCall.source 用于 MatchStore 判定 matchV4）
        Task { @MainActor in
            do {
                let r = try await CallService.joinCall(channelId: fromRoomId)
                self.lastJoinCallSource = r.source
                guard self.state != .idle, self.state != .ended, self.state != .failed,
                      self.current.callId == msg.callId,
                      self.current.channelId == fromRoomId else { return }
                self.current.remoteYxAccid = r.yxAccid ?? self.current.remoteYxAccid
                self.current.remoteNickname = r.nickname ?? self.current.remoteNickname
                self.current.remoteIcon = r.icon ?? self.current.remoteIcon
                self.current.remoteLevelName = r.levelName ?? self.current.remoteLevelName
                self.current.remoteHeadFrame = r.headFrame ?? self.current.remoteHeadFrame
                self.current.remoteAge = r.age ?? self.current.remoteAge
                self.current.remoteCountryCode = r.countryCode ?? self.current.remoteCountryCode
                self.current.remoteVideoPrice = r.videoPrice ?? self.current.remoteVideoPrice
                self.sendCallNimSignal(.online)
                self.sendConnectedNimSignalIfPossible()
            } catch {
                self.lastJoinCallSource = nil
                AppLogger.call.notice("⚠️ [CallStore] Match auto-accept joinCall 拉对方资料失败 err=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// D 里程碑：直播态私 call 自动接听入口。
    /// 由 LiveStore.pauseForCall 调用，不弹浮层、无 UI 确认；frontGameType 写入 .live 标记本通通话来源。
    ///
    /// 与 `accept()` 的差异：
    /// - 不依赖现有 `state == .calling`（直接从 .idle 起步）
    /// - 跳过弹浮层等候用户操作的 calling 中间态视觉环节
    /// - 显式标记 `frontGameType = .live`，CallView UI 据此显示"直播私 call"标识 + "挂断回直播"
    func acceptIncomingFromLive(msg: CallMessage) async {
        guard SelfPermissionBridge.shared.gate(.call, action: "acceptIncomingFromLive") else {
            await publishRejectBusy(msg: msg, reason: "permission_denied")
            return
        }
        guard acquireDirectCallAdmission() else {
            await publishRejectBusy(msg: msg, reason: "busy")
            return
        }
        defer { isStartingDirectCall = false }
        guard let signaling else {
            AppLogger.call.notice("⚠️ [CallStore] acceptIncomingFromLive 跳过 state=\(self.state.rawValue, privacy: .public) signaling=\(self.signaling != nil, privacy: .public)")
            return
        }
        guard let fromRoomId = msg.fromRoomId, !fromRoomId.isEmpty else {
            AppLogger.call.notice("⚠️ [CallStore] acceptIncomingFromLive 缺 fromRoomId")
            return
        }
        guard await requireMediaAccess(.liveStream, retry: { [weak self] in
            await self?.acceptIncomingFromLive(msg: msg)
        }) else { return }

        // 1) 初始化 currentCallInfo（被叫 in / frontGameType=.live）
        var info = CurrentCallInfo()
        info.frontGameType = .live
        info.inOrOut = .in
        info.channelId = fromRoomId
        info.callId = msg.callId
        info.remoteUserId = msg.fromUserId
        info.callStartTime = Date().timeIntervalSince1970 * 1000
        current = info
        state = .calling

        // 2) 立刻发 Accept（publish 失败必须收尾，避免主叫永等不到 Accept）
        let ok = await signaling.publish(buildMessage(action: .accept))
        guard ok else {
            lastError = L10n.callErrorAcceptFailed
            sendCallNimSignal(.reject)
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: .callee, answerTime: 0, abnormal: 1)
            return
        }
        state = .connecting

        // 3) join RTC 通话频道
        await joinRtc(channel: fromRoomId, rateType: .callee)

        // 4) 主叫端可能已在频道（callOut 时先 join），若 didJoinedOfUid 在切到 .connecting 前已触发，
        //    handleRemoteRtcChange 不会再回调，此处手动补一次升级。
        if agora.remoteUid != 0, state == .connecting {
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            AppLogger.call.info("✅ [CallStore] 直播私 call 接听后远端已在频道 → state=connected")
        }

        // 5) 接通率上报（answered 节点，对齐 accept() 同位置上报）。同步 await：fire-and-forget
        //    会与对端 RTM hangup 入队的 handleRemote Task 形成 FIFO race，hangup 先跑会推到
        //    state=.ended → reportRate 入口守卫拦截 → answered 永久漏报。同步 await 把这次上报
        //    放在 publish/joinRtc 共同 MainActor 串行链路上，handleRemote 必排队在后。
        await reportRate(category: .answered, type: .callee,
                         answerTime: current.sinceStartDuration, abnormal: 0)

        // 6) 异步拉对方资料（C 范围 joinCall 接口；失败仅影响 UI，不影响接通能力）
        Task { @MainActor in
            do {
                let r = try await CallService.joinCall(channelId: fromRoomId)
                // L 里程碑：无条件 assign source（不受 state guard 约束）——
                // MatchStore 订阅此字段实时判定 matchState 迁移。LIVE 私 call 通常 source='liveCall' 或 nil。
                self.lastJoinCallSource = r.source
                guard self.state != .idle, self.state != .ended, self.state != .failed,
                      self.current.callId == msg.callId,
                      self.current.channelId == fromRoomId else { return }
                self.current.remoteYxAccid = r.yxAccid ?? self.current.remoteYxAccid
                self.current.remoteNickname = r.nickname ?? self.current.remoteNickname
                self.current.remoteIcon = r.icon ?? self.current.remoteIcon
                self.current.remoteLevelName = r.levelName ?? self.current.remoteLevelName
                self.current.remoteHeadFrame = r.headFrame ?? self.current.remoteHeadFrame
                self.current.remoteAge = r.age ?? self.current.remoteAge
                self.current.remoteCountryCode = r.countryCode ?? self.current.remoteCountryCode
                self.current.remoteVideoPrice = r.videoPrice ?? self.current.remoteVideoPrice
                self.sendCallNimSignal(.online)
                self.sendConnectedNimSignalIfPossible()
            } catch {
                // L 里程碑：joinCall 失败 → source 置 nil（MatchStore 保守视为非 matchV4）
                self.lastJoinCallSource = nil
                AppLogger.call.notice("⚠️ [CallStore] LIVE joinCall 拉对方资料失败 channel=\(fromRoomId, privacy: .private) err=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// F 里程碑：派对房私 call 自动接听入口（对齐 D 期 acceptIncomingFromLive · spec §2.1 Flow B）。
    /// 由 PartyStore.pauseForCall 调用，不弹浮层、无 UI 确认；frontGameType 写入 .party 标记本通通话来源。
    ///
    /// 与 acceptIncomingFromLive 的唯一差异：`frontGameType = .party`。其余时序、信令、joinRtc、
    /// 接通率上报、joinCall 拉资料完全一致（复用直播私 call 立即接听模式 · D-1 决策：无 5s delay）。
    func acceptIncomingFromParty(msg: CallMessage) async {
        guard SelfPermissionBridge.shared.gate(.call, action: "acceptIncomingFromParty") else {
            await publishRejectBusy(msg: msg, reason: "permission_denied")
            return
        }
        guard acquireDirectCallAdmission() else {
            await publishRejectBusy(msg: msg, reason: "busy")
            return
        }
        defer { isStartingDirectCall = false }
        guard let signaling else {
            AppLogger.call.notice("⚠️ [CallStore] acceptIncomingFromParty 跳过 state=\(self.state.rawValue, privacy: .public) signaling=\(self.signaling != nil, privacy: .public)")
            return
        }
        guard let fromRoomId = msg.fromRoomId, !fromRoomId.isEmpty else {
            AppLogger.call.notice("⚠️ [CallStore] acceptIncomingFromParty 缺 fromRoomId")
            return
        }
        guard await requireMediaAccess(.liveStream, retry: { [weak self] in
            await self?.acceptIncomingFromParty(msg: msg)
        }) else { return }

        // 1) 初始化 currentCallInfo（被叫 in / frontGameType=.party）
        var info = CurrentCallInfo()
        info.frontGameType = .party
        info.inOrOut = .in
        info.channelId = fromRoomId
        info.callId = msg.callId
        info.remoteUserId = msg.fromUserId
        info.callStartTime = Date().timeIntervalSince1970 * 1000
        current = info
        state = .calling

        // 2) 立刻发 Accept（publish 失败必须收尾，避免主叫永等不到 Accept）
        let ok = await signaling.publish(buildMessage(action: .accept))
        guard ok else {
            lastError = L10n.callErrorAcceptFailed
            sendCallNimSignal(.reject)
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: .callee, answerTime: 0, abnormal: 1)
            return
        }
        state = .connecting

        // 3) join RTC 通话频道（sharedEngine 会显式 setChannelProfile(.communication) · rule §5）
        await joinRtc(channel: fromRoomId, rateType: .callee)

        // 4) 主叫端可能已在频道（callOut 时先 join），若 didJoinedOfUid 在切到 .connecting 前已触发，
        //    handleRemoteRtcChange 不会再回调，此处手动补一次升级。
        if agora.remoteUid != 0, state == .connecting {
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            AppLogger.call.info("✅ [CallStore] 派对房私 call 接听后远端已在频道 → state=connected")
        }

        // 5) 接通率上报（answered 节点，与 acceptIncomingFromLive 同步 await 顺序对齐）
        await reportRate(category: .answered, type: .callee,
                         answerTime: current.sinceStartDuration, abnormal: 0)

        // 6) 异步拉对方资料（joinCall 接口；失败仅影响 UI，不影响接通能力）
        Task { @MainActor in
            do {
                let r = try await CallService.joinCall(channelId: fromRoomId)
                self.lastJoinCallSource = r.source
                guard self.state != .idle, self.state != .ended, self.state != .failed,
                      self.current.callId == msg.callId,
                      self.current.channelId == fromRoomId else { return }
                self.current.remoteYxAccid = r.yxAccid ?? self.current.remoteYxAccid
                self.current.remoteNickname = r.nickname ?? self.current.remoteNickname
                self.current.remoteIcon = r.icon ?? self.current.remoteIcon
                self.current.remoteLevelName = r.levelName ?? self.current.remoteLevelName
                self.current.remoteHeadFrame = r.headFrame ?? self.current.remoteHeadFrame
                self.current.remoteAge = r.age ?? self.current.remoteAge
                self.current.remoteCountryCode = r.countryCode ?? self.current.remoteCountryCode
                self.current.remoteVideoPrice = r.videoPrice ?? self.current.remoteVideoPrice
                self.sendCallNimSignal(.online)
                self.sendConnectedNimSignalIfPossible()
            } catch {
                self.lastJoinCallSource = nil
                AppLogger.call.notice("⚠️ [CallStore] PARTY joinCall 拉对方资料失败 channel=\(fromRoomId, privacy: .private) err=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// 被叫接受通话。
    func accept(auto: Bool = false) async {
        guard SelfPermissionBridge.shared.gate(.call, action: "acceptIncomingCall") else {
            if state == .calling {
                await reject()
            }
            return
        }
        guard state == .calling, current.inOrOut == .in, let signaling else { return }
        guard await requireMediaAccess(.liveStream, retry: { [weak self] in
            await self?.accept(auto: auto)
        }) else { return }
        let info = current
        cancelCallInTimeout()
        AppSoundPlayer.shared.stopIncomingCallRingtone()

        // 1) 通知主叫 —— 必须成功才能前进
        //    ⚠️ publish 失败时**不切 .connecting**：否则主叫永远收不到 Accept、30s 后发
        //    Cancel，本端此时是 .connecting，handleRemoteCancel 守卫 `state == .calling`
        //    会丢 Cancel → 卡死 .connecting。
        let ok = await signaling.publish(buildMessage(action: .accept))
        guard ok else {
            lastError = L10n.callErrorAcceptFailed
            sendCallNimSignal(.reject)
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: .callee, answerTime: 0, abnormal: 1)
            return
        }
        state = .connecting

        // 2) 拿 rtcToken + join 频道
        await joinRtc(channel: info.channelId, rateType: .callee)

        // 3) 主叫端可能已经在频道里（主叫 callOut 时先 join），如此 didJoinedOfUid
        //    在状态切到 .connecting 之前就触发过、不会再触发，这里手动补一次升级。
        if agora.remoteUid != 0, state == .connecting {
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            AppLogger.call.info("✅ [CallStore] accept 后远端已在频道 → state=connected")
        }

        // 4) 接通率上报（被叫 answered）
        await reportRate(category: .answered, type: .callee, answerTime: info.sinceStartDuration, abnormal: 0)
    }

    /// 被叫拒绝通话。
    func reject() async {
        guard state == .calling, current.inOrOut == .in, let signaling else { return }
        cancelCallInTimeout()
        AppSoundPlayer.shared.stopIncomingCallRingtone()
        _ = await signaling.publish(buildMessage(action: .reject))
        sendCallNimSignal(.reject)
        // H5 callInCancel L1119/1129：被叫主动拒接桶 answerTime=0
        await endLocally(reason: .localHangUp, rateCategory: .rejected, rateType: .callee, answerTime: 0, abnormal: 0)
    }

    // MARK: - 接通后：挂断

    /// 通话中本地挂断。
    /// v4 规则（对齐 H5 anchor-livechat-h5/src/components/g-faceTime/index.vue:387 `privateCallTips`）：
    /// 直播私 call / 派对房私 call 前 5 分钟锁定期主播不能挂断（liveCallCountdown > 0 期间）；用户可挂断不受此约束。
    func hangup() async {
        guard state == .connecting || state == .connected else { return }
        // 直播私 call / 派对房私 call 锁定期 guard：主播 5 分钟内不允许挂断（对齐 H5 privateCallTips）
        if (current.frontGameType == .live || current.frontGameType == .party), liveCallCountdown > 0 {
            AppLogger.call.notice("🔒 [hangup] 私 call 锁定期 (frontGameType=\(self.current.frontGameType.rawValue, privacy: .public) 剩余 \(self.liveCallCountdown, privacy: .public)s) → 拒绝主播挂断")
            return
        }
        if let signaling {
            _ = await signaling.publish(buildMessage(action: .hangup))
        }
        sendCallNimSignal(.hangUp)
        await endLocally(reason: .localHangUp, rateCategory: nil, rateType: .caller, answerTime: 0, abnormal: 0)
    }

    /// 空房间检测倒计时到期后的系统自动挂断。
    /// H5 使用 `CALL_OVER_REASON_NUMBER.SYSTEM_HEART_BEAT_FAIL`，不能误记为主播主动挂断。
    private func hangupForSystemHeartbeatFailure() async {
        guard state == .connecting || state == .connected else { return }
        if let signaling {
            _ = await signaling.publish(buildMessage(action: .hangup))
        }
        sendCallNimSignal(.hangUp)
        await endLocally(reason: .systemHeartBeatFail,
                         rateCategory: nil,
                         rateType: .caller,
                         answerTime: 0,
                         abnormal: 1)
    }

    // MARK: - C 里程碑通话中控制

    /// 静音/取消静音。仅 `.connecting`/`.connected` 有效，其他态 no-op（幂等保护）。
    /// 对齐 H5 `useCallApi.js` `toggleAudioMute()` 语义：不改 track publish（对端仍认为在线），
    /// 仅停发音频帧。endLocally 会 reset 到 false 避免下次通话继承。
    func toggleMic() {
        guard state == .connecting || state == .connected else { return }
        let newValue = !isMicMuted
        agora.muteLocalAudio(newValue)
        isMicMuted = newValue
    }

    /// 切前后置摄像头。仅 `.connecting`/`.connected` 有效；直播私 call 场景（`frontGameType==.live`）
    /// **禁用**（直播摄像头由 LiveRoomView 独占管理，跨场景切换会污染直播预览）。UI 层已 disabled 兜底。
    /// - `camera` 由 view 层传入（CallFaceTimeView 的 fallback lazy CameraManager）；CallStore 不持有 CameraManager 类型
    func switchCamera(camera: CameraManager) {
        guard state == .connecting || state == .connected else { return }
        guard current.frontGameType != .live else { return }
        camera.switchCameraPosition()
        isUsingFrontCamera.toggle()
    }

    /// CallFaceTimeView 在相机可用后注册。Store 统一结束通话时可立即释放独立通话相机，
    /// 不再等待 SwiftUI 的 onDisappear。
    func bindLocalCamera(_ camera: CameraManager, ownedByCall: Bool) {
        localCamera = camera
        ownsLocalCamera = ownedByCall
    }

    /// 视图销毁时取消注册；若 Store 已先行收尾，此方法是幂等 no-op。
    func unbindLocalCamera(_ camera: CameraManager) {
        guard localCamera === camera else { return }
        localCamera = nil
        ownsLocalCamera = false
    }

    /// 弱网 report 入口（AgoraManager.callNetworkQualityHandler → 转发到这里）。
    /// - 仅 `.connecting`/`.connected` 累计；其他态 no-op（idle/calling 期声网也可能推 quality，忽略）
    /// - 连续 30 次质量 ≥5 触发 toast + counter 清零重计
    /// - 中间任一 ≤4 立即清零（对齐 H5 networkMonitor.js "连续"语义）
    /// - 2s 冷却避免抖动
    private func reportCallNetworkQuality(worst: Int) {
        guard state == .connecting || state == .connected else { return }
        if worst >= 5 {
            weakNetworkConsecutiveCount += 1
            if weakNetworkConsecutiveCount >= weakNetworkThreshold {
                triggerWeakNetworkToast()
                weakNetworkConsecutiveCount = 0  // 触发后清零重计，避免持续劣质网络秒级重触发
            }
        } else {
            weakNetworkConsecutiveCount = 0
        }
    }

    private func triggerWeakNetworkToast() {
        let now = Date()
        if let last = lastWeakNetworkToastAt, now.timeIntervalSince(last) < 2.0 { return }
        lastWeakNetworkToastAt = now
        weakNetworkToastToken = UUID()
    }

    // MARK: - C-3 异常自检 tick / dismiss

    /// startElapsedTask 每秒 tick 后调；仅 .connected 态 + 无 alert 时检查。
    /// - 10s 周期：userOffline / networkUnstable（H5 tenSecondsCB）
    /// - 120s 阈值：incomeZero（H5 secondsToZero）
    /// - 一次通话同 reason 只弹一次（alertedAbnormalReasons 保护）
    /// - alert 展示期间（callAbnormalReason != nil）不重触发（防同 tick 多 reason 冲突）
    private func checkAbnormalIfNeeded() {
        guard state == .connected, callAbnormalReason == nil else { return }
        let elapsed = callElapsed
        if elapsed >= CallTuning.abnormalCheckPeriodSeconds,
           elapsed % CallTuning.abnormalCheckPeriodSeconds == 0 {
            if agora.remoteUid == 0, !alertedAbnormalReasons.contains(.userOffline) {
                triggerAbnormal(.userOffline)
                return
            }
            if agora.state != .joined, !alertedAbnormalReasons.contains(.networkUnstable) {
                triggerAbnormal(.networkUnstable)
                return
            }
        }
        if elapsed >= CallTuning.incomeZeroThresholdSeconds,
           current.callIncome == 0,
           !alertedAbnormalReasons.contains(.incomeZero) {
            triggerAbnormal(.incomeZero)
        }
    }

    private func triggerAbnormal(_ reason: CallAbnormalReason) {
        alertedAbnormalReasons.insert(reason)
        callAbnormalReason = reason
    }

    /// Continue 按钮触发（CallFaceTimeView `.alert` cancel action）；End Call 走 hangup 路径不调此方法。
    func dismissAbnormalReason() {
        callAbnormalReason = nil
    }

    // MARK: - C-4 Wave1 gap-009 300s 收益横幅倒计时 tick

    /// startElapsedTask 每秒 tick 后调；仅 .connected 且 frontGameType==.live/.party 时递减。
    /// 从 300 → 0，归 0 后不再触发（liveCallBanner 分档显示静态文案）。
    /// F-spec：派对房私 call 复用同款 300s 锁定倒计时。
    private func tickLiveCallCountdownIfNeeded() {
        guard state == .connected,
              (current.frontGameType == .live || current.frontGameType == .party),
              liveCallCountdown > 0 else { return }
        liveCallCountdown -= 1
    }

    // MARK: - C-4 Wave2 gap-critic-005 app 切后台/前台推流管理

    /// app 切后台：仅独立 1v1 通话中（`.connecting/.connected` + 非直播私 call）暂停视频推流。
    /// 音频 track 保留（Info.plist UIBackgroundModes:audio + AVAudioSession 组合让通话不断音）。
    /// 直播私 call（frontGameType==.live）由 LiveStore 主导 pauseForCall 链路，本 handler 短路。
    private func handleAppDidEnterBackground() {
        AppSoundPlayer.shared.handleApplicationDidEnterBackground()
        guard state == .connecting || state == .connected else { return }
        guard current.frontGameType != .live else { return }
        agora.updateChannelPublishVideo(false)
        AppLogger.call.info("📱 [CallStore] app didEnterBackground → publishCustomVideoTrack=false（仅独立 1v1）")
    }

    /// app 回前台：恢复视频推流。同上 guard 逻辑。
    private func handleAppWillEnterForeground() {
        guard state == .connecting || state == .connected else { return }
        guard current.frontGameType != .live else { return }
        agora.updateChannelPublishVideo(true)
        AppLogger.call.info("📱 [CallStore] app willEnterForeground → publishCustomVideoTrack=true")
    }

    /// `willEnterForeground` 时应用仍可能处于 inactive；铃声恢复必须等 `didBecomeActive`。
    private func handleAppDidBecomeActive() {
        AppSoundPlayer.shared.handleApplicationDidBecomeActive(
            isIncomingCallWaiting: state == .calling
                && current.inOrOut == .in
                && current.frontGameType == .direct
        )
    }

    // MARK: - C-4 Wave2 gap-critic-004 AudioSession 打断处理

    /// AVAudioSession 打断开始（系统来电/闹钟/其他 App 抢占）：静音本端 mic。
    /// 注意不改 isMicMuted 字段（用户可见状态），仅 SDK 层 muteLocalAudioStream。
    private func handleAudioInterruptionBegan() {
        AppLogger.call.info("🔔 [CallStore] AudioSession interruption began → mute mic (SDK 层)")
        agora.muteLocalAudio(true)
    }

    /// AVAudioSession 打断结束：如用户没主动静音则恢复。
    private func handleAudioInterruptionEnded() {
        AppLogger.call.info("🔔 [CallStore] AudioSession interruption ended → restore mic (userMute=\(self.isMicMuted, privacy: .public))")
        agora.muteLocalAudio(isMicMuted)
    }

    // MARK: - 内部：构造 CallMessage

    /// 严格对齐 H5 callApi/core/callApi.ts 各 action 的 publish payload：
    /// - VideoCall: 带 fromRoomId（被叫据此 join 同频道）
    /// - Cancel:    带 cancelCallByInternal=0（External，用户主动取消）
    /// - Reject:    带 rejectReason + rejectByInternal=0（External）
    /// - Accept / Hangup: 不带额外字段
    /// callId / fromUserId / remoteUserId 是所有 action 通用必填，由 CryptoJS encode 自动塞，
    /// 这里对齐到 Swift Codable init 显式传。
    private func buildMessage(action: CallAction, rejectReason: String? = nil) -> CallMessage {
        switch action {
        case .videoCall, .audioCall:
            return CallMessage(action: action,
                               fromUserId: myUserId,
                               remoteUserId: current.remoteUserId,
                               callId: current.callId,
                               fromRoomId: current.channelId)
        case .cancel:
            return CallMessage(action: action,
                               fromUserId: myUserId,
                               remoteUserId: current.remoteUserId,
                               callId: current.callId,
                               cancelCallByInternal: 0)
        case .reject:
            return CallMessage(action: action,
                               fromUserId: myUserId,
                               remoteUserId: current.remoteUserId,
                               callId: current.callId,
                               rejectReason: rejectReason,
                               rejectByInternal: 0)
        case .accept, .hangup:
            return CallMessage(action: action,
                               fromUserId: myUserId,
                               remoteUserId: current.remoteUserId,
                               callId: current.callId)
        }
    }

    /// H5 `sendCustomSysMsg` 的 iOS 对应：RTM 仍负责状态迁移，NIM 只做弱网兜底。
    private func sendCallNimSignal(_ type: CallNimType) {
        let peer = current.remoteYxAccid
        let channelId = current.channelId
        guard !peer.isEmpty, !channelId.isEmpty else {
            AppLogger.call.debug("[CallStore] NIM call signal skip type=\(type.rawValue, privacy: .public): missing peer/channel")
            return
        }
        let payload: [String: Any] = [
            "attachType": -3,
            "channelId": channelId,
            "type": type.rawValue,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let content = String(data: data, encoding: .utf8) else {
            AppLogger.call.warning("[CallStore] NIM call signal encode failed type=\(type.rawValue, privacy: .public)")
            return
        }

        let notification = NIMCustomSystemNotification(content: content)
        notification.sendToOnlineUsersOnly = true
        let setting = NIMCustomSystemNotificationSetting()
        setting.shouldBeCounted = false
        setting.apnsEnabled = false
        notification.setting = setting
        let session = NIMSession(peer, type: .P2P)
        NIMSDK.shared().systemNotificationManager.sendCustomNotification(notification, to: session) { error in
            if let error {
                AppLogger.call.notice("[CallStore] NIM call signal failed type=\(type.rawValue, privacy: .public) err=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func sendConnectedNimSignalIfPossible() {
        guard !current.callId.isEmpty, nimConnectedSignalCallId != current.callId else { return }
        guard !current.remoteYxAccid.isEmpty else { return }
        nimConnectedSignalCallId = current.callId
        sendCallNimSignal(.connected)
    }

    // MARK: - 内部：RTC 建链
    //
    // 本端 join channel 完成后 state 不切 .connected——必须等远端 didJoinedOfUid 回调
    // （即对方真正 join 同一 channel）才算接通；状态升级在 handleRemoteRtcChange 里做。
    //
    // ⚠️ joinRtc 内有 `await getAgoraRtmToken`（网络），期间对端可能 Hangup → endLocally 先跑、
    // state=.ended、agora 已 leave。如果 token 拿回后无脑 agora.join，会创建一个游离的 RTC 通道
    // 没有清理路径。所以拿到 token 后必须再次校验 state 仍处于"应当继续 join"的阶段。
    private func joinRtc(channel: String, rateType: CallRateType) async {
        let stateBeforeAwait = state
        do {
            let tokenRes = try await LiveService.getAgoraRtmToken()
            guard let rtcToken = tokenRes.rtcToken, !rtcToken.isEmpty else {
                lastError = L10n.callErrorRtcTokenFailed
                await endLocally(reason: .beginCallError, rateCategory: nil, rateType: rateType, answerTime: 0, abnormal: 1)
                return
            }
            // 关键守卫：state 必须仍在拨号/接通过程中。.calling 适用于主叫端 callOut 后立刻 join 的
            // 路径；.connecting 适用于主/被叫 Accept 后的路径。其它（.ended/.failed/.idle）都
            // 表示通话已中止，幽灵 join 必须被阻断。
            guard state == .calling || state == .connecting else {
                AppLogger.call.debug("📍 [CallStore] joinRtc 拿到 token 后 state 已是 \(self.state.rawValue, privacy: .public)（之前=\(stateBeforeAwait.rawValue, privacy: .public)）→ 放弃 join")
                return
            }
            agora.join(channelId: channel, token: rtcToken, uid: UInt(myUserId), profile: .communication)
        } catch let e as APIError {
            lastError = String(format: L10n.callErrorRtcTokenFormat, e.message)
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: rateType, answerTime: 0, abnormal: 1)
        } catch {
            lastError = String(format: L10n.callErrorRtcTokenFormat, error.localizedDescription)
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: rateType, answerTime: 0, abnormal: 1)
        }
    }

    // MARK: - 内部：统一收尾

    private func endLocally(reason: CallOverReason,
                            rateCategory: CallRateCategory?,
                            rateType: CallRateType,
                            answerTime: Int = 0,
                            abnormal: Int) async {
        guard state != .idle, !isEndingCall else {
            AppLogger.call.debug("[endLocally] duplicate end ignored reason=\(reason.rawValue, privacy: .public)")
            return
        }
        isEndingCall = true
        AppSoundPlayer.shared.stopIncomingCallRingtone()
        // 【归因日志】通话结束入口统一记录：谁触发 + 触发时上下文
        // 用于排查"自动结束"：搜索 🔴 [endLocally] 一眼看到 reason + 触发路径栈
        AppLogger.call.notice("🔴 [endLocally] reason=\(reason.rawValue, privacy: .public) rateCat=\(rateCategory.map { String($0.rawValue) } ?? "nil", privacy: .public) rateType=\(rateType.rawValue, privacy: .public) state=\(self.state.rawValue, privacy: .public) elapsed=\(self.callElapsed, privacy: .public)s frontGame=\(String(describing: self.current.frontGameType), privacy: .public) inOrOut=\(String(describing: self.current.inOrOut), privacy: .public) answerTime=\(answerTime, privacy: .public) abnormal=\(abnormal, privacy: .public) callWaitState=\(self.callWaitState, privacy: .public) lastError='\(self.lastError, privacy: .private)'")
        cancelCallOutTimeout()
        cancelCallInTimeout()
        let info = current
        current.hangupReason = reason
        // 本地相机/麦克风必须先收；上报失败或超时不能阻止设备释放。
        stopOwnedLocalCamera()
        // v5.4：await 等 didLeaveChannelWith，避免后续 start/join 拿到半销毁 singleton
        if state != .idle { await agora.leave() }
        // logout/stop 可能在 leave 期间把通话重置为 idle；此时不能用旧通话继续上报或覆写状态。
        guard state != .idle, current.callId == info.callId else { return }
        // C 里程碑 R2：reset 通话中控制状态，避免下次通话继承
        if isMicMuted {
            agora.muteLocalAudio(false)
            isMicMuted = false
        }
        isUsingFrontCamera = true
        weakNetworkConsecutiveCount = 0
        lastWeakNetworkToastAt = nil
        weakNetworkToastToken = nil
        // C-3 reset：下次通话干净开始（alertedAbnormalReasons 允许所有 reason 重新触发）
        callAbnormalReason = nil
        alertedAbnormalReasons.removeAll()
        // C-4 Wave1 reset：私 call 倒计时归 0（下次 .connected 时 didSet 重新初始化 300）
        liveCallCountdown = 0
        // DM-20260616-003 reset：清空黑屏空房间检测状态机，下次通话干净起点
        emptyRoomDetector.reset()
        // C-4 Wave4 A1 reset：双头像动画 token 清（下次通话重新触发）
        livingCallIntroToken = nil
        // C-5 reset：cancel 计时避免异步 hangup，congrats sheet 关闭
        cancelCallWaitLockTimer()
        congratsBonusToken = nil
        lastCongratsBonus = 0
        state = .ended
        scheduleEndedToIdle()

        // ⚠️ 主播端**不调** `/callOver`（后端无此路由 → 404；该接口是用户端独有的，后端按
        // 用户端 callOver 触发结算）。通话已经在本地结束后，才尽力上报 callRate；接口问题
        // 不得影响音视频释放或 UI 收尾。
        if !info.channelId.isEmpty, let cat = rateCategory {
            await reportRate(category: cat, type: rateType,
                             answerTime: answerTime,
                             abnormal: abnormal,
                             allowEnded: true)
        }
    }

    private func stopOwnedLocalCamera() {
        guard ownsLocalCamera, let localCamera else { return }
        BeautyPipelineSharer.shared.detach(localCamera.renderer as AnyObject & BeautyRenderer)
        localCamera.tearDown()
        localCamera.stop()
        self.localCamera = nil
        ownsLocalCamera = false
    }

    /// ended → idle 的延迟切换（正常挂断 500ms，失败态 1.8s 让 UI 有时间展示"结束原因"toast）。
    /// 使用可取消的 Task：stop() / 新 callOut 触发时必须 cancel，否则会异步把已被新通话
    /// 占用的 state 错误复位回 idle。
    private func scheduleEndedToIdle() {
        endedToIdleTask?.cancel()
        // 拨打失败提示：lastError 非空 → 延长 1.8s 让 CallView 结束原因 toast 展示完整
        let delayNs: UInt64 = lastError.isEmpty ? 500_000_000 : 1_800_000_000
        endedToIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self, !Task.isCancelled, self.state == .ended else { return }
            self.state = .idle
            self.current = CurrentCallInfo()
            self.isEndingCall = false
            // H M4：HUD 顶级 @Published 不在 current 内，需单独 reset，避免新通话 HUD 残留旧气泡
            self.callRecentRemoteText = nil
            self.callChatBubble = nil
            self.callWaitBonus = 0
            self.callWaitState = 0
            // 拨打失败提示：idle 时清空，避免下次通话继承旧 error 文案
            self.lastError = ""
            // 2026-07-10 code-review P0-5 修复：跨通话公屏历史清空
            // 否则下通话 CallMessageScroller 会显示上通话残留 gift/text 行；
            // 配合 GiftEffectSysMsgRouter 内的 state gate（idle 期 backlog 不 append）双保险
            self.callChatMessages.removeAll()
        }
    }

    /// 接通率统一上报入口。
    /// ⚠️ state 守卫：joinRtc 失败 → endLocally → state=.ended 后，控制流回到
    /// acceptIncomingFromLive L414 / accept() L463 仍会继续执行 reportRate(.answered)，
    /// 污染后端接通率统计（虚假 abnormal=0）。守卫下沉到入口拦截抢跑。
    /// endLocally 内先关闭媒体并切 .ended，再用 allowEnded=true 上报结束桶，避免网络上报阻塞本地收尾。
    private func reportRate(category: CallRateCategory, type: CallRateType,
                            answerTime: Int, abnormal: Int,
                            allowEnded: Bool = false) async {
        guard allowEnded || (state != .ended && state != .idle && state != .failed) else {
            AppLogger.call.notice("⚠️ [CallStore] reportRate 抢跑拦截 state=\(self.state.rawValue, privacy: .public) cat=\(category.rawValue, privacy: .public)")
            return
        }
        guard callRateEnabled, !current.channelId.isEmpty else { return }
        await CallService.callRate(
            channelId: current.channelId,
            callType: type, category: category,
            answerTime: answerTime, userType: .anchor, abnormal: abnormal
        )
    }

    // MARK: - 内部：主叫超时

    private func startCallOutTimeout() {
        cancelCallOutTimeout()
        callOutTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CallTuning.callOutTimeoutSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.state == .calling, self.current.inOrOut == .out else { return }
            AppLogger.call.notice("⏰ [callOutTimeout] 主叫 30s 无应答 → 自动取消 remoteUid=\(self.current.remoteUserId, privacy: .private)")
            if let signaling = self.signaling {
                _ = await signaling.publish(self.buildMessage(action: .cancel))
            }
            self.sendCallNimSignal(.cancel)
            // 拨打失败提示：30s 无应答 → "对方无应答"
            self.lastError = L10n.callErrorRemoteNoAnswer
            // H5 handleCallingTimeout L540：timeout 桶 answerTime 字面 30
            await self.endLocally(reason: .userConcurrentCancel, rateCategory: .timeout, rateType: .caller, answerTime: 30, abnormal: 0)
        }
    }

    private func cancelCallOutTimeout() {
        callOutTimeoutTask?.cancel()
        callOutTimeoutTask = nil
    }

    /// 来电 30 秒未接听，按 H5 `callInCancel` 路径发 Reject，并记入被叫拒接桶。
    private func startCallInTimeout() {
        cancelCallInTimeout()
        callInTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CallTuning.callInTimeoutSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled,
                  self.state == .calling, self.current.inOrOut == .in else { return }
            let callId = self.current.callId
            AppLogger.call.notice("⏰ [callInTimeout] 来电 30s 未操作 → 自动拒接 remoteUid=\(self.current.remoteUserId, privacy: .private)")
            if let signaling = self.signaling {
                _ = await signaling.publish(self.buildMessage(action: .reject, rejectReason: "timeout"))
            }
            self.sendCallNimSignal(.reject)
            // publish 期间可能已收到对端 Cancel 或用户刚好点了接听；避免二次收尾覆盖新状态。
            guard self.state == .calling, self.current.inOrOut == .in, self.current.callId == callId else { return }
            self.lastError = L10n.callErrorRemoteNoAnswer
            await self.endLocally(reason: .localHangUp, rateCategory: .rejected, rateType: .callee, answerTime: 0, abnormal: 0)
        }
    }

    private func cancelCallInTimeout() {
        callInTimeoutTask?.cancel()
        callInTimeoutTask = nil
    }
}

// MARK: - CallSignalingDelegate（处理对端 RTM 信令）

extension CallStore: CallSignalingDelegate {
    func signaling(_ signaling: CallSignaling, didReceive message: CallMessage, from publisher: String) {
        guard let action = message.action else {
            AppLogger.call.notice("⚠️ [CallStore] 未知 action=\(message.messageAction, privacy: .public) from=\(publisher, privacy: .public)")
            return
        }
        Task { @MainActor in await self.handleRemote(action: action, message: message) }
    }

    func signalingDidDetectSameUidLogin(_ signaling: CallSignaling) {
        AppLogger.call.error("🚨 [CallStore] 同 UID 登录 — 主流程交给 SessionStore.logout")
        Task { @MainActor in SessionStore.shared.logout() }
    }

    private func handleRemote(action: CallAction, message msg: CallMessage) async {
        switch action {
        case .videoCall:   await handleIncomingVideoCall(msg)
        case .audioCall:   AppLogger.call.notice("⚠️ [CallStore] 收到 audioCall（C 不接入）from=\(msg.fromUserId, privacy: .private)")
        case .cancel:      await handleRemoteCancel(msg)
        case .accept:      await handleRemoteAccept(msg)
        case .reject:      await handleRemoteReject(msg)
        case .hangup:      await handleRemoteHangup(msg)
        }
    }

    /// F 里程碑辅助：向来电方发 busy reject（不改本端 state）。
    /// 用于 handleIncomingVideoCall 前置守卫失败时（App 后台 / 派对房私 call 已关 / queryCall 失败 / 非派对来电）。
    private func publishRejectBusy(msg: CallMessage, reason: String) async {
        guard let signaling else { return }
        let busy = CallMessage(action: .reject,
                               fromUserId: myUserId,
                               remoteUserId: msg.fromUserId,
                               callId: msg.callId,
                               rejectReason: reason,
                               rejectByInternal: 1)
        _ = await signaling.publish(busy)
    }

    private func handleIncomingVideoCall(_ msg: CallMessage) async {
        // 校验是发给本端的（**必须先于 permission gate** · v2 code-review 修复：原顺序会对非本端 msg
        // 发出错误 permission_denied reject，误挂断主叫方 A→Y 的合法通话）
        guard msg.remoteUserId == myUserId else {
            AppLogger.call.notice("⚠️ [CallStore] 来电 remoteUserId(\(msg.remoteUserId, privacy: .private)) 与本端(\(self.myUserId, privacy: .private)) 不符，忽略")
            return
        }
        guard !RobotCallStore.shared.blocksOtherCalls, !isStartingDirectCall else {
            AppLogger.call.notice("[CallStore] incoming call blocked: robot call or outgoing admission active")
            await publishRejectBusy(msg: msg, reason: "busy")
            return
        }
        // P 项目权限管理：三层防护 RTM 被动接收层 · 走统一 gate helper（不 assertionFailure · Finding 4/8）
        // guard 在 source 判定之前 → 覆盖所有 source（普通通话 / matchV4 派单 / 未来新增）
        // gate 内部已 log warning；额外 publishRejectBusy 向对端发信号防主叫方等待
        if !SelfPermissionBridge.shared.gate(.call, action: "incomingVideoCall(callId=\(msg.callId))") {
            await publishRejectBusy(msg: msg, reason: "permission_denied")
            return
        }
        // D 里程碑：直播态优先走"直播私 call 自动接听"分支（不弹浮层、无 UI 确认）
        // 协议保证：用户端在直播间内发起的拨打都视为直播私 call，无需在 RTM 协议层区分类型
        // weak liveStore 由 LiveRoomView/RootView 在直播态注入（对齐 AgoraManager.liveStore 模式）
        if let ls = liveStore, ls.state == .living, ls.callState == 0 {
            // v22 修：主播 privateCallOpen=false 时直接 busy reject
            // 对齐 H5 用户端在开关关闭时拨打按钮 disable；主播端多加一层防御（前端 UI 状态 stale / 后端广播漂移场景）
            guard ls.privateCallOpen else {
                AppLogger.call.notice("🚫 [CallStore] 直播态私 call 已关 → busy reject from=\(msg.fromUserId, privacy: .private)")
                if let signaling {
                    let busy = CallMessage(action: .reject,
                                           fromUserId: myUserId,
                                           remoteUserId: msg.fromUserId,
                                           callId: msg.callId,
                                           rejectReason: "busy",
                                           rejectByInternal: 1)
                    _ = await signaling.publish(busy)
                }
                return
            }
            AppLogger.call.debug("📞 [CallStore] 直播态收到私 call → 委托 LiveStore.pauseForCall")
            await ls.pauseForCall(msg: msg)
            return
        }

        // F 里程碑（spec §2.1 Flow B）：派对房态优先分支 —— 在 PK guard 之前。
        // PartyStore 是全局单例；roomState == .joined 才可能是派对房私 call 场景。
        //
        // 三层前置守卫（对齐安卓 PartyRoomDataManager.kt:662 + spec §7 B3/B5）：
        //   1. appForeground（App 后台一律 reject）
        //   2. partyPrivateCallOpen == 1（本地二次校验，对齐 LiveStore.privateCallOpen · P1-9）
        //   3. queryCall 返 callerType == 5（不为 5 → reject reason=party room reject non-party call）
        //      queryCall 超时/失败 → 保守 reject（spec §7 B19 P2-19）
        let partyStore = PartyStore.shared
        if partyStore.roomState == .joined {
            // 守卫 1: App 前台
            if UIApplication.shared.applicationState == .background {
                AppLogger.call.notice("🚫 [CallStore] 派对房 App 后台 → reject from=\(msg.fromUserId, privacy: .private)")
                await publishRejectBusy(msg: msg, reason: "background")
                return
            }
            // 守卫 2: queryCall 先判 callerType。最小化 Party 房收到普通通话时，
            // 应完整退房后落入标准来电流程；仅 PartyCall 才保留当前房内自动接听行为。
            let channelId = msg.fromRoomId ?? ""
            let callerType: Int?
            do {
                let resp = try await CallService.queryCall(fromUserId: msg.fromUserId, channelId: channelId)
                callerType = resp.callerType
            } catch {
                AppLogger.call.notice("🚫 [CallStore] 派对房 queryCall 超时/失败 → 保守 reject err=\(error.localizedDescription, privacy: .private)")
                await publishRejectBusy(msg: msg, reason: "queryCall_failed")
                return
            }
            if callerType == 5 {
                // 房间维度私 call 开关只约束 PartyCall。
                guard partyStore.roomInfo?.isPartyPrivateCallEnabled == true else {
                    AppLogger.call.notice("🚫 [CallStore] 派对房私 call 已关 → busy reject from=\(msg.fromUserId, privacy: .private)")
                    await publishRejectBusy(msg: msg, reason: "party_call_closed")
                    return
                }
                AppLogger.call.debug("📞 [CallStore] 派对房收到 PartyCall → 委托 PartyStore.pauseForCall")
                await partyStore.pauseForCall(msg: msg)
                return
            }
            guard partyStore.isMinimized else {
                AppLogger.call.notice("🚫 [CallStore] 派对房内非 PartyCall (callerType=\(callerType ?? -1, privacy: .public)) → reject")
                await publishRejectBusy(msg: msg, reason: "party room reject non-party call")
                return
            }
            AppLogger.call.info("[CallStore] minimized Party → leave before standard incoming call")
            await partyStore.leaveMinimizedRoom()
        }

        // L Gap-5：匹配态 auto-accept 时序改造 —— 不再"匹配态无脑 auto-accept"，
        // 改为"先走标准 .calling 拉 apiJoinCall 拿 source"（见下方 direct 路径 line ~1119 Task 尾部），
        // source==matchV4 && isMatchActive → 内部自动 accept；非 matchV4 → 保持 .calling 让用户手动选接听/拒绝。
        // 语义对齐 H5 useCallApi.js:485-488（拿到 source 才决定 matchState 迁移）。
        //
        // acceptIncomingFromMatch 保留但停用（仅供未来 dev tool / 手动调用）。
        // G M6 / spec §8.2：PK 期（matching/inviting/invited/starting/inPK/punishing/endingPK）显式 busy reject。
        // 现有的 `ls.callState == 0` 守卫在 PK 期 callState=2/3 会 fall through 到下面 `state == .idle` 分支，
        // 若 CallStore 也是 .idle 就会创建错通话（spec §B 警示）；本分支显式拦截。
        if let pk = pkStore, pk.state != .idle, pk.state != .failed {
            AppLogger.call.notice("⚠️ [CallStore] PK 中收到来电 pkState=\(pk.state.rawValue, privacy: .public) → 自动 busy reject")
            if let signaling {
                let busy = CallMessage(action: .reject,
                                       fromUserId: myUserId,
                                       remoteUserId: msg.fromUserId,
                                       callId: msg.callId,
                                       rejectReason: "busy",
                                       rejectByInternal: 1)
                _ = await signaling.publish(busy)
            }
            return
        }
        guard state == .idle else {
            AppLogger.call.notice("⚠️ [CallStore] 收到来电但本端非 idle（state=\(self.state.rawValue, privacy: .public)）→ 自动忙线拒绝")
            if let signaling {
                // H5 callApi.ts:813 _autoReject 用 rejectByInternal=Internal(1) + reason="busy"，
                // 不带 fromRoomId（Reject payload 与 H5 严格对齐）。
                let busy = CallMessage(action: .reject,
                                       fromUserId: myUserId,
                                       remoteUserId: msg.fromUserId,
                                       callId: msg.callId,
                                       rejectReason: "busy",
                                       rejectByInternal: 1)
                _ = await signaling.publish(busy)
            }
            return
        }

        // VideoCall 必须带 fromRoomId（被叫据此 join），缺则视为非法消息丢弃
        guard let fromRoomId = msg.fromRoomId, !fromRoomId.isEmpty else {
            AppLogger.call.notice("⚠️ [CallStore] VideoCall 缺 fromRoomId from=\(msg.fromUserId, privacy: .private) 丢弃")
            return
        }

        var info = CurrentCallInfo()
        info.frontGameType = .direct
        info.inOrOut = .in
        info.channelId = fromRoomId              // ⚠️ 被叫端 channelId 来自 fromRoomId
        info.callId = msg.callId                 // ⚠️ 整轮通话沿用主叫生成的 callId
        info.remoteUserId = msg.fromUserId
        info.callStartTime = Date().timeIntervalSince1970 * 1000
        current = info
        state = .calling
        startCallInTimeout()

        // 3s 超时拉对方资料（失败仅影响 UI 展示，不影响接通能力）
        Task { @MainActor in
            do {
                let r = try await CallService.joinCall(channelId: fromRoomId)
                // L 里程碑：无条件 assign source —— MatchStore 订阅此字段实时判定 matchState 迁移。
                // 若 source=='matchV4' → MatchStore 转 .matchingCalling；非 matchV4 → .matchingSuspended
                self.lastJoinCallSource = r.source
                guard self.state != .idle, self.state != .ended, self.state != .failed,
                      self.current.callId == msg.callId,
                      self.current.channelId == fromRoomId else { return }
                self.current.remoteYxAccid = r.yxAccid ?? self.current.remoteYxAccid
                self.current.remoteNickname = r.nickname ?? self.current.remoteNickname
                self.current.remoteIcon = r.icon ?? self.current.remoteIcon
                self.current.remoteLevelName = r.levelName ?? self.current.remoteLevelName
                self.current.remoteHeadFrame = r.headFrame ?? self.current.remoteHeadFrame
                self.current.remoteAge = r.age ?? self.current.remoteAge
                self.current.remoteCountryCode = r.countryCode ?? self.current.remoteCountryCode
                self.current.remoteVideoPrice = r.videoPrice ?? self.current.remoteVideoPrice
                self.sendCallNimSignal(.online)
                self.sendConnectedNimSignalIfPossible()

                // L Gap-5：匹配来电内部自动 accept（对齐前次 acceptIncomingFromMatch 语义，仅时序前移到 source 到达后）
                if r.source == "matchV4", self.isMatchActive?() == true,
                   self.state == .calling, self.current.callId == msg.callId {
                    AppLogger.call.debug("📞 [CallStore] matchV4 && matching → 内部自动接听")
                    await self.accept(auto: true)
                }
            } catch {
                // L 里程碑：joinCall 失败 → source 置 nil（MatchStore 保守视为非 matchV4）
                self.lastJoinCallSource = nil
                AppLogger.call.notice("⚠️ [CallStore] joinCall 拉对方资料失败/超时 channel=\(fromRoomId, privacy: .private) err=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// 处理 H5 `attachType=-3` 辅助信令。它不能直接驱动状态机，避免与 RTM 重复结束。
    func handleNimCallSignal(type: String, channelId: String, sender: String) {
        guard !channelId.isEmpty, channelId == current.channelId,
              !sender.isEmpty, sender == current.remoteYxAccid,
              let signal = CallNimType(rawValue: type) else { return }
        switch signal {
        case .online:
            AppLogger.call.debug("[CallStore] peer NIM online channel=\(channelId, privacy: .private)")
        case .reject:
            guard state == .calling, current.inOrOut == .out else { return }
            lastError = L10n.callErrorRemoteRejected
            AppLogger.call.debug("[CallStore] peer NIM reject; waiting for RTM authoritative end")
        case .cancel, .connected:
            AppLogger.call.debug("[CallStore] peer NIM signal type=\(type, privacy: .public); RTM owns state transition")
        case .hangUp:
            current.hangupReason = .remoteHangUp
            AppLogger.call.debug("[CallStore] peer NIM hangup recorded; waiting for RTM authoritative end")
        }
    }

    private func handleRemoteCancel(_ msg: CallMessage) async {
        guard state == .calling, current.callId == msg.callId else { return }
        AppLogger.call.notice("📥 [Signaling] handleRemoteCancel from=\(msg.fromUserId, privacy: .private) callId=\(msg.callId, privacy: .public) → endLocally")
        // H5 CALL_OVER_REASON_NUMBER 没有"远端取消"独立码，沿用 2 (remoteHangUp) 是历史选择。
        // H5 useCallApi.js remoteCancel：calling 阶段 callDuration → answerTime=sinceStartDuration
        await endLocally(reason: .remoteHangUp, rateCategory: .canceled, rateType: .callee, answerTime: current.sinceStartDuration, abnormal: 0)
    }

    private func handleRemoteAccept(_ msg: CallMessage) async {
        guard state == .calling, current.inOrOut == .out, current.callId == msg.callId else { return }
        cancelCallOutTimeout()
        state = .connecting
        await joinRtc(channel: current.channelId, rateType: .caller)
        // 主叫 callOut 时已 RTC join，若远端已先到（didJoinedOfUid 在 .calling 被门控），手动补升级
        if agora.remoteUid != 0, state == .connecting {
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            AppLogger.call.info("✅ [CallStore] 主叫收 Accept 后远端已在频道 → state=connected")
        }
    }

    private func handleRemoteReject(_ msg: CallMessage) async {
        guard state == .calling, current.inOrOut == .out, current.callId == msg.callId else { return }
        AppLogger.call.notice("📥 [Signaling] handleRemoteReject from=\(msg.fromUserId, privacy: .private) callId=\(msg.callId, privacy: .public) rejectReason=\(msg.rejectReason ?? "-", privacy: .public) rejectByInternal=\(msg.rejectByInternal ?? -1, privacy: .public) → endLocally")
        // 区分 busy vs rejected：H5 callApi.ts:813 _autoReject 用 rejectReason="busy" 表示对方通话中/PK 中/匹配中自动拒接
        if msg.rejectReason == "busy" {
            lastError = L10n.callErrorRemoteBusy
        } else {
            lastError = L10n.callErrorRemoteRejected
        }
        // H5 useCallApi.js remoteReject：calling 阶段 callDuration → answerTime=sinceStartDuration
        await endLocally(reason: .remoteHangUp, rateCategory: .rejected, rateType: .caller, answerTime: current.sinceStartDuration, abnormal: 0)
    }

    private func handleRemoteHangup(_ msg: CallMessage) async {
        guard state == .connecting || state == .connected, current.callId == msg.callId else { return }
        AppLogger.call.notice("📥 [Signaling] handleRemoteHangup from=\(msg.fromUserId, privacy: .private) callId=\(msg.callId, privacy: .public) elapsed=\(self.callElapsed, privacy: .public)s → endLocally")
        await endLocally(reason: .remoteHangUp, rateCategory: nil, rateType: .caller, answerTime: 0, abnormal: 0)
    }

    // MARK: - 通话计时 driver

    /// state didSet 钩子：根据状态转移启停 / 重置 `callElapsed`。
    /// - `.calling`：从 0 累加（主叫超时圆环 / 被叫等待时长）
    /// - `.connecting`：暂停 + 归 0（RTC 建链中不累加，对齐旧 view-state 初始 0 行为，
    ///   避免 `CallFaceTimeView` 在 `.connecting` 时显示 calling 阶段已累加的杂值）
    /// - `.connected`：重置 0 重启（通话时长起点）
    /// - `.ended` / `.idle` / `.prepared` / `.failed`：停止 + 归 0
    private func updateElapsedTimer(prev: CallState) {
        switch state {
        case .calling:
            callElapsed = 0
            startElapsedTask()
        case .connected:
            callElapsed = 0
            startElapsedTask()
        case .connecting, .ended, .idle, .prepared, .failed:
            elapsedTask?.cancel()
            elapsedTask = nil
            callElapsed = 0
        }
    }

    /// 来电铃声仅服务于前台普通被叫等待页；接通、结束、拒接和超时离开 `.calling` 时统一停止。
    private func updateAppSoundsForStateTransition() {
        let shouldRing = state == .calling
            && current.inOrOut == .in
            && current.frontGameType == .direct
        if shouldRing {
            AppSoundPlayer.shared.startIncomingCallRingtone()
        } else {
            AppSoundPlayer.shared.stopIncomingCallRingtone()
        }
    }

    private func startElapsedTask() {
        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                // H5 在充值等待期间传入 `time-stop`，通话时长不应继续增长。
                guard !self.isCallWaitLocked else { continue }
                self.callElapsed += 1
                // C-3 每秒 tick 后自检异常（内部 elapsed%10 门控 + state guard + alerted 保护）
                self.checkAbnormalIfNeeded()
                // C-4 Wave1 gap-009：私 call 300s 收益横幅倒计时（内部 state + frontGameType 守卫）
                self.tickLiveCallCountdownIfNeeded()
                // DM-20260616-003：黑屏空房间检测 10s 心跳（对齐 H5 topBar.vue tenSecondsCB）
                self.tickEmptyRoomDetectorIfNeeded()
            }
        }
    }

    /// 黑屏空房间检测 10s 心跳驱动（DM-20260616-003）。
    /// 仅 `.connected` 且 elapsed 是 10 的倍数时触发；detector 内部有 stopped / hungUp 幂等守卫。
    /// 对齐 H5 topBar.vue L162-169 `tenSecondsCB` 由 CCalculagraph 每 10s 回调。
    private func tickEmptyRoomDetectorIfNeeded() {
        // 每 10s log 一次触发情况（无论是否命中），让日志能证明 tick loop 在跑
        guard callElapsed >= CallEmptyRoomDetector.tickInterval,
              callElapsed % CallEmptyRoomDetector.tickInterval == 0 else { return }
        guard state == .connected else {
            AppLogger.call.notice("🩺 [tickEmptyRoom] elapsed=\(self.callElapsed, privacy: .public) SKIP (state=\(self.state.rawValue, privacy: .public) != connected)")
            return
        }
        AppLogger.call.notice("🩺 [tickEmptyRoom] elapsed=\(self.callElapsed, privacy: .public) state=connected frontGame=\(String(describing: self.current.frontGameType), privacy: .public) → schedule detector.tick")
        Task { @MainActor [weak self] in
            await self?.emptyRoomDetector.tick()
        }
    }
}

// MARK: - H M4：SystemMessageRouter sysMsg 通道入口（spec §3.1 / H 校验清单 §1.1.2 A 表）

extension CallStore {

    /// sysMsg -1：通话内远端文字消息。
    /// 对齐 H5 `message.js`：文字立即进入 `talkListInCall`，随后自动翻译并更新同一条；
    /// `chatBubble` 是发送方透传的九宫格图片 URL，不是本地样式编号。
    func handleRemoteText(_ text: String, chatBubble: String? = nil, sender: String) {
        guard !text.isEmpty,
              state == .connecting || state == .connected,
              (current.remoteYxAccid.isEmpty || sender == current.remoteYxAccid) else {
            return
        }
        callRecentRemoteText = text
        callChatBubble = chatBubble
        let sender = CallChatMessage.Sender(
            nickname: current.remoteNickname.isEmpty ? current.remoteUserIdString : current.remoteNickname,
            level: nil,
            isVip: false,
            isSpecial: false,
            chatBubble: chatBubble,
            nicknameColor: .default
        )
        let message = CallChatMessage.text(sender: sender, content: text, translation: nil)
        appendChatMessage(message)
        translateRemoteCallText(messageID: message.id, text: text)
        AppLogger.call.info("[CallStore] handleRemoteText len=\(text.count, privacy: .public) hasBubble=\(chatBubble?.isEmpty == false, privacy: .public)")
    }

    // MARK: - 公屏消息队列 append helper（Phase A3）

    /// 追加公屏消息 + 上限修剪（>callChatMessagesLimit 时 pop 头部）。
    func appendChatMessage(_ msg: CallChatMessage) {
        callChatMessages.append(msg)
        if callChatMessages.count > callChatMessagesLimit {
            callChatMessages.removeFirst(callChatMessages.count - callChatMessagesLimit)
        }
    }

    /// 主播本地回显（对齐 H5 sendMessage `talkListInCall.unshift({user:'my', ...})`）。
    func echoLocalChatText(_ text: String) {
        guard !text.isEmpty else { return }
        let mine = AnchorInfoStore.shared.mine
        let sender = CallChatMessage.Sender(
            nickname: mine?.nickname ?? "",
            level: mine?.level,
            isVip: false,
            isSpecial: false,
            chatBubble: AnchorInfoStore.shared.currentChatBubble,
            nicknameColor: .default,
            isSelf: true
        )
        appendChatMessage(.text(sender: sender, content: text, translation: nil))
    }

    /// 追加对方消息自动翻译结果（对齐 H5 收到 attachType=-1 后的 translateText）。
    /// 命中不到 msgId 或非 `.text` payload 时静默 no-op。
    func setChatTranslation(messageId: UUID, translation: String) {
        guard let idx = callChatMessages.firstIndex(where: { $0.id == messageId }) else { return }
        let old = callChatMessages[idx]
        guard case .text(let content, _) = old.payload else { return }
        callChatMessages[idx] = CallChatMessage(
            id: old.id,
            timestamp: old.timestamp,
            sender: old.sender,
            payload: .text(content: content, translation: translation)
        )
    }

    /// H5 收到 attachType=-1 后自动调 translateText；失败时保留原文，不影响通话公屏流。
    private func translateRemoteCallText(messageID: UUID, text: String) {
        let targetLanguage: String = {
            switch AppLocaleStore.shared.current {
            case .en: return "en"
            case .ar: return "ar"
            case .tr: return "tr"
            case .system: return Locale.current.language.languageCode?.identifier ?? "en"
            }
        }()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let credentials = await self.translatorCredentials() else {
                AppLogger.call.warning("[CallStore] auto translate unavailable: config missing")
                return
            }
            do {
                let translated = try await MicrosoftTranslateService.shared.translate(
                    text: text, targetLang: targetLanguage, key: credentials.key, area: credentials.area
                )
                self.setChatTranslation(messageId: messageID, translation: translated)
            } catch {
                AppLogger.call.warning("[CallStore] auto translate failed msgId=\(messageID.uuidString, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func translatorCredentials() async -> (key: String, area: String)? {
        if let key = AppConfigStore.shared.microsoftTranslatorKey,
           let area = AppConfigStore.shared.microsoftTranslatorArea,
           !key.isEmpty, !area.isEmpty {
            return (key, area)
        }

        await AppConfigStore.shared.activate()
        guard let key = AppConfigStore.shared.microsoftTranslatorKey,
              let area = AppConfigStore.shared.microsoftTranslatorArea,
              !key.isEmpty, !area.isEmpty else {
            return nil
        }
        return (key, area)
    }

    /// 已接通通话收到 P2P `SEND_GIFT` 时的唯一入口。
    ///
    /// 对齐 H5 `stores/modules/message.js`：只消费当前通话对端发来的礼物；
    /// `attachType=4` 的系统消息不带发送方，已接通时不能据此展示，避免其他用户礼物误覆盖。
    @discardableResult
    func handleRemoteGiftFromP2P(_ data: [String: Any], senderYxAccid: String) -> Bool {
        guard state == .connected,
              !current.callId.isEmpty,
              !current.remoteYxAccid.isEmpty,
              senderYxAccid == current.remoteYxAccid,
              let giftIcon = (data["giftIcon"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !giftIcon.isEmpty else {
            return false
        }

        // P2P 消息的发送方在 NIM envelope，不在 attach payload；补齐给通用特效 decoder。
        var payload = data
        if payload["fromAccid"] == nil {
            payload["fromAccid"] = senderYxAccid
        }
        appendChatGiftFromPayload(payload)
        let accepted = GiftEffectIntake.ingest(
            scene: .call,
            scopeId: current.callId,
            payload: payload,
            mineYxAccid: SessionStore.shared.user?.yxAccid ?? ""
        )
        AppLogger.call.info("[CallStore] P2P SEND_GIFT accepted effect=\(accepted, privacy: .public) scope=\(self.current.callId, privacy: .private)")
        return true
    }

    /// Party 私 call 的送礼仍由 Party 聊天室 `2049` 广播下发，不会经过 P2P `SEND_GIFT`。
    ///
    /// 仅接受当前通话对端送给当前主播的礼物：Party 房在通话覆盖期间仍持续收 2049，
    /// 不做双向校验会把房内其他人的送礼误显示到通话公屏。
    @discardableResult
    func handleRemoteGiftFromPartyBroadcast(_ data: [String: Any]) -> Bool {
        guard state == .connected,
              current.frontGameType == .party,
              !current.callId.isEmpty,
              isPartyCallGiftForCurrentParticipants(data),
              firstNonEmptyGiftImage(in: data) != nil else {
            return false
        }

        let sendUser = data["sendUser"] as? [String: Any]
        let senderYxAccid = firstNonEmptyString(
            data["senderYxAccid"], data["sendYxAccid"], sendUser?["yxAccid"]
        )
        var payload = data
        // 2049 把发送人嵌在 sendUser；通用通话解码器读取顶层字段，补齐后复用同一特效/公屏链路。
        if let senderYxAccid {
            payload["fromAccid"] = senderYxAccid
            payload["senderYxAccid"] = senderYxAccid
        } else if !current.remoteYxAccid.isEmpty {
            // joinCall 尚未返回时可只靠 userId 完成参与者校验；此处绝不写入空账号。
            payload["fromAccid"] = current.remoteYxAccid
            payload["senderYxAccid"] = current.remoteYxAccid
        }
        if firstNonEmptyString(payload["senderNickname"]) == nil {
            payload["senderNickname"] = sendUser?["nickname"]
        }
        if firstNonEmptyString(payload["senderAvatar"]) == nil {
            payload["senderAvatar"] = sendUser?["avatar"]
                ?? sendUser?["icon"]
                ?? sendUser?["userAvatar"]
        }

        let accepted = GiftEffectIntake.ingest(
            scene: .call,
            scopeId: current.callId,
            payload: payload,
            mineYxAccid: SessionStore.shared.user?.yxAccid ?? ""
        )
        guard accepted else { return false }

        appendChatGiftFromPayload(payload)
        AppLogger.call.info(
            "[CallStore] Party 2049 gift displayed scope=\(self.current.callId, privacy: .private)"
        )
        return true
    }

    private func isPartyCallGiftForCurrentParticipants(_ data: [String: Any]) -> Bool {
        let sendUser = data["sendUser"] as? [String: Any]
        let senderYxAccid = firstNonEmptyString(
            data["senderYxAccid"], data["sendYxAccid"], sendUser?["yxAccid"]
        )
        let senderUserId = firstNonEmptyString(
            data["senderUserId"], data["sendUserId"], sendUser?["userId"]
        )

        if let senderYxAccid, !current.remoteYxAccid.isEmpty {
            guard senderYxAccid == current.remoteYxAccid else { return false }
        } else if let senderUserId {
            guard senderUserId == String(current.remoteUserId) else { return false }
        } else {
            return false
        }

        guard let recipients = data["receiveUserList"] as? [[String: Any]],
              !recipients.isEmpty else {
            return false
        }
        let myUserId = SessionStore.shared.user?.userId.map(String.init)
        let myYxAccid = firstNonEmptyString(SessionStore.shared.user?.yxAccid)
        return recipients.contains { recipient in
            let recipientUserId = firstNonEmptyString(recipient["userId"])
            let recipientYxAccid = firstNonEmptyString(recipient["yxAccid"])
            if let myUserId, recipientUserId == myUserId { return true }
            if let myYxAccid, recipientYxAccid == myYxAccid { return true }
            return false
        }
    }

    private func firstNonEmptyGiftImage(in payload: [String: Any]) -> String? {
        firstNonEmptyString(payload["smallImg"], payload["giftSmallImg"], payload["giftImg"], payload["giftIcon"])
    }

    private func firstNonEmptyString(_ values: Any?...) -> String? {
        values.lazy.compactMap { value in
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let number = value as? NSNumber, !(number is Bool) {
                return number.stringValue
            }
            if let integer = value as? Int { return String(integer) }
            if let integer = value as? Int64 { return String(integer) }
            return nil
        }.first
    }

    /// 通话公屏礼物 append helper。
    /// 图片优先 giftSmallImg / smallImg，缺失时回退 giftImg / giftIcon。
    func appendChatGiftFromPayload(_ data: [String: Any]) {
        // 图片：H5 messageScroller line 11 优先 giftSmallImg，缺则 giftImg
        let img = (data["giftSmallImg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
              ?? (data["smallImg"] as? String)
              ?? (data["giftImg"] as? String)
              ?? (data["giftIcon"] as? String)
              ?? ""
        guard !img.isEmpty else { return }
        // 数量兼容 Int / String
        let num: Int = {
            if let n = data["giftNum"] as? Int { return max(1, n) }
            if let s = data["giftNum"] as? String, let n = Int(s) { return max(1, n) }
            return 1
        }()
        let nickname = (data["senderNickname"] as? String)
            ?? (data["nickName"] as? String)
            ?? current.remoteNickname
        let sender = CallChatMessage.Sender(
            nickname: nickname,
            level: nil,
            isVip: false,
            isSpecial: false,
            chatBubble: nil,
            nicknameColor: .default
        )
        appendChatMessage(.gift(sender: sender, imageURL: img, count: num))
    }

    /// sysMsg -6：通话充值等待状态变更（type 1/2/3/4）。
    /// C-5 状态机：type=1/3 启 60s+5s 兜底 timer；type=2 补偿 elapsed + 2s 后弹 Congrats；
    /// type=4 或 0 清 timer。仅 .connecting/.connected 有效（.calling 期避免抢跑）。
    func updateWaitState(type: Int) {
        let prev = callWaitState
        callWaitState = type
        AppLogger.call.info("[CallStore] updateWaitState type=\(type, privacy: .public) prev=\(prev, privacy: .public)")
        // C-5 R5：非通话中不启动 timer（防抢跑）
        guard state == .connecting || state == .connected else {
            AppLogger.call.warning("[CallStore] updateWaitState skip state=\(String(describing: self.state), privacy: .public)")
            return
        }
        switch type {
        case 1, 3: startCallWaitLockTimer(reason: type)
        case 2:    handlePaySuccess()
        case 4, 0: cancelCallWaitLockTimer()
        default:   break
        }
    }

    // MARK: - C-5 充值锁定 timer / 补偿 / Congrats

    /// 启动主段 + 5s 兜底段 auto hangup（H5 topBar.vue waitRechargeTimer + 5s fallback）。
    /// 主段秒数：v26（2026-07-15）从 `AppConfigStore.callWaitTime` 读（H5 `call_config.call_wait_time`），
    /// 后端未配置或未拉到时用 `callWaitPrimarySeconds`=60 本地兜底（对齐 H5 topBar.vue:20 `|| 60`）。
    /// 幂等：重复 START_PAY / CALL_TIME_END cancel 旧 task 重启。
    private func startCallWaitLockTimer(reason: Int) {
        callWaitTimerTask?.cancel()
        // v26.1（2026-07-16）review 修：等价 JS `|| 60` 语义，`0 / 负数 / nil` 全部回落
        // （原 `?? 60` 只兜 nil，后端错配 0 会导致空循环 → 立即 5s auto hangup 秒挂断）
        let rawSeconds = AppConfigStore.shared.callWaitTime ?? Self.callWaitPrimarySeconds
        let primarySeconds = rawSeconds > 0 ? rawSeconds : Self.callWaitPrimarySeconds
        callWaitCountdown = primarySeconds
        AppLogger.call.info("[CallStore] callWaitLockTimer start reason=\(reason, privacy: .public) \(primarySeconds, privacy: .public)s+\(Self.callWaitFallbackSeconds, privacy: .public)s")
        callWaitTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<primarySeconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.callWaitCountdown = max(0, self.callWaitCountdown - 1)
            }
            // 5s 兜底段
            try? await Task.sleep(nanoseconds: UInt64(Self.callWaitFallbackSeconds) * 1_000_000_000)
            if Task.isCancelled { return }
            AppLogger.call.notice("⏰ [CallStore] callWaitLockTimer 兜底到期 → auto hangup")
            await self.hangup()
        }
    }

    /// PAY_SUCCESS：清 timer。通话时长在锁定期间已暂停，因此不需要事后补偿。
    /// 保持 H5 解锁动画结束后再展示 Congrats 的 2s 时序。
    private func handlePaySuccess() {
        cancelCallWaitLockTimer()
        let bonus = callWaitBonus  // 快照本次奖励值供 2s 后弹窗读
        lastCongratsBonus = bonus
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.congratsBonusDelaySeconds * 1_000_000_000))
            guard let self, self.state == .connecting || self.state == .connected else { return }
            // H5 在解锁动画完成后清空 waitState；避免顶部等待状态残留到后续正常通话。
            if self.callWaitState == 2 {
                self.callWaitState = 0
            }
            self.congratsBonusToken = UUID()
        }
    }

    /// 清 timer + 归 0（PAY_CANCEL / type=0 / endLocally）。幂等。
    private func cancelCallWaitLockTimer() {
        callWaitTimerTask?.cancel()
        callWaitTimerTask = nil
        callWaitCountdown = 0
    }

    /// Congrats sheet dismiss 触发（用户点 OK 或 drag dismiss）
    func dismissCongratsBonus() {
        congratsBonusToken = nil
    }

    /// sysMsg 15：通话每分钟预估收入累加。
    func appendCallIncome(num: Int) {
        guard num > 0 else { return }
        current.callIncome += num
        AppLogger.call.info("[CallStore] appendCallIncome +\(num, privacy: .public) total=\(self.current.callIncome, privacy: .public)")
    }

    /// sysMsg 18：通话礼物预估收入累加。
    func appendGiftIncome(num: Int) {
        guard num > 0 else { return }
        current.callGiftIncome += num
        AppLogger.call.info("[CallStore] appendGiftIncome +\(num, privacy: .public) total=\(self.current.callGiftIncome, privacy: .public)")
    }

    /// sysMsg 90：通话充值成功钻石奖励累加（H5 callWaitBonus）。
    func appendWaitBonus(num: Int) {
        guard num > 0 else { return }
        callWaitBonus += num
        AppLogger.call.info("[CallStore] appendWaitBonus +\(num, privacy: .public) total=\(self.callWaitBonus, privacy: .public)")
    }

    /// 主播发送公屏文字消息（Phase C：对齐 H5 g-faceTime/index.vue:122-153 sendMessage）。
    /// 双动作：
    /// 1. 立即本地 echo（`echoLocalChatText`，对齐 H5 `talkListInCall.unshift`——不等 NIM 回执）
    /// 2. NIM custom P2P system notification attachType=-1 发送到 `current.remoteYxAccid`，携带 ext.userLevel/fromNickName/chatBubble
    ///    （对齐 H5 sendImMsg 参数结构，供对端 msgItem 用来渲染气泡背景 + nav 徽章）
    /// 发送失败仅日志、不 rollback echo（H5 同款语义；Wave 6 补 send fail toast）。
    func sendCallText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let peer = current.remoteYxAccid
        guard !peer.isEmpty else {
            AppLogger.call.warning("[CallStore] sendCallText skip: remoteYxAccid empty")
            return
        }
        // 1. 本地回显（先做，UI 即时反馈）
        echoLocalChatText(trimmed)
        // 2. H5 `homeStore.sendImMsg` 使用 customP2p system message；收端由 NIMService
        //    的系统通知 delegate 分发给 SystemMessageRouter，不能改用普通 NIMChat 消息。
        let mine = AnchorInfoStore.shared.mine
        let encodedNickname = mine?.nickname?.addingPercentEncoding(withAllowedCharacters: .callMessageNicknameAllowed) ?? ""
        let payload: [String: Any] = [
            "attachType": -1,
            "content": trimmed,
            "ext": [
                "userLevel": mine?.level ?? 0,
                "fromNickName": encodedNickname,
                "chatBubble": AnchorInfoStore.shared.currentChatBubble ?? ""
            ]
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            AppLogger.call.warning("[CallStore] sendCallText JSON encode failed")
            return
        }
        let notification = NIMCustomSystemNotification(content: jsonStr)
        // H5 未限制仅在线用户，离线期间由 NIM 按系统消息语义补发。
        notification.sendToOnlineUsersOnly = false
        let session = NIMSession(peer, type: .P2P)
        NIMSDK.shared().systemNotificationManager.sendCustomNotification(notification, to: session) { error in
            if let error {
                AppLogger.call.error("[CallStore] sendCallText FAIL peer=\(peer, privacy: .private) err=\(error.localizedDescription, privacy: .private)")
            } else {
                AppLogger.call.info("[CallStore] sendCallText OK peer=\(peer, privacy: .private) len=\(trimmed.count, privacy: .public)")
            }
        }
    }
}

private extension CharacterSet {
    /// 对齐 JavaScript `encodeURIComponent`：昵称不允许让 JSON/P2P 消息字段产生歧义。
    static let callMessageNicknameAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
}
