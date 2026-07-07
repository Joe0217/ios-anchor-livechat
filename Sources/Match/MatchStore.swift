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
    /// 快照最近一次 lastJoinCallSource（供 idle 时读取）
    var latestJoinCallSource: String? { get }
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
        observer.stateReturnedToIdlePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak observer] in
                self?.handleCallStoreReturnedToIdle(lastJoinCallSource: observer?.latestJoinCallSource)
            }
            .store(in: &callStoreCancellables)
    }

    // MARK: - 主命令：开启 / 关闭

    /// 用户点开启按钮的入口。可能来自 `.ended / .blocked` 态。
    ///
    /// v3 §5.1 F3 修正后的顺序（**删除 beauty pre-check**，见 RA21）：
    /// `isOpen 返 1 → toggleMatch(1) 返 1 → cameraSession.start() → matchState=.matching`
    func openMatch() async {
        // 只有 .ended / .blocked 允许发起（.matching / .matchingCalling 期间按钮不 render，理论到不了这里）
        guard state == .ended || state == .blocked else {
            logger.warning("openMatch called in unexpected state=\(String(describing: self.state))")
            return
        }

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
    func closeMatch() async {
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
                logger.info("closeMatch: server toggleMatch(0) success")
            } catch {
                logger.warning("closeMatch: server toggleMatch(0) failed: \(String(describing: error))")
            }
        }

        lastToast = .turnOffSucceed
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
        } else {
            // 非匹配来源来电 → 强制关匹配（对齐 H5 useCallApi.js:485-488 语义）
            logger.warning("handleJoinCallSource: non-matchV4 (\(source ?? "nil")) → force .ended")
            cameraSession?.stop()
            state = .ended
            // 补发 toggleMatch(0) 回滚服务端匹配池
            Task { [service] in
                _ = try? await service.toggleMatch(status: 0, faceCheckStatus: nil)
            }
        }
    }

    /// CallStore.state 转 .idle（通话完全结束）触发。
    /// v3 §2.2：仅当 lastJoinCallSource=='matchV4' 时回 .matching；其他来源不影响。
    func handleCallStoreReturnedToIdle(lastJoinCallSource: String?) {
        guard state == .matchingCalling else {
            logger.info("handleCallStoreReturnedToIdle: ignored, state=\(String(describing: self.state))")
            return
        }
        if lastJoinCallSource == "matchV4" {
            state = .matching
            cameraSession?.start()  // 重新起 camera（Match 独立 session）
            logger.info("handleCallStoreReturnedToIdle: matchV4 → state=.matching, camera restart")
        } else {
            logger.info("handleCallStoreReturnedToIdle: non-matchV4 → state unchanged")
        }
    }

    // MARK: - 10 分钟提示弹窗辅助

    /// 用户勾选"今日不再提醒"。持久化 + clearInterval 由 MatchPopupCoordinator 观察此字段处理。
    func markTodayNoReminder() {
        todayNoReminderChecked = true
        MatchPersistedStore.saveTodayNoReminderChecked(true)
        MatchPersistedStore.saveTipShownDate(MatchDateHelper.todayString())
    }

    /// 10 分钟提示弹窗是否应该展示（组合态 gate，v3 §5.2 R19）。
    /// - parameter appHidden: 由 SwiftUI @Environment(\.scenePhase) 观察
    func shouldShowTipPopup(appHidden: Bool) -> Bool {
        let today = MatchDateHelper.todayString()
        // 若跨自然日 → 重置 noReminder（对齐 H5 c-goMatch.vue:460-462）
        let noTodayShow = !MatchDateHelper.isFirstToday(savedDate: MatchPersistedStore.load().tipShownDate)
                          && todayNoReminderChecked

        _ = today  // 保留以便未来展示日期字段
        return !appHidden
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
    /// - state → .blocked + isMatchBlocked=true 持久化
    /// - showExitMatchPopup=true（"移除匹配"弹窗）
    private func handleFaceCheckException(fromRandom: Bool) {
        logger.warning("handleFaceCheckException: fromRandom=\(fromRandom) → blocked")
        stopFaceCheck()
        cameraSession?.stop()
        isMatchBlocked = true
        MatchPersistedStore.saveIsMatchBlocked(true)
        state = .blocked
        showExitMatchPopup = true
        lastToast = .noFaceDetected

        // 服务端上报（faceCheckStatus=1）—— OSS 截图 + reportNoFace 留 spec BL-4 J-合规
        Task { [service] in
            _ = try? await service.toggleMatch(status: 0, faceCheckStatus: 1)
        }
    }

    /// 用户点"移除匹配弹窗"OK → 只关 UI（state 已在 handleFaceCheckException 转 .blocked）
    func dismissExitMatchPopup() {
        showExitMatchPopup = false
    }
}
