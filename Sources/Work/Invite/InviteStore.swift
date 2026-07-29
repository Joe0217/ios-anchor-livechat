import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "InviteStore")

@MainActor
final class InviteStore: ObservableObject {
    enum State {
        case idle
        case loading(previous: InviteDashboard?)
        case loaded
        case error(message: String, previous: InviteDashboard?)

        var dashboard: InviteDashboard? {
            switch self {
            case .loading(let previous), .error(_, let previous): return previous
            case .idle, .loaded: return nil
            }
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var dashboard: InviteDashboard?
    @Published private(set) var statistics: [InviteAudience: InviteStatistics] = [:]
    @Published private(set) var boundItems: [InviteAudience: [InviteRankItem]] = [:]
    @Published private(set) var totalRewardItems: [InviteRankItem] = []
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isLoadingTotalRewards = false
    @Published private(set) var boundListErrors: [InviteAudience: String] = [:]
    @Published private(set) var totalRewardError: String?
    /// 安卓邀请页 position=1，首屏默认展示邀请主播。
    @Published var audience: InviteAudience = .anchor
    @Published var rankingTab: InviteRankingTab = .myRewards

    private let service: InviteServiceProtocol
    private var didLoad = false
    private var reloadGeneration = 0
    private var currentPage: [InviteAudience: Int] = [.user: 1, .anchor: 1]
    private var hasMore: [InviteAudience: Bool] = [.user: true, .anchor: true]
    private var listGenerations: [InviteAudience: Int] = [.user: 0, .anchor: 0]
    private var totalRewardGeneration = 0
    /// H5 rankContent 固定每页 10 条，滚到底再请求下一页。
    private let pageSize = 10

    init(service: InviteServiceProtocol = InviteService.shared) {
        self.service = service
    }

    func onAppear() {
        guard !didLoad else { return }
        didLoad = true
        Task { await reload() }
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let previous = dashboard
        state = .loading(previous: previous)
        boundListErrors = [:]
        totalRewardError = nil

        // H5 的看板、两个统计和榜单请求互不阻塞；保留已拿到的数据并让失败模块单独重试。
        async let dashboardResult = service.fetchDashboard()
        async let userStatistics = service.fetchStatistics(audience: .user)
        async let anchorStatistics = service.fetchStatistics(audience: .anchor)
        async let totalRewards = refreshTotalRewards()

        do {
            let value = try await dashboardResult
            guard generation == reloadGeneration else { return }
            dashboard = value
            state = .loaded
        } catch {
            if Task.isCancelled { return }
            guard generation == reloadGeneration else { return }
            let message = (error as? APIError)?.message ?? L10n.commonNetworkError
            logger.error("Invite dashboard load failed: \(String(describing: error), privacy: .private)")
            state = .error(message: message, previous: previous)
        }

        do {
            let value = try await userStatistics
            guard generation == reloadGeneration else { return }
            statistics[.user] = value
        } catch {
            if Task.isCancelled { return }
            guard generation == reloadGeneration else { return }
            logger.error("Invite user statistics failed: \(String(describing: error), privacy: .private)")
        }

        do {
            let value = try await anchorStatistics
            guard generation == reloadGeneration else { return }
            statistics[.anchor] = value
        } catch {
            if Task.isCancelled { return }
            guard generation == reloadGeneration else { return }
            logger.error("Invite anchor statistics failed: \(String(describing: error), privacy: .private)")
        }

        if !Task.isCancelled, generation == reloadGeneration {
            await reloadBoundLists()
        }
        await totalRewards
    }

    func selectAudience(_ newAudience: InviteAudience) {
        audience = newAudience
        guard (boundItems[newAudience] ?? []).isEmpty else { return }
        Task { await refreshBoundList(for: newAudience) }
    }

    func selectRankingTab(_ tab: InviteRankingTab) {
        logger.notice("[Invite] ranking-tab request current=\(self.rankingTab.rawValue, privacy: .public) target=\(tab.rawValue, privacy: .public)")
        if rankingTab == tab {
            if tab == .totalBonus, totalRewardItems.isEmpty, totalRewardError != nil, !isLoadingTotalRewards {
                logger.notice("[Invite] total-bonus retry requested after prior failure")
                Task { await refreshTotalRewards() }
            }
            return
        }
        rankingTab = tab
        logger.notice("[Invite] ranking-tab applied target=\(tab.rawValue, privacy: .public)")
        AnalyticsTracker.track("h_invite_page_tab2_click", properties: [
            "page": audience == .anchor ? "host_page" : "user_page",
            "tab": tab == .myRewards ? "My rewards" : "Income Rank",
        ])
        guard tab == .totalBonus, totalRewardItems.isEmpty, !isLoadingTotalRewards else { return }
        Task { await refreshTotalRewards() }
    }

    func loadMoreIfNeeded(current item: InviteRankItem) {
        guard rankingTab == .myRewards,
              item.id == boundItems[audience]?.last?.id,
              hasMore[audience] == true,
              !state.isLoading,
              !isLoadingMore else { return }
        Task { await loadMoreBoundList(for: audience) }
    }

    var visibleItems: [InviteRankItem] {
        switch rankingTab {
        case .myRewards: return boundItems[audience] ?? []
        case .totalBonus: return totalRewardItems
        }
    }

    var visibleListError: String? {
        switch rankingTab {
        case .myRewards: return boundListErrors[audience]
        case .totalBonus: return totalRewardError
        }
    }

    var isVisibleListLoading: Bool {
        switch rankingTab {
        case .myRewards: return state.isLoading
        case .totalBonus: return isLoadingTotalRewards
        }
    }

    var currentStatistics: InviteStatistics {
        statistics[audience] ?? InviteStatistics()
    }

    var currentShare: InviteShareInfo {
        guard let dashboard else { return InviteShareInfo() }
        return audience == .user ? dashboard.userShare : dashboard.anchorShare
    }

    /// H5 奖励卡只展示当前邀请类型的一条主返佣比例。
    var primaryCommission: String {
        guard let rewards = dashboard?.rewards else { return "0%" }
        switch audience {
        case .user:
            return rewards.userCommission
        case .anchor:
            return rewards.anchorCommission
        }
    }

    func sharePayload() -> InviteSharePayload? {
        let share = currentShare
        guard !share.url.isEmpty else {
            AppToastCenter.shared.show(L10n.Invite.shareUnavailable)
            return nil
        }
        let pieces = [share.posterContent, share.url].filter { !$0.isEmpty }
        AnalyticsTracker.track("invite_btn_click", properties: ["source": audience == .user ? "inviteUser" : "inviteHost"])
        if audience == .user {
            AnalyticsTracker.track("h_invite_page_user_tab_copy_link")
        }
        return InviteSharePayload(
            audience: audience,
            code: share.code,
            url: share.url,
            text: pieces.joined(separator: "\n"),
            posterImageURL: share.posterImageURL
        )
    }

    private func reloadBoundLists() async {
        async let user = refreshBoundList(for: .user)
        async let anchor = refreshBoundList(for: .anchor)
        await (user, anchor)
    }

    private func refreshBoundList(for audience: InviteAudience) async {
        listGenerations[audience, default: 0] += 1
        let generation = listGenerations[audience, default: 0]
        currentPage[audience] = 1
        hasMore[audience] = true
        boundListErrors[audience] = nil
        do {
            let items = try await service.fetchBoundUsers(audience: audience, page: 1, pageSize: pageSize)
            if Task.isCancelled { return }
            guard generation == listGenerations[audience] else { return }
            boundItems[audience] = items
            hasMore[audience] = items.count >= pageSize
        } catch {
            if Task.isCancelled { return }
            guard generation == listGenerations[audience] else { return }
            logger.error("Invite list refresh audience=\(audience.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            boundListErrors[audience] = (error as? APIError)?.message ?? L10n.commonNetworkError
        }
    }

    private func loadMoreBoundList(for audience: InviteAudience) async {
        guard !isLoadingMore, hasMore[audience] == true else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = listGenerations[audience, default: 0]
        let next = (currentPage[audience] ?? 1) + 1
        do {
            let items = try await service.fetchBoundUsers(audience: audience, page: next, pageSize: pageSize)
            if Task.isCancelled { return }
            guard generation == listGenerations[audience] else { return }
            boundItems[audience, default: []].append(contentsOf: items)
            currentPage[audience] = next
            hasMore[audience] = items.count >= pageSize
        } catch {
            if Task.isCancelled { return }
            guard generation == listGenerations[audience] else { return }
            logger.error("Invite list load more audience=\(audience.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show((error as? APIError)?.message ?? L10n.commonNetworkError)
        }
    }

    private func refreshTotalRewards() async {
        totalRewardGeneration += 1
        let generation = totalRewardGeneration
        logger.notice("[Invite] total-bonus load start generation=\(generation, privacy: .public)")
        isLoadingTotalRewards = true
        totalRewardError = nil
        defer {
            if generation == totalRewardGeneration {
                isLoadingTotalRewards = false
            }
        }
        do {
            let items = try await service.fetchTotalRewards()
            if Task.isCancelled { return }
            guard generation == totalRewardGeneration else { return }
            totalRewardItems = items
            logger.notice("[Invite] total-bonus load success generation=\(generation, privacy: .public) count=\(items.count, privacy: .public)")
        } catch {
            if Task.isCancelled { return }
            guard generation == totalRewardGeneration else { return }
            logger.error("Invite total reward rank failed: \(String(describing: error), privacy: .private)")
            logger.notice("[Invite] total-bonus load failed generation=\(generation, privacy: .public)")
            totalRewardError = (error as? APIError)?.message ?? L10n.commonNetworkError
        }
    }
}

@MainActor
final class InviteDetailsStore: ObservableObject {
    @Published var tab: InviteDetailTab = .invitedUsers
    @Published var startDate: Date
    @Published var endDate: Date
    @Published private(set) var items: [InviteRewardRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private let service: InviteServiceProtocol
    private var page = 1
    private var hasMore = true
    private var requestGeneration = 0
    private let pageSize = 20

    init(service: InviteServiceProtocol = InviteService.shared) {
        self.service = service
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        startDate = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        endDate = now
    }

    func onAppear() { Task { await reload() } }

    func selectTab(_ tab: InviteDetailTab) {
        guard self.tab != tab else { return }
        self.tab = tab
        // Tab 对应不同接口，不能在新表头下继续展示旧 Tab 的数据。
        // 先失效在途请求，避免旧分页结果在新请求启动前回写。
        requestGeneration += 1
        items = []
        errorMessage = nil
        isLoading = true
        Task { await reload() }
    }

    func reload() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let today = calendar.startOfDay(for: Date())
        guard startDate <= today else {
            AppToastCenter.shared.show(L10n.Invite.invalidDateRange)
            return
        }
        // H5 仅允许选择起始日期，查询区间的结束日期始终是当天。
        endDate = Date()
        requestGeneration += 1
        let generation = requestGeneration
        let requestedTab = tab
        let requestedStartDate = startDate
        let requestedEndDate = endDate
        isLoading = true
        errorMessage = nil
        page = 1
        hasMore = true
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }
        do {
            let values = try await service.fetchInviteDetails(kind: requestedTab, startDate: requestedStartDate, endDate: requestedEndDate, keyword: "", page: page, pageSize: pageSize)
            if Task.isCancelled { return }
            guard generation == requestGeneration else { return }
            items = values
            hasMore = values.count >= pageSize
        } catch {
            if Task.isCancelled { return }
            guard generation == requestGeneration else { return }
            errorMessage = (error as? APIError)?.message ?? L10n.commonNetworkError
            logger.error("Invite detail reload tab=\(requestedTab.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)")
        }
    }

    func loadMoreIfNeeded(current item: InviteRewardRecord) {
        guard item.id == items.last?.id, hasMore, !isLoading, !isLoadingMore else { return }
        Task { await loadMore() }
    }

    private func loadMore() async {
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = requestGeneration
        let requestedTab = tab
        let requestedStartDate = startDate
        let requestedEndDate = endDate
        do {
            let nextPage = page + 1
            let values = try await service.fetchInviteDetails(kind: requestedTab, startDate: requestedStartDate, endDate: requestedEndDate, keyword: "", page: nextPage, pageSize: pageSize)
            if Task.isCancelled { return }
            guard generation == requestGeneration else { return }
            items.append(contentsOf: values)
            page = nextPage
            hasMore = values.count >= pageSize
        } catch {
            if Task.isCancelled { return }
            guard generation == requestGeneration else { return }
            logger.error("Invite detail load more tab=\(self.tab.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show((error as? APIError)?.message ?? L10n.commonNetworkError)
        }
    }
}

@MainActor
final class InviteUserAwardsStore: ObservableObject {
    @Published private(set) var records: [InviteRewardRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    let userID: String
    private let service: InviteServiceProtocol
    private var page = 1
    private var hasMore = true
    private var requestGeneration = 0
    private let pageSize = 20

    init(userID: String, service: InviteServiceProtocol = InviteService.shared) {
        self.userID = userID
        self.service = service
    }

    func load() async {
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        errorMessage = nil
        page = 1
        hasMore = true
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }
        do {
            let values = try await service.fetchInviteDetails(kind: .rewardRecords, startDate: nil, endDate: nil, keyword: userID, page: 1, pageSize: pageSize)
            guard generation == requestGeneration else { return }
            records = values
            hasMore = values.count >= pageSize
        } catch {
            if Task.isCancelled { return }
            guard generation == requestGeneration else { return }
            errorMessage = (error as? APIError)?.message ?? L10n.commonNetworkError
            logger.error("Invite user award detail user=\(self.userID, privacy: .public) failed: \(String(describing: error), privacy: .private)")
        }
    }

    func loadMoreIfNeeded(current item: InviteRewardRecord) {
        guard item.id == records.last?.id, hasMore, !isLoadingMore else { return }
        Task { await loadMore() }
    }

    private func loadMore() async {
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = requestGeneration
        let nextPage = page + 1
        do {
            let values = try await service.fetchInviteDetails(kind: .rewardRecords, startDate: nil, endDate: nil, keyword: userID, page: nextPage, pageSize: pageSize)
            guard generation == requestGeneration else { return }
            records.append(contentsOf: values)
            page = nextPage
            hasMore = values.count >= pageSize
        } catch {
            if Task.isCancelled { return }
            guard generation == requestGeneration else { return }
            logger.error("Invite user award detail load more user=\(self.userID, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show((error as? APIError)?.message ?? L10n.commonNetworkError)
        }
    }
}

@MainActor
final class InviteAnchorDashboardStore: ObservableObject {
    @Published var period: InviteDashboardPeriod = .today
    @Published private(set) var dashboard: InviteAnchorDashboard?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: InviteServiceProtocol
    private var loadedDashboards: [InviteDashboardPeriod: InviteAnchorDashboard] = [:]
    private var requestGeneration = 0

    init(service: InviteServiceProtocol = InviteService.shared) { self.service = service }

    func onAppear() { Task { await loadAll() } }

    func selectPeriod(_ period: InviteDashboardPeriod) {
        guard self.period != period else { return }
        self.period = period
        errorMessage = nil
        if let cached = loadedDashboards[period] {
            dashboard = cached
        } else {
            // 周期变更时旧周期结果没有展示语义；保留会让用户误以为点击未生效。
            dashboard = nil
            Task { await load() }
        }
    }

    func load() async {
        requestGeneration += 1
        let generation = requestGeneration
        let requestedPeriod = period
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }
        do {
            let value = try await service.fetchAnchorDashboard(period: requestedPeriod)
            guard generation == requestGeneration else { return }
            loadedDashboards[requestedPeriod] = value
            if period == requestedPeriod {
                dashboard = value
            }
        } catch {
            if Task.isCancelled { return }
            guard generation == requestGeneration else { return }
            if period == requestedPeriod {
                errorMessage = (error as? APIError)?.message ?? L10n.commonNetworkError
            }
            logger.error("Invite anchor dashboard period=\(requestedPeriod.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func loadAll() async {
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }

        async let today = fetchDashboardResult(period: .today)
        async let thisWeek = fetchDashboardResult(period: .thisWeek)
        async let lastWeek = fetchDashboardResult(period: .lastWeek)
        async let lastMonth = fetchDashboardResult(period: .lastMonth)
        let results = await (today, thisWeek, lastWeek, lastMonth)

        guard generation == requestGeneration else { return }

        if let value = results.0 { loadedDashboards[.today] = value }
        if let value = results.1 { loadedDashboards[.thisWeek] = value }
        if let value = results.2 { loadedDashboards[.lastWeek] = value }
        if let value = results.3 { loadedDashboards[.lastMonth] = value }
        dashboard = loadedDashboards[period]
        if dashboard == nil {
            errorMessage = L10n.commonNetworkError
        }
    }

    private func fetchDashboardResult(period: InviteDashboardPeriod) async -> InviteAnchorDashboard? {
        do {
            return try await service.fetchAnchorDashboard(period: period)
        } catch {
            logger.error("Invite anchor dashboard preload period=\(period.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}

@MainActor
final class InviteAnchorDetailStore: ObservableObject {
    @Published private(set) var detail: InviteAnchorDetail?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let uid: String
    private let service: InviteServiceProtocol

    init(uid: String, service: InviteServiceProtocol = InviteService.shared) {
        self.uid = uid
        self.service = service
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            detail = try await service.fetchAnchorDetail(uid: uid)
        } catch {
            if Task.isCancelled { return }
            errorMessage = (error as? APIError)?.message ?? L10n.commonNetworkError
            logger.error("Invite anchor detail uid=\(self.uid, privacy: .public) failed: \(String(describing: error), privacy: .private)")
        }
    }
}
