import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "MatchPopupCoordinator")

/// L 里程碑：10 分钟提示弹窗调度器（对齐 H5 c-goMatch.vue handleShowMatchPopup + matchPopupTimer）。
///
/// **语义**：`setInterval(10*60*1000)` 每 10 分钟检查组合态；组合态满足时展示 MatchTipPopup。
/// - 组合态：`!appHidden && matchState==.ended && !isMatchBlocked && !todayNoReminderChecked`
/// - 勾选"今日不再提醒"→ `todayNoReminderChecked=true` 持久化 → 触发 timer stop（H5 clearInterval）
/// - 跨自然日 `MatchDateHelper.isFirstToday(savedDate: tipShownDate)` → 重置 noReminder 状态 + 重启 timer
///
/// **挂载**：MainTabView 层 `@StateObject`，绑定 `@Environment(\.scenePhase)` → `updateAppHidden(...)`
@MainActor
final class MatchPopupCoordinator: ObservableObject {

    static let shared = MatchPopupCoordinator()

    @Published var isShowing: Bool = false
    @Published private(set) var appHidden: Bool = false
    /// 是否处于 4 tab 根页之外的子页（LiveRoom / WishSetting / BeautySettings / UserProfile / Call 等）—— 不弹
    @Published private(set) var blockedByOtherPage: Bool = false

    private var timerTask: Task<Void, Never>?

    /// 10 分钟（H5 MATCH_POPUP_SHOW_TIME = 10 * 60 * 1000）
    private static let interval: UInt64 = 10 * 60 * 1_000_000_000

    private init() {}

    // MARK: - 生命周期

    /// MainTabView.onAppear 调用（登录后每次 tab 挂载）
    func start() {
        // 跨自然日检查：若 tipShownDate 不是今天 → 重置 noReminder（对齐 H5 c-goMatch.vue:461-462）
        let persisted = MatchPersistedStore.load()
        if MatchDateHelper.isFirstToday(savedDate: persisted.tipShownDate) {
            // 隔日重置
            MatchPersistedStore.saveTodayNoReminderChecked(false)
            MatchPersistedStore.saveTipShownDate(MatchDateHelper.todayString())
        }

        // 启动 timer
        restartTimer()
        logger.info("MatchPopupCoordinator started (interval 10min)")
    }

    /// scenePhase 观察：app hidden/active 变化时更新
    func updateAppHidden(_ hidden: Bool) {
        appHidden = hidden
    }

    /// 子页 gate：MainTabView 派生 `isOnSubpage || CallStore.state != .idle` 时置 true
    /// —— 直播间/通话中/详情页均不弹 tip（对齐 H5 c-goMatch 仅挂 home 页面语义）
    func updateBlockedByOtherPage(_ blocked: Bool) {
        blockedByOtherPage = blocked
        // 已弹的情况下切子页 → 立即关闭
        if blocked && isShowing {
            isShowing = false
        }
    }

    /// 用户勾选"今日不再提醒"—— 立即持久化 + 停止 timer（对齐 H5 handleNoReminders → clearInterval）
    func markTodayNoReminder() {
        MatchStore.shared.markTodayNoReminder()  // 已在 MatchStore 内持久化 todayNoReminderChecked + tipShownDate
        timerTask?.cancel()
        timerTask = nil
        isShowing = false
        logger.info("markTodayNoReminder: timer stopped for today")
    }

    /// 用户点关闭 (X)：只关本次，不影响下次 tick
    func dismiss() {
        isShowing = false
    }

    // MARK: - Timer

    private func restartTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.interval)
                if Task.isCancelled { return }
                guard let self else { return }
                self.checkAndShow()
            }
        }
    }

    /// 组合态检查（对齐 H5 c-goMatch.vue:468 gate + v4 subpage 拦截）
    private func checkAndShow() {
        let store = MatchStore.shared
        let shouldShow = store.shouldShowTipPopup(
            appHidden: appHidden,
            blockedByOtherPage: blockedByOtherPage
        )
        logger.debug("checkAndShow: appHidden=\(self.appHidden) blockedByOtherPage=\(self.blockedByOtherPage) shouldShow=\(shouldShow) state=\(String(describing: store.state))")
        if shouldShow {
            isShowing = true
        }
    }
}
