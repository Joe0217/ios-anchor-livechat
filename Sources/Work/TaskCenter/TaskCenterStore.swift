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

    /// Weekly 独有(仅在 weeklyOverview 拉取后填充)
    @Published private(set) var tycoonTasks: [ActiveTycoonTaskVO] = []
    @Published private(set) var pointsInfo: WeeklyPointsInfoVO?
    @Published private(set) var weeklyResetRemainSeconds: Int = 0

    // MARK: - 顶部排位

    @Published private(set) var rankInfo: TaskRankInfoVO?

    // MARK: - collapse 折叠态(与 UserDefaults 双向)

    @Published private(set) var collapsedDaily: Set<String> = []
    @Published private(set) var collapsedWeekly: Set<String> = []

    // MARK: - 领奖 loading + popup

    @Published private(set) var claimingKey: String?   // "taskId-tier" or "taskId-all"
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
    }

    /// Test/Preview 用:显式注入 userId(避开 SessionStore.shared 依赖)。
    init(service: TaskCenterServiceProtocol, userId: String) {
        self.service = service
        self.userId = userId
        self.collapsedDaily = TaskCenterCollapseStore.load(cycle: .daily, userId: userId)
        self.collapsedWeekly = TaskCenterCollapseStore.load(cycle: .weekly, userId: userId)
    }

    /// 当前 cycle 的 state(供 View 派生)
    var state: LoadState {
        activeCycle == .daily ? dailyState : weeklyState
    }

    /// 当前 cycle 的折叠模块集合
    var collapsed: Set<String> {
        activeCycle == .daily ? collapsedDaily : collapsedWeekly
    }

    // MARK: - 生命周期

    /// 页面首次出现:并行拉取 rank + 当前 cycle;避免重复
    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        fetchRank()
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
        activeCycle = cycle
        // 若目标 cycle 从未加载,触发拉取;已加载则复用旧数据
        if case .idle = (cycle == .daily ? dailyState : weeklyState) {
            Task { await loadCycle(cycle) }
        }
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
                    // 首次调用触发 init;失败静默(H5 useTaskCenter false 时 fallback,iOS 首版不做 fallback,失败直接 error 态)
                    _ = try? await self.service.initTaskCenter()
                    let groups = try await self.service.list(cycle: .daily)
                    if Task.isCancelled { return }
                    self.setState(.daily, .loaded(groups))
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
            // 对齐 H5 index.vue L211-213:V1 + V2 并行调用
            async let _ : Void = self.service.anchorRankingV2()   // 失败静默,返回 iOS 不消费(对齐 H5 行为)
            do {
                self.rankInfo = try await self.service.anchorRanking()
            } catch {
                AppLogger.net.error("[TaskCenter.rank] fetch failed: \(String(describing: error), privacy: .public)")
                // fail-silent:rankInfo 保持 nil,View 层 fallback 显 `--`
            }
        }
    }

    // MARK: - Collapse 切换

    func toggleCollapse(_ moduleCode: String) {
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

}
