import Foundation

@MainActor
final class HomeRankingStore: ObservableObject {
    enum LoadState<Payload: Equatable>: Equatable {
        case idle
        case loading(previous: Payload?)
        case loaded(Payload)
        case failed(previous: Payload?)

        var payload: Payload? {
            switch self {
            case .idle: return nil
            case .loading(let previous), .failed(let previous): return previous
            case .loaded(let payload): return payload
            }
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    @Published private var normalStates: [String: LoadState<HomeRankingPayload>] = [:]
    @Published private var coupleStates: [String: LoadState<HomeCoupleRankingPayload>] = [:]
    @Published private var normalHasMore: [String: Bool] = [:]
    @Published private var coupleHasMore: [String: Bool] = [:]
    @Published private var normalLoadingMore: Set<String> = []
    @Published private var coupleLoadingMore: Set<String> = []
    @Published private var normalPageErrors: [String: String] = [:]
    @Published private var couplePageErrors: [String: String] = [:]

    private let service: HomeRankingServiceProtocol
    private var normalTasks: [String: Task<Void, Never>] = [:]
    private var coupleTasks: [String: Task<Void, Never>] = [:]
    private var normalTaskTokens: [String: UUID] = [:]
    private var coupleTaskTokens: [String: UUID] = [:]

    private let initialPageSize = 20
    private let subsequentPageSize = 30

    init(service: HomeRankingServiceProtocol = HomeRankingService.shared) {
        self.service = service
    }

    func payload(category: HomeRankingCategory, period: HomeRankingPeriod) -> HomeRankingPayload? {
        normalStates[normalKey(category: category, period: period)]?.payload
    }

    func couplePayload(period: HomeRankingPeriod) -> HomeCoupleRankingPayload? {
        coupleStates[coupleKey(period: period)]?.payload
    }

    func isLoading(category: HomeRankingCategory, period: HomeRankingPeriod) -> Bool {
        if category == .couple {
            return coupleStates[coupleKey(period: period)]?.isLoading ?? false
        }
        return normalStates[normalKey(category: category, period: period)]?.isLoading ?? false
    }

    func hasMore(category: HomeRankingCategory, period: HomeRankingPeriod) -> Bool {
        if category == .couple {
            return coupleHasMore[coupleKey(period: period)] ?? false
        }
        return normalHasMore[normalKey(category: category, period: period)] ?? false
    }

    func isLoadingMore(category: HomeRankingCategory, period: HomeRankingPeriod) -> Bool {
        if category == .couple {
            return coupleLoadingMore.contains(coupleKey(period: period))
        }
        return normalLoadingMore.contains(normalKey(category: category, period: period))
    }

    func pageError(category: HomeRankingCategory, period: HomeRankingPeriod) -> String? {
        if category == .couple {
            return couplePageErrors[coupleKey(period: period)]
        }
        return normalPageErrors[normalKey(category: category, period: period)]
    }

    /// 页面切换只拉取尚未缓存的榜单；已加载或正在加载的组合直接复用当前状态。
    func load(category: HomeRankingCategory, period: HomeRankingPeriod) {
        if category == .couple {
            beginCoupleLoad(period: period, forceRefresh: false)
        } else {
            beginNormalLoad(category: category, period: period, forceRefresh: false)
        }
    }

    /// 下拉刷新是显式操作，保留已有内容并重新请求当前组合。
    func refresh(category: HomeRankingCategory, period: HomeRankingPeriod) async {
        let task: Task<Void, Never>?
        if category == .couple {
            task = beginCoupleLoad(period: period, forceRefresh: true)
        } else {
            task = beginNormalLoad(category: category, period: period, forceRefresh: true)
        }
        await task?.value
    }

    /// The backend's `currentPage` is offset-based. Since the first screen has 20 rows
    /// while later UI pages have 30, each request expands a page-one window instead of
    /// changing `pageSize` on page two and skipping ranks 21...30.
    func loadMore(category: HomeRankingCategory, period: HomeRankingPeriod) {
        if category == .couple {
            beginCoupleLoadMore(period: period)
        } else {
            beginNormalLoadMore(category: category, period: period)
        }
    }

    func clearCache() {
        normalTasks.values.forEach { $0.cancel() }
        coupleTasks.values.forEach { $0.cancel() }
        normalTasks.removeAll()
        coupleTasks.removeAll()
        normalTaskTokens.removeAll()
        coupleTaskTokens.removeAll()
        normalStates.removeAll()
        coupleStates.removeAll()
        normalHasMore.removeAll()
        coupleHasMore.removeAll()
        normalLoadingMore.removeAll()
        coupleLoadingMore.removeAll()
        normalPageErrors.removeAll()
        couplePageErrors.removeAll()
    }

    private func beginNormalLoad(
        category: HomeRankingCategory,
        period: HomeRankingPeriod,
        forceRefresh: Bool
    ) -> Task<Void, Never>? {
        let key = normalKey(category: category, period: period)
        if !forceRefresh, normalStates[key]?.payload != nil {
            return nil
        }
        if let existingTask = normalTasks[key] {
            if !forceRefresh { return existingTask }
            existingTask.cancel()
        }

        let previous = normalStates[key]?.payload
        let token = UUID()
        normalStates[key] = .loading(previous: previous)
        normalTaskTokens[key] = token
        let task = Task { @MainActor [weak self, service] in
            do {
                let payload = try await service.fetchRanking(
                    category: category,
                    period: period,
                    limit: self?.initialPageSize ?? 20
                )
                guard !Task.isCancelled else {
                    self?.finishNormalLoad(key: key, token: token, state: .failed(previous: previous))
                    return
                }
                self?.finishNormalLoad(
                    key: key,
                    token: token,
                    state: .loaded(payload),
                    hasMore: payload.members.count >= (self?.initialPageSize ?? 20)
                )
            } catch {
                guard !Task.isCancelled else {
                    self?.finishNormalLoad(key: key, token: token, state: .failed(previous: previous))
                    return
                }
                AppLogger.net.error("[HomeRanking] regular load failed: \(String(describing: error), privacy: .public)")
                self?.finishNormalLoad(key: key, token: token, state: .failed(previous: previous))
            }
        }
        normalTasks[key] = task
        return task
    }

    private func beginCoupleLoad(
        period: HomeRankingPeriod,
        forceRefresh: Bool
    ) -> Task<Void, Never>? {
        let key = coupleKey(period: period)
        if !forceRefresh, coupleStates[key]?.payload != nil {
            return nil
        }
        if let existingTask = coupleTasks[key] {
            if !forceRefresh { return existingTask }
            existingTask.cancel()
        }

        let previous = coupleStates[key]?.payload
        let token = UUID()
        coupleStates[key] = .loading(previous: previous)
        coupleTaskTokens[key] = token
        let task = Task { @MainActor [weak self, service] in
            do {
                let payload = try await service.fetchCoupleRanking(period: period, limit: self?.initialPageSize ?? 20)
                guard !Task.isCancelled else {
                    self?.finishCoupleLoad(key: key, token: token, state: .failed(previous: previous))
                    return
                }
                self?.finishCoupleLoad(
                    key: key,
                    token: token,
                    state: .loaded(payload),
                    hasMore: payload.members.count >= (self?.initialPageSize ?? 20)
                )
            } catch {
                guard !Task.isCancelled else {
                    self?.finishCoupleLoad(key: key, token: token, state: .failed(previous: previous))
                    return
                }
                AppLogger.net.error("[HomeRanking] couple load failed: \(String(describing: error), privacy: .public)")
                self?.finishCoupleLoad(key: key, token: token, state: .failed(previous: previous))
            }
        }
        coupleTasks[key] = task
        return task
    }

    private func finishNormalLoad(
        key: String,
        token: UUID,
        state: LoadState<HomeRankingPayload>,
        hasMore: Bool? = nil
    ) {
        guard normalTaskTokens[key] == token else { return }
        normalStates[key] = state
        if let hasMore { normalHasMore[key] = hasMore }
        normalLoadingMore.remove(key)
        normalPageErrors[key] = nil
        normalTasks[key] = nil
        normalTaskTokens[key] = nil
    }

    private func finishCoupleLoad(
        key: String,
        token: UUID,
        state: LoadState<HomeCoupleRankingPayload>,
        hasMore: Bool? = nil
    ) {
        guard coupleTaskTokens[key] == token else { return }
        coupleStates[key] = state
        if let hasMore { coupleHasMore[key] = hasMore }
        coupleLoadingMore.remove(key)
        couplePageErrors[key] = nil
        coupleTasks[key] = nil
        coupleTaskTokens[key] = nil
    }

    private func beginNormalLoadMore(category: HomeRankingCategory, period: HomeRankingPeriod) {
        let key = normalKey(category: category, period: period)
        guard let previous = normalStates[key]?.payload,
              normalHasMore[key] == true,
              normalTasks[key] == nil else { return }

        let requestedCount = previous.members.count + subsequentPageSize
        let token = UUID()
        normalTaskTokens[key] = token
        normalLoadingMore.insert(key)
        normalPageErrors[key] = nil
        let task = Task { @MainActor [weak self, service] in
            do {
                let payload = try await service.fetchRanking(
                    category: category,
                    period: period,
                    limit: requestedCount
                )
                guard !Task.isCancelled else { return }
                self?.finishNormalLoad(
                    key: key,
                    token: token,
                    state: .loaded(payload),
                    hasMore: payload.members.count >= requestedCount && payload.members.count > previous.members.count
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishNormalLoadMoreFailure(key: key, token: token, error: error)
            }
        }
        normalTasks[key] = task
    }

    private func beginCoupleLoadMore(period: HomeRankingPeriod) {
        let key = coupleKey(period: period)
        guard let previous = coupleStates[key]?.payload,
              coupleHasMore[key] == true,
              coupleTasks[key] == nil else { return }

        let requestedCount = previous.members.count + subsequentPageSize
        let token = UUID()
        coupleTaskTokens[key] = token
        coupleLoadingMore.insert(key)
        couplePageErrors[key] = nil
        let task = Task { @MainActor [weak self, service] in
            do {
                let payload = try await service.fetchCoupleRanking(period: period, limit: requestedCount)
                guard !Task.isCancelled else { return }
                self?.finishCoupleLoad(
                    key: key,
                    token: token,
                    state: .loaded(payload),
                    hasMore: payload.members.count >= requestedCount && payload.members.count > previous.members.count
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishCoupleLoadMoreFailure(key: key, token: token, error: error)
            }
        }
        coupleTasks[key] = task
    }

    private func finishNormalLoadMoreFailure(key: String, token: UUID, error: Error) {
        guard normalTaskTokens[key] == token else { return }
        normalLoadingMore.remove(key)
        normalPageErrors[key] = (error as? APIError)?.message ?? L10n.commonNetworkError
        normalTasks[key] = nil
        normalTaskTokens[key] = nil
    }

    private func finishCoupleLoadMoreFailure(key: String, token: UUID, error: Error) {
        guard coupleTaskTokens[key] == token else { return }
        coupleLoadingMore.remove(key)
        couplePageErrors[key] = (error as? APIError)?.message ?? L10n.commonNetworkError
        coupleTasks[key] = nil
        coupleTaskTokens[key] = nil
    }

    private func normalKey(category: HomeRankingCategory, period: HomeRankingPeriod) -> String {
        "\(category.rawValue)-\(period.rawValue)"
    }

    private func coupleKey(period: HomeRankingPeriod) -> String {
        "couple-\(period.rawValue)"
    }

    deinit {
        normalTasks.values.forEach { $0.cancel() }
        coupleTasks.values.forEach { $0.cancel() }
    }
}
