import Combine
import Foundation

enum PartyCurrencyValidationError: Equatable {
    case invalidAmount
    case insufficientGems
}

enum PartyCurrencyExchangeOutcome: Equatable {
    case success(gems: Int64, target: PartyCurrencyTarget)
    case validation(PartyCurrencyValidationError)
    case failed
    case cancelled
    case ignored
}

/// 房币兑换状态与副作用收敛点。兑换成功后总是重新拉余额，不依赖兑换接口的非稳定返回字段。
@MainActor
final class PartyCurrencyStore: ObservableObject {
    @Published private(set) var balance: PartyCurrencyBalance?
    @Published private(set) var isLoadingBalance = false
    @Published private(set) var didFailLoadingBalance = false
    @Published private(set) var isExchanging = false
    @Published private(set) var validationError: PartyCurrencyValidationError?
    @Published private(set) var amountText = ""
    @Published private(set) var selectedTarget: PartyCurrencyTarget = .diamond

    private let service: PartyCurrencyService
    private var balanceRequestID = UUID()

    init(service: PartyCurrencyService) {
        self.service = service
    }

    var enteredGems: Int64? {
        guard let amount = Int64(amountText), amount > 0 else { return nil }
        return amount
    }

    func select(target: PartyCurrencyTarget) {
        selectedTarget = target
    }

    func setAmount(_ value: String) {
        let digits = value.unicodeScalars.filter { scalar in
            scalar.value >= 48 && scalar.value <= 57
        }
        amountText = String(String.UnicodeScalarView(digits))
        validationError = nil
    }

    func fillAllGems() {
        guard let balance else { return }
        amountText = String(balance.availableWholeGems)
        validationError = nil
    }

    func loadBalance() async {
        let requestID = UUID()
        balanceRequestID = requestID
        isLoadingBalance = true
        didFailLoadingBalance = false
        defer {
            if balanceRequestID == requestID {
                isLoadingBalance = false
            }
        }

        do {
            let loaded = try await service.fetchBalance()
            guard balanceRequestID == requestID else { return }
            balance = loaded
        } catch is CancellationError {
            return
        } catch {
            guard balanceRequestID == requestID else { return }
            didFailLoadingBalance = true
        }
    }

    func exchange() async -> PartyCurrencyExchangeOutcome {
        guard !isExchanging else { return .ignored }
        guard let gems = enteredGems else {
            validationError = .invalidAmount
            return .validation(.invalidAmount)
        }
        guard let balance, Decimal(gems) <= balance.gems else {
            validationError = .insufficientGems
            return .validation(.insufficientGems)
        }

        let target = selectedTarget
        isExchanging = true
        validationError = nil
        balanceRequestID = UUID() // Invalidate a stale initial/retry balance response.
        isLoadingBalance = false
        defer { isExchanging = false }

        do {
            try await service.exchange(gems: gems, target: target)
            amountText = ""

            // The transaction succeeded even if reconciliation cannot complete. Keep the last known balance
            // in that case instead of reporting a completed exchange as failed.
            if let refreshed = try? await service.fetchBalance() {
                self.balance = refreshed
                didFailLoadingBalance = false
            }
            return .success(gems: gems, target: target)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
    }
}
