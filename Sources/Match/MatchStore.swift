import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "MatchStore")

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

    // MARK: - 依赖

    private let service: MatchServiceProtocol
    private weak var cameraSession: MatchCameraSessionProtocol?

    /// 单例（对齐 CallStore.shared / LiveStore.shared / PartyStore.shared 模式）
    static let shared = MatchStore(service: MatchService.shared)

    /// 依赖注入 init（供单测传 Fake）。生产用 `.shared`。
    init(service: MatchServiceProtocol) {
        self.service = service
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

    // MARK: - 摄像头会话注入（step 1b UI 阶段调）

    func attachCameraSession(_ session: MatchCameraSessionProtocol) {
        self.cameraSession = session
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
    }

    /// 用户主动关匹配。
    func closeMatch() async {
        guard state == .matching else {
            logger.warning("closeMatch called in unexpected state=\(String(describing: self.state))")
            return
        }

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
}
