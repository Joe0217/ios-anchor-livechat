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

    @Published private(set) var normalState: LoadState<HomeRankingPayload> = .idle
    @Published private(set) var coupleState: LoadState<HomeCoupleRankingPayload> = .idle
    @Published private(set) var normalRequestKey: String?
    @Published private(set) var coupleRequestKey: String?

    private let service: HomeRankingServiceProtocol
    private var normalTask: Task<Void, Never>?
    private var coupleTask: Task<Void, Never>?

    init(service: HomeRankingServiceProtocol = HomeRankingService.shared) {
        self.service = service
    }

    func load(category: HomeRankingCategory, period: HomeRankingPeriod) async {
        if category == .couple {
            await loadCouple(period: period)
        } else {
            await loadNormal(category: category, period: period)
        }
    }

    func refresh(category: HomeRankingCategory, period: HomeRankingPeriod) async {
        await load(category: category, period: period)
    }

    private func loadNormal(category: HomeRankingCategory, period: HomeRankingPeriod) async {
        normalTask?.cancel()
        normalRequestKey = "\(category.rawValue)-\(period.rawValue)"
        let previous = normalState.payload
        normalState = .loading(previous: previous)
        let task = Task { [weak self, service] in
            guard let self else { return }
            do {
                let payload = try await service.fetchRanking(category: category, period: period)
                guard !Task.isCancelled else { return }
                self.normalState = .loaded(payload)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.net.error("[HomeRanking] regular load failed: \(String(describing: error), privacy: .public)")
                self.normalState = .failed(previous: previous)
            }
        }
        normalTask = task
        await task.value
    }

    private func loadCouple(period: HomeRankingPeriod) async {
        coupleTask?.cancel()
        coupleRequestKey = "couple-\(period.rawValue)"
        let previous = coupleState.payload
        coupleState = .loading(previous: previous)
        let task = Task { [weak self, service] in
            guard let self else { return }
            do {
                let payload = try await service.fetchCoupleRanking(period: period)
                guard !Task.isCancelled else { return }
                self.coupleState = .loaded(payload)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.net.error("[HomeRanking] couple load failed: \(String(describing: error), privacy: .public)")
                self.coupleState = .failed(previous: previous)
            }
        }
        coupleTask = task
        await task.value
    }

    deinit {
        normalTask?.cancel()
        coupleTask?.cancel()
    }
}
