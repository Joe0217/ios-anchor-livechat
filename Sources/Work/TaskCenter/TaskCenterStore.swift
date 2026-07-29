import Foundation
import Combine

/// Phase C —— 任务中心页 Store。对齐 H5 [`views/task/index.vue`](../../../../Desktop/HN/anchor-livechat-h5/src/views/task/index.vue)
/// 的核心状态机 + 领奖 flow + collapse 持久化。
///
/// 状态机与 [LiveDataStore.State](../LiveData/LiveDataStore.swift) 同款 —— idle / loading(previous) / loaded / error(msg, previous)。
/// 领奖成功后:
/// - 单档:`message == "grant_pending"` 只 toast;否则弹 [PendingReward] popup
/// - 一键:同类奖励合并为一个 popup;混合类型 toast
@MainActor
final class TaskCenterStore: ObservableObject {

    enum LoadState {
        case idle
        case loading(previous: [TaskModuleGroupVO]?)
        case loaded([TaskModuleGroupVO])
        case error(String, previous: [TaskModuleGroupVO]?)

        var currentGroups: [TaskModuleGroupVO]? {
            switch self {
            case .idle: return nil
            case .loading(let p): return p
            case .loaded(let g): return g
            case .error(_, let p): return p
            }
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        var errorMessage: String? {
            if case .error(let msg, _) = self { return msg }
            return nil
        }
    }

    // MARK: - Cycle 状态(Daily / Weekly 各一份)

    @Published private(set) var activeCycle: TaskCycle = .daily
    @Published private(set) var dailyState: LoadState = .idle
    @Published private(set) var weeklyState: LoadState = .idle

    /// H5 灰度期的日任务兜底。只有新版 Daily 无可展示分组时才由 View 使用。
    @Published private(set) var legacyDailyTasks: LegacyDailyTasksVO?
    @Published private(set) var legacyDailyResolved = false

    /// Weekly 独有(仅在 weeklyOverview 拉取后填充)
    @Published private(set) var tycoonTasks: [ActiveTycoonTaskVO] = []
    @Published private(set) var pointsInfo: WeeklyPointsInfoVO?
    @Published private(set) var weeklyResetRemainSeconds: Int = 0

    // MARK: - 顶部排位

    @Published private(set) var rankInfo: TaskRankInfoVO?

    // MARK: - collapse 折叠态(与 UserDefaults 双向)

    @Published private(set) var collapsedDaily: Set<String> = []
    @Published private(set) var collapsedWeekly: Set<String> = []
    @Published private(set) var tycoonExpanded = false
    @Published private(set) var pointsExpanded = false

    // MARK: - 领奖 loading + popup

    @Published private(set) var claimingKey: String?   // "taskId-tier" or "taskId-all"
    @Published private(set) var claimingLegacyTaskId: Int?
    @Published var pendingReward: PendingReward?

    // MARK: - internals

    private let service: TaskCenterServiceProtocol
    private let userId: String
    private var didAppear = false
    private var currentDailyTask: Task<Void, Never>?
    private var currentWeeklyTask: Task<Void, Never>?

    /// 从 SessionStore 读取当前 userId(作用于 collapse UserDefaults key 前缀)。
    /// 单独抽出方法而非 init 默认参数 —— init 默认参数在调用方作用域求值,SessionStore.shared.user
    /// 是 @MainActor 隔离属性,不能从 nonisolated 上下文引用;init body 在 @MainActor Store 内合法。
    private static func currentUserId() -> String {
        String(SessionStore.shared.user?.userId ?? 0)
    }

    init(service: TaskCenterServiceProtocol = TaskCenterService.shared) {
        self.service = service
        let uid = Self.currentUserId()
        self.userId = uid
        self.collapsedDaily = TaskCenterCollapseStore.load(cycle: .daily, userId: uid)
        self.collapsedWeekly = TaskCenterCollapseStore.load(cycle: .weekly, userId: uid)
        self.tycoonExpanded = TaskCenterCollapseStore.loadWeeklySectionExpanded(.tycoon, userId: uid)
        self.pointsExpanded = TaskCenterCollapseStore.loadWeeklySectionExpanded(.points, userId: uid)
    }

    /// Test/Preview 用:显式注入 userId(避开 SessionStore.shared 依赖)。
    init(service: TaskCenterServiceProtocol, userId: String) {
        self.service = service
        self.userId = userId
        self.collapsedDaily = TaskCenterCollapseStore.load(cycle: .daily, userId: userId)
        self.collapsedWeekly = TaskCenterCollapseStore.load(cycle: .weekly, userId: userId)
        self.tycoonExpanded = TaskCenterCollapseStore.loadWeeklySectionExpanded(.tycoon, userId: userId)
        self.pointsExpanded = TaskCenterCollapseStore.loadWeeklySectionExpanded(.points, userId: userId)
    }

    /// 当前 cycle 的 state(供 View 派生)
    var state: LoadState {
        activeCycle == .daily ? dailyState : weeklyState
    }

    /// 当前 cycle 的折叠模块集合
    var collapsed: Set<String> {
        activeCycle == .daily ? collapsedDaily : collapsedWeekly
    }

    /// 新版 Daily 失败或返回空分组时，H5 会展示旧版限时/全天任务。
    var shouldUseLegacyDailyTasks: Bool {
        guard legacyDailyResolved else { return false }
        switch dailyState {
        case .loaded(let groups): return groups.isEmpty
        case .error(_, previous: nil): return true
        default: return false
        }
    }

    // MARK: - 生命周期

    /// 页面首次出现:并行拉取 rank + 当前 cycle;避免重复
    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        fetchRank()
        track("h_task_center_view", properties: ["hostid": userId])
        Task { await self.loadCycle(.daily) }
    }

    /// 下拉刷新:重拉 rank + 当前 cycle
    func refresh() async {
        fetchRank()
        await loadCycle(activeCycle)
    }

    // MARK: - Cycle 切换

    func switchCycle(_ cycle: TaskCycle) {
        guard cycle != activeCycle else {
            // H5 tap 已选 cycle 也重拉 —— 对齐 handleTabClick 无条件 getData
            Task { await loadCycle(cycle) }
            return
        }
        let previousCycle = activeCycle
        activeCycle = cycle
        track("h_task_tab_switch", properties: [
            "fromTab": previousCycle == .daily ? "Daily" : "Weekly",
            "hostid": userId,
        ])
        // H5 每次切换 tab 都刷新目标周期；已有列表仍会通过 previous 保留在屏幕上。
        Task { await loadCycle(cycle) }
    }

    // MARK: - Cycle 拉取

    /// 拉取指定 cycle 的 module + task。
    /// - Daily:走 `taskCenter/list?cycle=DAILY`
    /// - Weekly:走 `taskCenter/weeklyOverview`(带 tycoon + points + reset 一次拉全)
    func loadCycle(_ cycle: TaskCycle) async {
        // cancel 同 cycle 前一发 task
        if cycle == .daily { currentDailyTask?.cancel() } else { currentWeeklyTask?.cancel() }

        // 保留 previous 视觉(list-refresh-preserve-items rule)
        let previous: [TaskModuleGroupVO]?
        switch cycle == .daily ? dailyState : weeklyState {
        case .loaded(let g): previous = g
        case .loading(let p), .error(_, let p): previous = p
        case .idle: previous = nil
        }
        setState(cycle, .loading(previous: previous))

        let t = Task { [weak self] in
            guard let self else { return }
            do {
                if cycle == .daily {
                    // H5 在新版 taskCenter 请求的同时始终加载旧版日任务，供灰度或空分组时降级。
                    async let legacyRequest = self.service.legacyDailyTasks()
                    do {
                        _ = try await self.service.initTaskCenter()
                        let groups = try await self.service.list(cycle: .daily)
                        if !Task.isCancelled {
                            self.setState(.daily, .loaded(groups))
                        }
                    } catch {
                        if !Task.isCancelled {
                            let msg = (error as? APIError)?.message ?? L10n.commonNetworkError
                            AppLogger.net.error("[TaskCenter] loadCycle DAILY failed: \(String(describing: error), privacy: .public)")
                            self.setState(.daily, .error(msg, previous: previous))
                        }
                    }

                    do {
                        let legacyTasks = try await legacyRequest
                        if !Task.isCancelled {
                            self.legacyDailyTasks = legacyTasks
                        }
                    } catch {
                        if !Task.isCancelled {
                            AppLogger.net.error("[TaskCenter] legacy daily fallback failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                    if !Task.isCancelled {
                        self.legacyDailyResolved = true
                    }
                } else {
                    let overview = try await self.service.weeklyOverview()
                    if Task.isCancelled { return }
                    self.tycoonTasks = overview.tycoonTasks
                    self.pointsInfo = overview.pointsInfo
                    self.weeklyResetRemainSeconds = overview.weeklyResetRemainSeconds
                    self.setState(.weekly, .loaded(overview.moduleGroups))
                }
            } catch {
                if Task.isCancelled { return }
                let msg = (error as? APIError)?.message ?? L10n.commonNetworkError
                AppLogger.net.error("[TaskCenter] loadCycle \(cycle.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self.setState(cycle, .error(msg, previous: previous))
            }
        }
        if cycle == .daily { currentDailyTask = t } else { currentWeeklyTask = t }
        await t.value
    }

    /// Weekly 倒计时归零后按 H5 `@weekly-reset="loadWeeklyOverview"` 重新读取新周期状态。
    func refreshWeeklyAfterReset() {
        guard activeCycle == .weekly else { return }
        Task { await loadCycle(.weekly) }
    }

    private func setState(_ cycle: TaskCycle, _ state: LoadState) {
        if cycle == .daily {
            dailyState = state
        } else {
            weeklyState = state
        }
    }

    // MARK: - 顶部排位

    private func fetchRank() {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.rankInfo = try await self.service.anchorRanking()
            } catch {
                AppLogger.net.error("[TaskCenter.rank] fetch failed: \(String(describing: error), privacy: .public)")
                // fail-silent:rankInfo 保持 nil,View 层 fallback 显 `--`
            }
        }
    }

    // MARK: - Collapse 切换

    func toggleCollapse(_ moduleCode: String, moduleName: String) {
        var set = collapsed
        if set.contains(moduleCode) {
            set.remove(moduleCode)
        } else {
            set.insert(moduleCode)
        }
        if activeCycle == .daily {
            collapsedDaily = set
        } else {
            collapsedWeekly = set
        }
        TaskCenterCollapseStore.save(cycle: activeCycle, userId: userId, collapsed: set)
        track("h_task_module_click", properties: [
            "tab_module": moduleName,
            "fromTab": activeCycle == .weekly ? "Weekly" : "Daily",
        ])
    }

    func setWeeklySection(_ section: TaskCenterCollapseStore.WeeklySection, isExpanded: Bool) {
        switch section {
        case .tycoon: tycoonExpanded = isExpanded
        case .points: pointsExpanded = isExpanded
        }
        TaskCenterCollapseStore.saveWeeklySectionExpanded(section, userId: userId, isExpanded: isExpanded)
        let moduleName = section == .tycoon ? "Active Tycoon Task" : "Integral Task"
        track("h_task_module_click", properties: [
            "tab_module": moduleName,
            "fromTab": "Weekly",
        ])
    }

    // MARK: - 领奖

    /// 单档领取。成功 flow:
    /// - `message == "grant_pending"` → 只 toast "grant_pending",不弹 popup;仍刷新
    /// - 其他 → 弹 popup(rewardType + rewardValue)+ 刷新
    func claim(taskId: Int, tier: Int) async {
        claimingKey = "\(taskId)-\(tier)"
        defer { claimingKey = nil }
        do {
            let result = try await service.claim(taskId: taskId, tier: tier)
            track("h_task_tier_claim", properties: [
                "taskId": taskId,
                "taskdia": result.rewardValue,
                "hostid": userId,
            ])
            if result.isGrantPending {
                AppToastCenter.shared.show(L10n.taskClaimGrantPending)
            } else {
                pendingReward = PendingReward(
                    rewardType: result.rewardType,
                    totalValue: result.rewardValue,
                    isMerged: false
                )
            }
            // 刷新当前 cycle + rank(领奖后积分/收入可能变)
            await loadCycle(activeCycle)
            fetchRank()
        } catch {
            AppLogger.net.error("[TaskCenter.claim] failed taskId=\(taskId, privacy: .public) tier=\(tier, privacy: .public): \(String(describing: error), privacy: .public)")
            let msg = (error as? APIError)?.message ?? L10n.commonNetworkError
            AppToastCenter.shared.show(msg)
        }
    }

    /// 一键领取全部可领档。成功 flow:
    /// - 单类奖励 → 合并 rewardValue 之和,弹 popup(isMerged: true)
    /// - 混合类型 → 只 toast "领取成功 xN 档"
    func claimAll(taskId: Int) async {
        claimingKey = "\(taskId)-all"
        defer { claimingKey = nil }
        do {
            let result = try await service.claimAll(taskId: taskId)
            let claimed = result.claimed
            for item in claimed {
                track("h_task_tier_claim", properties: [
                    "taskId": taskId,
                    "taskdia": item.rewardValue,
                    "hostid": userId,
                ])
            }
            if claimed.isEmpty {
                AppToastCenter.shared.show(L10n.taskClaimSuccess)
            } else {
                // 按 rewardType 分组;若只有一类则合并弹 popup;多类则 toast
                let types = Set(claimed.map { $0.rewardType })
                if types.count == 1, let type = types.first {
                    let total = claimed.reduce(0) { $0 + $1.rewardValue }
                    pendingReward = PendingReward(rewardType: type, totalValue: total, isMerged: claimed.count > 1)
                } else {
                    AppToastCenter.shared.show(String(format: L10n.taskClaimAllMultiTypeFormat, claimed.count))
                }
            }
            await loadCycle(activeCycle)
            fetchRank()
        } catch {
            AppLogger.net.error("[TaskCenter.claimAll] failed taskId=\(taskId, privacy: .public): \(String(describing: error), privacy: .public)")
            let msg = (error as? APIError)?.message ?? L10n.commonNetworkError
            AppToastCenter.shared.show(msg)
        }
    }

    // MARK: - 领奖 loading 派生

    func isClaimingTier(taskId: Int, tier: Int) -> Bool {
        claimingKey == "\(taskId)-\(tier)"
    }

    func isClaimingAll(taskId: Int) -> Bool {
        claimingKey == "\(taskId)-all"
    }

    func claimLegacyTask(taskId: Int) async {
        guard claimingLegacyTaskId == nil else { return }
        claimingLegacyTaskId = taskId
        defer { claimingLegacyTaskId = nil }
        do {
            try await service.claimLegacyTask(taskId: taskId)
            AppToastCenter.shared.show(L10n.taskClaimSuccess)
            await loadCycle(.daily)
            fetchRank()
        } catch {
            AppLogger.net.error("[TaskCenter.legacyClaim] failed taskId=\(taskId, privacy: .public): \(String(describing: error), privacy: .public)")
            let msg = (error as? APIError)?.message ?? L10n.commonNetworkError
            AppToastCenter.shared.show(msg)
        }
    }

    func isClaimingLegacyTask(taskId: Int) -> Bool {
        claimingLegacyTaskId == taskId
    }

    private func track(_ event: String, properties: [String: Any]) {
        AnalyticsTracker.track(event, properties: properties)
    }

}
