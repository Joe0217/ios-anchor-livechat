import Foundation
import Combine

@MainActor
final class DataStatisticsStore: ObservableObject {
    enum State {
        case idle
        case loading(previous: DataStatisticsDashboard?)
        case loaded(DataStatisticsDashboard)
        case error(String, previous: DataStatisticsDashboard?)

        var dashboard: DataStatisticsDashboard? {
            switch self {
            case .idle: return nil
            case .loading(let previous), .error(_, let previous): return previous
            case .loaded(let dashboard): return dashboard
            }
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var deductionCondition: DataStatisticsDeductionCondition?
    @Published private(set) var isLoadingCondition = false
    @Published private(set) var isSubmittingDeduction = false

    private let service: DataStatisticsServiceProtocol

    init(service: DataStatisticsServiceProtocol = DataStatisticsService.shared) {
        self.service = service
    }

    func onAppear() async {
        guard case .idle = state else { return }
        await reload()
    }

    func reload() async {
        let previous = state.dashboard
        state = .loading(previous: previous)
        do {
            state = .loaded(try await service.fetchDashboard())
        } catch is CancellationError {
            state = previous.map(State.loaded) ?? .idle
        } catch {
            state = .error((error as? APIError)?.message ?? error.localizedDescription, previous: previous)
        }
    }

    func loadDeductionCondition() async {
        deductionCondition = nil
        isLoadingCondition = true
        defer { isLoadingCondition = false }
        do {
            deductionCondition = try await service.fetchDeductionCondition()
        } catch {
            deductionCondition = DataStatisticsDeductionCondition(points: "-", pointsRequired: "-", remainingChances: "-", canDeduct: false)
        }
    }

    func submitDeduction() async -> Bool {
        guard deductionCondition?.canDeduct == true, !isSubmittingDeduction else { return false }
        isSubmittingDeduction = true
        defer { isSubmittingDeduction = false }
        do {
            try await service.submitDeduction()
            await reload()
            return true
        } catch {
            return false
        }
    }
}

private extension DataStatisticsDeductionCondition {
    init(points: String, pointsRequired: String, remainingChances: String, canDeduct: Bool) {
        self.points = points
        self.pointsRequired = pointsRequired
        self.remainingChances = remainingChances
        self.canDeduct = canDeduct
    }
}
