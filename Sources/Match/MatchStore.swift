import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "MatchStore")

// MARK: - CallStore observer 抽象（U3：解耦 MatchStore 与具体 CallStore 类型）

/// 供 MatchStore 观察 CallStore 状态 + lastJoinCallSource 的最小抽象。
/// 生产由 `MatchStore.attachCallStoreBridge(...)` 从 App 层注入（非直接引 CallStore.shared，
/// 避免 test target 循环依赖）。
@MainActor
protocol MatchCallStoreObserving: AnyObject {
    /// CallStore.$state Combine publisher 快照
    var stateChangePublisher: AnyPublisher<Bool /* isConnectingOrLater */, Never> { get }
    /// CallStore.$lastJoinCallSource publisher（'matchV4' / 'liveCall' / nil / 其他）
    var lastJoinCallSourcePublisher: AnyPublisher<String?, Never> { get }
    /// CallStore.$state 转 .idle publisher（用于通话结束回 .matching 判定）
    var stateReturnedToIdlePublisher: AnyPublisher<Void, Never> { get }
    /// Gap-5：CallStore.$state 进入 .connected 的边（用于 wasConnectedInCall 打标）
    var enteredConnectedPublisher: AnyPublisher<Void, Never> { get }
    /// 快照最近一次 lastJoinCallSource（供 idle 时读取）
    var latestJoinCallSource: String? { get }
    /// P2-1 对齐 H5 useCallApi.js:397：本次通话结束是否是异常出错路径
    /// （对应 CallOverReason.beginCallError —— RTC/RTM/信令建链失败）。
    /// MatchStore 在 .matchingCalling → .idle 时读此值判定：true 时走"关匹配"（H5 保守策略），
    /// false 时按 source 走 resume/keep 逻辑。**不暴露 CallOverReason 类型**保持 test module 隔离。
    var latestHangupWasError: Bool { get }
}

// MARK: - 状态机 · Match 4 态 + 独立维度 isMatchBlocked

/// L 里程碑：视频匹配状态机。4 态 + `isMatchBlocked` 持久化维度。
///
/// 详见 `docs/plan/L-spec-视频匹配Match-*.md` §2.1 状态机图 + §2.2 跨模块状态联动。
enum MatchState: Equatable {
    /// 初始/关闭态。用户可点开启（可能是冷启动首次 or blocked 清后）。
    case ended
    /// 已开启匹配池 + 摄像头预览中。
    case matching
    /// 匹配命中后接通中/通话中。CallStore 主控此态期间。
    case matchingCalling
    /// 被封禁（超次数 / 人脸识别失败）。isMatchBlocked=true UserDefaults 持久化。
    /// 出口边：用户主动点击 → isOpen 返 1 才清 blocked → .matching。
    case blocked
    /// Gap-5：匹配中收到**非** matchV4 来电时的暂停态（对齐 H5 MATCHING_LEFT 但语义更精细）。
    /// - 摄像头已关、服务端 toggleMatch(0) 已上报（退池）
    /// - 保留"用户曾在匹配"意图 —— 通话结束时按分支恢复：
    ///     - 用户直接拒绝（未接通 = `wasConnectedInCall==false`）→ 自动 openMatch
    ///     - 用户接通后挂断（`wasConnectedInCall==true`）→ 弹 Resume Match Alert，用户确认后 openMatch
    case matchingSuspended
}

// MARK: - MatchCameraSession protocol · step 1b 具体实现

/// 匹配态独立摄像头会话（脱离直播/通话的新形态）。
///
/// **实现细节**：MatchCameraSession 内部封装独立 `CameraManager()` 实例（对齐现有 LiveRoomView/CallView 6 处模式，
/// **非** App 全局共享 session）。Match 会话生命周期 = 内部 CameraManager 生命周期。命中接通时移交 = Match 停 session，
/// CallView 起自己的 session（视觉上短暂 300-500ms 空档，掩盖在 g-waitingCall 过渡）。
///
/// step 1a 只做 protocol 抽象；step 1b UI 阶段落地具体实现（含 subscribe frame sink）。
@MainActor
protocol MatchCameraSessionProtocol: AnyObject {
    /// 会话是否运行中（session.isRunning 镜像）
    var isRunning: Bool { get }

    /// interruption 累计未恢复时长（对齐 CameraManager.$interruptionUnrecoveredDuration）
    var interruptionUnrecoveredDuration: TimeInterval { get }

    /// 启动 session（若未 running）
    func start()

    /// 停止 session + 释放订阅
    func stop()

    /// interruption 持续超时 published（>= 30s 时 fire）
    var timedOutPublisher: AnyPublisher<Void, Never> { get }

    /// 相机错误 published（权限拒绝 / 开启超时 3s / runtime error）
    var errorPublisher: AnyPublisher<MatchCameraError, Never> { get }
}

enum MatchCameraError: Equatable {
    case permissionDenied
    case startTimeout       // 3s 未 running / 未收到首帧
    case runtimeError(String)
}

// MARK: - MatchStore

/// 视频匹配 Match 状态机 store。
///
/// 责任：
/// - 维护 `state` (MatchState) + `isMatchBlocked` (独立持久化维度)
/// - 编排 openMatch / closeMatch / handleBlocked / handleIMOffline / observeCallStore
/// - 订阅 CallStore.$lastJoinCallSource + CallStore.$state + NIMService.$connectionState + MatchCameraSession
///
/// **不变量**：
/// - `.matching` 时 cameraSession 必 running；反之必 stop
/// - `.matchingCalling` 期间 CGoMatchButton 不 render（UI 层负责）
/// - `.blocked` 不允许自动恢复到 .ended，仅在用户点击 + isOpen 返 1 时清
/// - `lastJoinCallSource` 只在 CallStore 存（single source of truth）
@MainActor
final class MatchStore: ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var state: MatchState = .ended

    /// 封禁位（UserDefaults 持久化）。**独立维度**：与 state 交互但非 state 的一部分。
    /// 影响冷启动 state 初值 + `.blocked` 按钮 UI 可见性。
    @Published private(set) var isMatchBlocked: Bool = false

    /// 是否已弹过今日规则弹窗（内存态；根据 UserDefaults.ruleAgreedDate 计算）
    @Published private(set) var isFirstMatchToday: Bool = true

    /// 是否已勾选"今日不再提醒"（UserDefaults 持久化镜像）
    @Published private(set) var todayNoReminderChecked: Bool = false

    /// 最近一次错误提示（供 UI toast 展示，一次性；view 端 onReceive 后置 nil）。
    /// **enum 而非 String**：Store 不依赖 L10n（test target 独立 module 限制），
    /// UI 层通过 `MatchToast+Localized` extension 走 L10n 映射到展示文案。
    @Published var lastToast: MatchToast?

    /// #3d：未露脸弹窗（5s 倒计时）—— .matching 期间人脸检测未检出时 UI 层弹此提示
    @Published var showNoFacePopup: Bool = false
    /// #3d：移除匹配弹窗 —— 未露脸倒计时结束仍未检测到脸 → 强制 blocked 后展示
    @Published var showExitMatchPopup: Bool = false

    /// Gap-5：Resume Match 确认 Alert 展示态。
    /// 触发：`.matchingSuspended` 期间用户接通过（wasConnectedInCall=true）→ 通话结束时置 true；UI 层观察展示 Alert
    @Published var showResumeMatchAlert: Bool = false

    /// Gap-5：本轮"暂停期"通话是否曾进入 .connected（区分"直接拒绝" vs "接通后挂断"）
    /// - `false`：CallStore 从 .calling/.incoming 直接归 .idle（用户点拒绝 / 主叫取消 / 超时）→ 通话结束自动 openMatch
    /// - `true`：CallStore 经过 .connected → 弹 Resume Match Alert 由用户确认
    private var wasConnectedInCall: Bool = false

    // MARK: - 依赖

    private let service: MatchServiceProtocol
    /// 匹配态摄像头会话（U1/U2 落地后 strong 持有；spec BL-1 review S-7：避免 View dismiss
    /// 后 weak 立即 nil，摄像头资源需由 Store 主动 collapse 而非依赖 view 生命周期）
    private var cameraSession: MatchCameraSessionProtocol?

    /// #3d：人脸检测 service（stub 默认 true，J 里程碑替换真 FUManager 桥）
    private let faceDetection: FaceDetectionServiceProtocol
    /// 30s 首次检测 timer + 3 次随机检测 timer 统一取消 task
    private var faceCheckTask: Task<Void, Never>?
    /// 5s 未露脸倒计时 task
    private var noFaceCountdownTask: Task<Void, Never>?

    /// 单例（对齐 CallStore.shared / LiveStore.shared / PartyStore.shared 模式）
    static let shared = MatchStore(service: MatchService.shared, faceDetection: FaceDetectionServiceStub.shared)

    /// 依赖注入 init（供单测传 Fake）。生产用 `.shared`。
    init(service: MatchServiceProtocol,
         faceDetection: FaceDetectionServiceProtocol = FaceDetectionServiceStub.shared) {
        self.service = service
        self.faceDetection = faceDetection
        loadFromPersistence()
    }

    // MARK: - 冷启动加载

    /// 冷启动读 UserDefaults（v3 §2.3 不变量：isMatchBlocked=true → matchState=.blocked）。
    private func loadFromPersistence() {
        let persisted = MatchPersistedStore.load()
        isMatchBlocked = persisted.isMatchBlocked
        todayNoReminderChecked = persisted.todayNoReminderChecked
        isFirstMatchToday = MatchDateHelper.isFirstToday(savedDate: persisted.ruleAgreedDate)

        if persisted.isMatchBlocked {
            state = .blocked
        } else {
            state = .ended
        }
        logger.info("loadFromPersistence: state=\(String(describing: self.state)) blocked=\(persisted.isMatchBlocked) firstToday=\(self.isFirstMatchToday) noReminder=\(persisted.todayNoReminderChecked)")
    }

    // MARK: - 依赖注入 & 事件订阅

    private var cameraCancellables = Set<AnyCancellable>()
    private var callStoreCancellables = Set<AnyCancellable>()
    private var nimCancellables = Set<AnyCancellable>()

    /// Gap-2：openMatch 前置 IM 在线 gate。app 层注入 `{ NIMService.shared.connectionState == .connected }`；
    /// nil = 未注入（test 场景）时默认放行。对齐 H5 c-goMatch.vue:394-395 语义（iOS 无 setIMOnline API，只 gate）
    var nimOnlineProvider: (() -> Bool)?

    /// 用户诉求 2026-07-08：openMatch 起手若用户处于 offline（`OnlineStatusStore.userSetOnline == false`）
    /// → 自动上线，无需用户先手动切在线。
    /// **返回值**：`true` 表示刚从 offline 切到 online（用户明确意图）；openMatch 据此 skip IM gate
    /// —— 用户既然主动 tap 匹配 + hook 已切在线，即便 NIMSDK 短暂未连（自动重连中）也应让 toggleMatch(1)
    /// 走完，避免"我切在线了但匹配没开"的困惑。
    /// nil = 未注入（test 场景）时视作 no-op（返 false，不 skip gate）。
    var ensureUserOnlineHook: (() -> Bool)?

    /// U1/U2：MatchTabView.onAppear 挂载摄像头会话；同时订阅 timedOut/error publishers 转发到状态机
    func attachCameraSession(_ session: MatchCameraSessionProtocol) {
        // 幂等：同一 session 重挂 no-op
        if self.cameraSession === session { return }
        self.cameraSession = session
        cameraCancellables.removeAll()

        // interruption 累计 >= 30s → R9 关匹配
        session.timedOutPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleCameraInterruptionTimeout()
            }
            .store(in: &cameraCancellables)

        // 摄像头错误（permissionDenied / startTimeout / runtimeError）→ R5/R6
        session.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                switch err {
                case .permissionDenied, .startTimeout:
                    self?.handleCameraStartTimeout()
                case .runtimeError:
                    self?.handleCameraInterruptionTimeout()
                }
            }
            .store(in: &cameraCancellables)
    }

    /// U4：NIM 长连接掉线观察（disconnected/idle publisher）。App 层构造 bridge 后注入。
    func attachNIMConnectionBridge(_ disconnectedPublisher: AnyPublisher<Void, Never>) {
        nimCancellables.removeAll()
        disconnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleIMOffline()
            }
            .store(in: &nimCancellables)
    }

    /// U3：CallStore observer 桥接。App 层构造 bridge 后调此方法注入。
    func attachCallStoreBridge(_ observer: MatchCallStoreObserving) {
        callStoreCancellables.removeAll()

        // CallStore.state 转 .connecting/.connected → 无条件 unsubscribe MatchCameraPreview（让 CallView 独占）
        observer.stateChangePublisher
            .filter { $0 }  // isConnectingOrLater = true
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleCallStoreLeavingIdle()
            }
            .store(in: &callStoreCancellables)

        // joinCall.source 到达 → matchV4 → .matchingCalling；非 matchV4 → 强制 .ended
        observer.lastJoinCallSourcePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                self?.handleJoinCallSource(source)
            }
            .store(in: &callStoreCancellables)

        // CallStore.state → .idle → 若 lastJoinCallSource=='matchV4' 回 .matching + 重启 camera
        // P2-1：同时读 latestHangupWasError，出错时走"关匹配"分支（对齐 H5 useCallApi.js:397）
        observer.stateReturnedToIdlePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak observer] in
                self?.handleCallStoreReturnedToIdle(
                    lastJoinCallSource: observer?.latestJoinCallSource,
                    lastCallError: observer?.latestHangupWasError ?? false
                )
            }
            .store(in: &callStoreCancellables)

        // Gap-5：CallStore 进入 .connected 边 → 打 wasConnectedInCall 标（用于 suspended → alert 分流）
        observer.enteredConnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.state == .matchingSuspended else { return }
                self.wasConnectedInCall = true
            }
            .store(in: &callStoreCancellables)
    }

    // MARK: - 主命令：开启 / 关闭

    /// 用户点开启按钮的入口。可能来自 `.ended / .blocked` 态。
    ///
    /// v3 §5.1 F3 修正后的顺序（**删除 beauty pre-check**，见 RA21）：
    /// `isOpen 返 1 → toggleMatch(1) 返 1 → cameraSession.start() → matchState=.matching`
    func openMatch() async {
        // P 项目权限管理：.call bit 覆盖匹配 · 走统一 gate helper（不 assertionFailure · Finding 4/8）
        // v2 code-review: gate 拒绝时 set lastToast 让 UI 有反馈（对齐同函数其他失败分支 pattern），
        // 复用 .networkError case 避免暴露 blacklist 状态（spec §6.1 fail-secure）。
        // 路径：MatchTipPopup 10 分钟弹（不查 canCall）+ optimistic init tab bar 视觉 race → 用户 tap "Go Match"
        guard SelfPermissionBridge.shared.gate(.call, action: "openMatch") else {
            lastToast = .networkError
            return
        }
        // 只有 .ended / .blocked 允许发起（.matching / .matchingCalling 期间按钮不 render,理论到不了这里）
        guard state == .ended || state == .blocked else {
            logger.warning("openMatch called in unexpected state=\(String(describing: self.state))")
            return
        }

        // 用户诉求 2026-07-08：offline 时自动上线（对齐 H5 !IMOnline && setIMOnline(true) 语义）
        // 用户主动开匹配 = 想接来电 → 自动切在线；比 gate 后要求"先手动上线"体验更好
        _ = ensureUserOnlineHook?()

        // 2026-07-09 修：删掉 IM connectionState gate。原 gate 只放行 .connected，误伤 .connecting/.reconnecting
        // 中间态导致用户点匹配看到 "Reconnecting, please try again" 无法开启。
        // 对齐 H5 语义：H5 无此 gate（仅 setIMOnline(true) 主动上线）；NIMSDK 自动重连很快，
        // toggleMatch(1) 服务端接单后即便 NIM 短暂未连也不影响；nimOnlineProvider 保留供未来其他 caller 复用。

        // 1) isOpen 前置校验
        let canOpen: MatchCanOpenResult
        do {
            canOpen = try await service.isMatchOpen()
        } catch {
            logger.error("openMatch isOpen network failed: \(String(describing: error))")
            lastToast = .networkError  // R3：网络失败保持当前态 + toast
            return
        }

        switch canOpen {
        case .allowed:
            // 若原态为 .blocked → 清 blocked（v3 §5.1 F14 出口边）
            if isMatchBlocked {
                isMatchBlocked = false
                MatchPersistedStore.saveIsMatchBlocked(false)
                logger.info("openMatch: isOpen returned allowed, cleared isMatchBlocked")
            }
        case .faceCheckFailed:
            handleBlocked(reason: .noFaceDetected)
            return
        case .exceededCount:
            handleBlocked(reason: .exceedCount)
            return
        }

        // 2) toggleMatch(1)
        let ok: Bool
        do {
            ok = try await service.toggleMatch(status: 1, faceCheckStatus: nil)
        } catch {
            logger.error("openMatch toggleMatch failed: \(String(describing: error))")
            lastToast = .networkError  // R4
            return
        }
        guard ok else {
            lastToast = .turnOnFailed
            return
        }

        // 3) 状态转 .matching（先切态后开相机）
        state = .matching
        logger.info("openMatch: state → .matching")

        // 4) 启动 cameraSession（若失败走 R6 3s 超时回滚，见 handleCameraStartTimeout）
        cameraSession?.start()

        // 5) 更新首日规则日期
        let today = MatchDateHelper.todayString()
        MatchPersistedStore.saveRuleAgreedDate(today)
        isFirstMatchToday = false

        lastToast = .turnOnSucceed

        // #3d：启动人脸检测（30s 首次 + 3 次随机 2-30s 内）
        startFaceCheckAfterOpenMatch()
    }

    /// 用户主动关匹配。
    /// - Parameter silent: `true` 时不展示 `turnOffSucceed` toast —— 用于"进直播/派对房/通话前自动关"这类
    ///   隐式关匹配场景（用户已明确进入其他业务，不需要再看"匹配已关"提示）。默认 `false` 兼容现有 UI。
    func closeMatch(silent: Bool = false) async {
        guard state == .matching else {
            logger.warning("closeMatch called in unexpected state=\(String(describing: self.state))")
            return
        }

        stopFaceCheck()  // #3d：关匹配同步停人脸检测
        cameraSession?.stop()
        state = .ended

        // 后端上报关匹配（fire-and-forget；失败不影响本地态）
        Task { [service] in
            do {
                _ = try await service.toggleMatch(status: 0, faceCheckStatus: nil)
                logger.info("closeMatch: server toggleMatch(0) success (silent=\(silent))")
            } catch {
                logger.warning("closeMatch: server toggleMatch(0) failed: \(String(describing: error))")
            }
        }

        if !silent { lastToast = .turnOffSucceed }
    }

    // MARK: - 被动关匹配路径

    /// 被后端拒绝 or 人脸失败 → 进 .blocked 态。
    private func handleBlocked(reason: MatchToast) {
        cameraSession?.stop()
        isMatchBlocked = true
        MatchPersistedStore.saveIsMatchBlocked(true)
        state = .blocked
        lastToast = reason
        // **不调 toggleMatch**（后端已明示拒绝，见 v3 §2.2）
        logger.info("handleBlocked: state → .blocked reason=\(String(describing: reason))")
    }

    /// R6：cameraSession 开启超时（3s 未 running / 未收到首帧）→ 回滚 matchState=.ended + 补发 toggleMatch(0)。
    func handleCameraStartTimeout() {
        guard state == .matching else { return }
        logger.warning("handleCameraStartTimeout: rollback state → .ended")
        cameraSession?.stop()
        state = .ended
        lastToast = .cameraStartFailed

        // 补发 toggleMatch(0) 回滚服务端（fire-and-forget）
        Task { [service] in
            _ = try? await service.toggleMatch(status: 0, faceCheckStatus: nil)
        }
    }

    /// R9：cameraSession interruption 累计 >= 30s → 强制关匹配。
    func handleCameraInterruptionTimeout() {
        guard state == .matching else { return }
        logger.warning("handleCameraInterruptionTimeout: state → .ended")
        cameraSession?.stop()
        state = .ended
        lastToast = .cameraUnavailable

        // 补发 toggleMatch(0) 回滚服务端
        Task { [service] in
            _ = try? await service.toggleMatch(status: 0, faceCheckStatus: nil)
        }
    }

    /// R10：IM 掉线（NIMService.$connectionState = .disconnected/.idle）→ 关匹配（**不调 toggleMatch**）。
    func handleIMOffline() {
        guard state == .matching else { return }
        logger.warning("handleIMOffline: state → .ended (no toggleMatch call, network unreachable)")
        cameraSession?.stop()
        state = .ended
        lastToast = .turnOffSucceed  // 对齐 H5 `c-goMatch.vue:75`
    }

    // MARK: - CallStore 观察（joinCall.source + state → .connecting/.ended）

    /// CallStore.state 从 .idle → .calling/.connecting/.connected 迁移的第一步。
    /// v3 §2.2：无条件 unsubscribe MatchCameraPreview（让 CallView 独占 camera）。
    ///
    /// **不切 matchState**：等 joinCall.source 到达再判定归属。
    func handleCallStoreLeavingIdle() {
        guard state == .matching else { return }
        // 让 MatchCameraPreview unsubscribe（stop 内部 session；CallView 用自己的 CameraManager 起新 session）
        cameraSession?.stop()
        logger.info("handleCallStoreLeavingIdle: cameraSession stopped, matchState kept .matching pending source")
    }

    /// CallStore.$lastJoinCallSource 更新触发（'matchV4' / 'liveCall' / nil / 其他）。
    func handleJoinCallSource(_ source: String?) {
        guard state == .matching else {
            logger.info("handleJoinCallSource(\(source ?? "nil")): ignored, state=\(String(describing: self.state))")
            return
        }
        if source == "matchV4" {
            state = .matchingCalling
            logger.info("handleJoinCallSource: matchV4 → state=.matchingCalling")
            // P1 对齐 H5 c-goMatch.vue:110-119：进入 MATCHING_CALLING 立即检测一次 + 启动 3 次随机检测
            startFaceCheckInCalling()
        } else {
            // Gap-5：非 matchV4 来源 → 暂停匹配（对齐 H5 useCallApi.js:485-486 MATCHING_LEFT 语义）。
            // 保留"恢复"意图，通话结束时按 wasConnectedInCall 分流：接通过弹 Alert；直接拒绝自动 openMatch
            logger.info("handleJoinCallSource: non-matchV4 (\(source ?? "nil")) → state=.matchingSuspended")
            stopFaceCheck()
            cameraSession?.stop()
            state = .matchingSuspended
            wasConnectedInCall = false
            // 补发 toggleMatch(0) 退池（服务端不派新匹配来电）
            Task { [service] in
                _ = try? await service.toggleMatch(status: 0, faceCheckStatus: nil)
            }
        }
    }

    /// CallStore.state 转 .idle（通话完全结束）触发。
    /// v3 §2.2 + Gap-5 + P1/P2-1：分四个入口态处理：
    /// - `.matchingCalling` + `lastCallError=true` → 关匹配（对齐 H5 useCallApi.js:397 保守策略）
    /// - `.matchingCalling` + `isMatchBlocked` → 转 `.blocked`（通话中人脸检测异常场景，P1）
    /// - `.matchingCalling`（matchV4 匹配通话）→ 通话结束回 `.matching` 重启 faceCheck
    /// - `.matchingSuspended`（非 matchV4 暂停期）→ 按 `wasConnectedInCall` 分流：
    ///     - true（接通过）→ 弹 Resume Match Alert
    ///     - false（未接通 / 直接拒绝）→ 自动 openMatch
    /// - 其他态 → 不管
    ///
    /// - Parameter lastCallError: P2-1 —— 本次通话是否异常出错结束（对应 CallOverReason.beginCallError）。
    ///   默认 false 兼容现有 test caller；生产由 CallStoreMatchBridge 传真值。
    func handleCallStoreReturnedToIdle(lastJoinCallSource: String?, lastCallError: Bool = false) {
        if state == .matchingCalling {
            // P2-1 对齐 H5 useCallApi.js:397：通话异常出错 → 关匹配（保守策略，避免反复错误循环）
            if lastCallError {
                logger.warning("handleCallStoreReturnedToIdle: matchingCalling + callError → state=.ended (align H5:397)")
                stopFaceCheck()
                cameraSession?.stop()
                state = .ended
                lastToast = .turnOffSucceed
                // 补发 toggleMatch(0) 退池（fire-and-forget；H5 通过 MATCHING_ENDED watch → closeMatch → toggleMatch(0)）
                Task { [service] in
                    _ = try? await service.toggleMatch(status: 0, faceCheckStatus: nil)
                }
                return
            }
            // P1：通话中人脸检测异常已标 isMatchBlocked → 转 .blocked（不 restart camera）
            if isMatchBlocked {
                logger.info("handleCallStoreReturnedToIdle: matchingCalling + blocked (in-call faceCheck) → state=.blocked")
                stopFaceCheck()
                cameraSession?.stop()
                state = .blocked
                return
            }
            if lastJoinCallSource == "matchV4" {
                state = .matching
                cameraSession?.start()  // 重新起 camera（Match 独立 session）
                // Gap-1b：通话结束回 matching 时重启人脸检测（对齐 H5 handleReopenVideoWindow line 160 `checkFace()`）
                startFaceCheckAfterOpenMatch()
                logger.info("handleCallStoreReturnedToIdle: matchV4 → state=.matching, camera restart, faceCheck restart")
            } else {
                logger.info("handleCallStoreReturnedToIdle: non-matchV4 (\(lastJoinCallSource ?? "nil")) in matchingCalling → state unchanged")
            }
            return
        }
        if state == .matchingSuspended {
            let connected = wasConnectedInCall
            wasConnectedInCall = false
            if connected {
                // 接通过 → 弹 Resume Match Alert；用户选 Resume → openMatch，选 Cancel → 保持 .ended
                showResumeMatchAlert = true
                state = .ended
                logger.info("handleCallStoreReturnedToIdle: suspended + connected → showResumeMatchAlert")
            } else {
                // 直接拒绝 / 未接通 → 自动 openMatch
                state = .ended
                logger.info("handleCallStoreReturnedToIdle: suspended + not-connected → auto openMatch")
                Task { [weak self] in await self?.openMatch() }
            }
            return
        }
        logger.info("handleCallStoreReturnedToIdle: ignored, state=\(String(describing: self.state))")
    }

    /// Gap-5：用户点 Resume Match Alert "Resume" 按钮
    func confirmResumeMatch() {
        showResumeMatchAlert = false
        Task { [weak self] in await self?.openMatch() }
    }

    /// Gap-5：用户点 Resume Match Alert "Cancel" 按钮（保持 .ended）
    func dismissResumeMatchAlert() {
        showResumeMatchAlert = false
    }

    // MARK: - 10 分钟提示弹窗辅助

    /// 用户勾选"今日不再提醒"。持久化 + clearInterval 由 MatchPopupCoordinator 观察此字段处理。
    func markTodayNoReminder() {
        todayNoReminderChecked = true
        MatchPersistedStore.saveTodayNoReminderChecked(true)
        MatchPersistedStore.saveTipShownDate(MatchDateHelper.todayString())
    }

    /// Bug 1 fix：首日规则弹窗 Agree 那一刻立即存日期（对齐 H5 c-goMatch.vue:290-293
    /// `showFirstMatchRule() → saveTodayDate()`）。避免"Agree → openMatch 前置失败 → 日期未存 →
    /// 下次点仍 isFirstMatchToday=true 又弹规则"的重复烦扰。
    /// openMatch 内的 saveRuleAgreedDate 保留幂等（成功后二次写同值 no-op）。
    func markRuleAgreedToday() {
        let today = MatchDateHelper.todayString()
        MatchPersistedStore.saveRuleAgreedDate(today)
        isFirstMatchToday = false
        logger.info("markRuleAgreedToday: date=\(today)")
    }

    /// View 消费 lastToast 后清（UI overlay `.task(id:)` 展示 2s 后调用）
    func clearLastToast() {
        lastToast = nil
    }

    /// 10 分钟提示弹窗是否应该展示（组合态 gate，v3 §5.2 R19 + v4 subpage 拦截 + v5 online gate）。
    /// - parameter appHidden: 由 SwiftUI `@Environment(\.scenePhase)` 观察（app 切后台不弹）
    /// - parameter blockedByOtherPage: 是否处于 4 tab 根页之外的子页（直播间/通话/详情页等）
    ///   —— 对齐 H5 语义：`c-goMatch` 组件只挂在 home 页面，子页不挂 → timer 也不 fire。
    ///   iOS 侧 timer 在 MainTabView 单例常驻，但 gate 补 subpage 判定实现等价效果
    /// - parameter userOnline: 用户是否在线（OnlineStatusStore.userSetOnline）；不在线时不弹，避免与 AutoOfflineDialog 重叠
    func shouldShowTipPopup(appHidden: Bool, blockedByOtherPage: Bool = false, userOnline: Bool = true) -> Bool {
        let today = MatchDateHelper.todayString()
        // 若跨自然日 → 重置 noReminder（对齐 H5 c-goMatch.vue:460-462）
        let noTodayShow = !MatchDateHelper.isFirstToday(savedDate: MatchPersistedStore.load().tipShownDate)
                          && todayNoReminderChecked

        _ = today  // 保留以便未来展示日期字段
        return !appHidden
            && !blockedByOtherPage
            && userOnline
            && state == .ended
            && !isMatchBlocked
            && !noTodayShow
    }

    // MARK: - #3d 人脸检测（对齐 H5 c-goMatch.vue checkFace + startRandomFaceCheck + handleFaceCheckException）

    /// H5 useMatch.js 生成 3 个递增随机秒数（首个 2-23s，后续间隔 ≥3s，上限 30s）
    private func generateRandomCheckSchedule() -> [UInt64] {
        let first = Int.random(in: 2...23)
        let second = Int.random(in: (first + 3)...26)
        let third = Int.random(in: (second + 3)...29)
        // 首次 checkFace 30s 已经过；随机检测在 30s 后再走 3 次，转换为 sleep 间隔（相对上次）
        return [first, second - first, third - second].map { UInt64($0) * 1_000_000_000 }
    }

    /// openMatch 成功后启动：先 30s 首次检测 → 若未露脸走 5s 倒计时；否则进入 3 次随机检测
    func startFaceCheckAfterOpenMatch() {
        stopFaceCheck()
        faceCheckTask = Task { @MainActor [weak self] in
            // 30s 首次检测（对齐 H5 checkFace）
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard let self, !Task.isCancelled, self.state == .matching else { return }

            if !self.faceDetection.hasFace() {
                self.presentNoFacePopup()
                return
            }

            // 3 次随机检测
            let intervals = self.generateRandomCheckSchedule()
            for interval in intervals {
                try? await Task.sleep(nanoseconds: interval)
                // line 472 outer guard 已解包 self；此处只需查 cancel + state
                guard !Task.isCancelled, self.state == .matching else { return }
                if !self.faceDetection.hasFace() {
                    self.handleFaceCheckException(fromRandom: true)
                    return
                }
            }
            logger.info("faceCheck: all 4 checks passed")
        }
    }

    /// 立即停人脸检测（关匹配 / state 迁出 .matching 时调）
    func stopFaceCheck() {
        faceCheckTask?.cancel()
        faceCheckTask = nil
        noFaceCountdownTask?.cancel()
        noFaceCountdownTask = nil
        showNoFacePopup = false
        // showExitMatchPopup 保留（用户手动 dismiss）
    }

    /// 30s 首次检测未露脸 → 展示 5s 倒计时弹窗，用户 5s 内露脸可救回；否则走 blocked
    private func presentNoFacePopup() {
        showNoFacePopup = true
        noFaceCountdownTask?.cancel()
        noFaceCountdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            guard let self, !Task.isCancelled, self.showNoFacePopup else { return }
            self.showNoFacePopup = false
            // 再次检测：若仍无脸 → blocked
            if !self.faceDetection.hasFace() {
                self.handleFaceCheckException(fromRandom: false)
            }
        }
    }

    /// 用户 5s 内检测到脸 → dismiss 弹窗（供 UI 层调用）
    func dismissNoFacePopup() {
        noFaceCountdownTask?.cancel()
        noFaceCountdownTask = nil
        showNoFacePopup = false
    }

    /// 未露脸异常收尾（对齐 H5 handleFaceCheckException）
    /// - 上报 reportNoFace（TODO：J 里程碑接入 OSS 截图 + 真接口）
    /// - toggleMatch(0, faceCheckStatus:1) 关匹配（本次桶）
    /// - **匹配态**（.matching）：state → .blocked + camera.stop + showExitMatchPopup（"移除匹配"弹窗）
    /// - **通话态**（.matchingCalling，P1 对齐 H5 line 193-205 handleFaceCheckException('connected'/'random')）:
    ///   仅标 isMatchBlocked + toggleMatch(0,1)，**不改 state 也不弹 exitMatchPopup**（CallStore 主控此态；
    ///   通话结束时 handleCallStoreReturnedToIdle 判 isMatchBlocked → 转 .blocked）
    private func handleFaceCheckException(fromRandom: Bool) {
        let inCall = (state == .matchingCalling)
        logger.warning("handleFaceCheckException: fromRandom=\(fromRandom) inCall=\(inCall)")
        stopFaceCheck()
        isMatchBlocked = true
        MatchPersistedStore.saveIsMatchBlocked(true)

        if inCall {
            // P1 通话中：不改 state，不停摄像头（CallView 有自己的 CameraManager），不弹 exitMatchPopup（H5 line 279 明示仅 openMatch 期 5s 倒计时后才弹）
            lastToast = .noFaceDetected
        } else {
            cameraSession?.stop()
            state = .blocked
            showExitMatchPopup = true
            lastToast = .noFaceDetected
        }

        // 服务端上报（faceCheckStatus=1）—— OSS 截图 + reportNoFace 留 spec BL-4 J-合规
        Task { [service] in
            _ = try? await service.toggleMatch(status: 0, faceCheckStatus: 1)
        }
    }

    /// P1 对齐 H5 c-goMatch.vue:110-119：进入 MATCHING_CALLING 立即检测一次 + 启动 3 次随机检测。
    /// 与 `startFaceCheckAfterOpenMatch` 的区别：
    /// - guard state == `.matchingCalling`（vs `.matching`）
    /// - **无 30s 首检等待**（H5 通话态立即检）
    /// - **无 5s noFacePopup 兜底**（H5 line 172-186：通话中随机检测无脸直接调 handleFaceCheckException，不弹倒计时）
    private func startFaceCheckInCalling() {
        stopFaceCheck()  // 清 openMatch 期启动的 30s + 随机 timer（对齐 H5 c-goMatch:114 clearAllTimers）

        // 立即检测一次（对齐 H5 line 116-117：!faceDetected → handleFaceCheckException('connected')）
        if !faceDetection.hasFace() {
            handleFaceCheckException(fromRandom: false)
            return
        }

        // 3 次随机递归检测（对齐 H5 startRandomFaceCheck，line 165-190）
        faceCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let intervals = self.generateRandomCheckSchedule()
            for interval in intervals {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, self.state == .matchingCalling else { return }
                if !self.faceDetection.hasFace() {
                    self.handleFaceCheckException(fromRandom: true)
                    return
                }
            }
            logger.info("faceCheck (in-calling): all random checks passed")
        }
    }

    /// 用户点"移除匹配弹窗"OK → 只关 UI（state 已在 handleFaceCheckException 转 .blocked）
    func dismissExitMatchPopup() {
        showExitMatchPopup = false
    }
}
