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
    private let canAccessAssets: @Sendable () -> Bool
    private let canExchange: @Sendable () -> Bool
    private var balanceRequestID = UUID()

    init(service: PartyCurrencyService,
         canAccessAssets: @escaping @Sendable () -> Bool = PartyCurrencyStore.defaultCanAccessAssets,
         canExchange: @escaping @Sendable () -> Bool = PartyCurrencyStore.defaultCanExchange) {
        self.service = service
        self.canAccessAssets = canAccessAssets
        self.canExchange = canExchange
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
        guard canAccessAssets() else {
            clearUnavailableAssetState()
            return
        }
        guard let balance else { return }
        amountText = String(balance.availableWholeGems)
        validationError = nil
    }

    func loadBalance() async {
        guard canAccessAssets() else {
            clearUnavailableAssetState()
            return
        }

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
            guard canAccessAssets() else {
                clearUnavailableAssetState()
                return
            }
            balance = loaded
        } catch is CancellationError {
            return
        } catch {
            guard balanceRequestID == requestID else { return }
            guard canAccessAssets() else {
                clearUnavailableAssetState()
                return
            }
            didFailLoadingBalance = true
        }
    }

    func exchange() async -> PartyCurrencyExchangeOutcome {
        guard canAccessAssets() else {
            clearUnavailableAssetState()
            return .ignored
        }
        guard canExchange() else {
            return .ignored
        }
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
            guard canAccessAssets() else {
                clearUnavailableAssetState()
                return .ignored
            }
            guard canExchange() else {
                return .ignored
            }
            amountText = ""

            // The transaction succeeded even if reconciliation cannot complete. Keep the last known balance
            // in that case instead of reporting a completed exchange as failed.
            if let refreshed = try? await service.fetchBalance(), canAccessAssets() {
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

    /// 动态降为 107 时，已展示或在途的 Party 资产不能继续留在内存/UI 中。
    private func clearUnavailableAssetState() {
        balanceRequestID = UUID()
        balance = nil
        isLoadingBalance = false
        didFailLoadingBalance = false
        isExchanging = false
        validationError = nil
        amountText = ""
    }

    nonisolated private static func defaultCanAccessAssets() -> Bool {
        #if HILY_TESTS
        // HilyTests 独立编译，不链接 SessionStore / SelfPermissionBridge+Shared。
        return true
        #else
        return SelfPermissionBridge.shared.gate(.wallet, action: "partyCurrencyAssets")
        #endif
    }

    nonisolated private static func defaultCanExchange() -> Bool {
        #if HILY_TESTS
        // HilyTests 独立编译，不链接 SessionStore / SelfPermissionBridge+Shared。
        return true
        #else
        return SelfPermissionBridge.shared.gate(.currencyExchange, action: "partyCurrencyExchange")
        #endif
    }
}

/// 独立的流水分页状态，避免查看流水干扰余额刷新或兑换中的状态。
@MainActor
final class PartyCurrencyRecordStore: ObservableObject {
    @Published private(set) var records: [PartyCurrencyRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var didFailLoading = false
    @Published private(set) var hasMore = true

    private let service: PartyCurrencyService
    private let canAccessAssets: @Sendable () -> Bool
    private let pageSize = 20
    private var activeTab: PartyCurrencyWalletTab?
    private var requestID = UUID()
    private var cache: [PartyCurrencyWalletTab: CachedState] = [:]

    private struct CachedState {
        var records: [PartyCurrencyRecord] = []
        var hasMore = true
        var nextPage = 1
        var nextOffset: String?
        var didLoad = false
        var didFailLoading = false
    }

    init(service: PartyCurrencyService,
         canAccessAssets: @escaping @Sendable () -> Bool = PartyCurrencyRecordStore.defaultCanAccessAssets) {
        self.service = service
        self.canAccessAssets = canAccessAssets
    }

    /// 每个资产 tab 首次进入时拉取；同页切换恢复内存缓存，不重复请求。
    func activate(tab: PartyCurrencyWalletTab) async {
        guard canAccessAssets() else {
            clearCache()
            return
        }
        guard activeTab != tab else { return }
        requestID = UUID()
        isLoading = false
        activeTab = tab
        let state = cache[tab] ?? CachedState()
        apply(state)
        guard !state.didLoad else { return }
        await loadMore(tab: tab)
    }

    func refresh(tab: PartyCurrencyWalletTab) async {
        guard canAccessAssets() else {
            clearCache()
            return
        }
        requestID = UUID()
        isLoading = false
        activeTab = tab
        // 下拉刷新保留已展示的流水；新首页成功后再在 loadMore 中原子替换。
        var state = cache[tab] ?? CachedState()
        state.hasMore = true
        state.nextPage = 1
        state.nextOffset = nil
        state.didFailLoading = false
        cache[tab] = state
        apply(state)
        await loadMore(tab: tab)
    }

    /// 流水页从导航栈移除时调用，避免下次进入看到旧余额变动。
    func clearCache() {
        requestID = UUID()
        isLoading = false
        activeTab = nil
        cache.removeAll()
        records = []
        hasMore = true
        didFailLoading = false
    }

    func loadMore(tab: PartyCurrencyWalletTab) async {
        guard canAccessAssets() else {
            clearCache()
            return
        }
        guard activeTab == tab, !isLoading else { return }
        var state = cache[tab] ?? CachedState()
        guard state.hasMore else { return }

        let id = UUID()
        requestID = id
        isLoading = true
        didFailLoading = false
        defer {
            if requestID == id {
                isLoading = false
            }
        }

        do {
            let loaded = try await service.fetchRecords(
                tab: tab,
                page: state.nextPage,
                pageSize: pageSize,
                offset: state.nextOffset
            )
            guard requestID == id, activeTab == tab else { return }
            guard canAccessAssets() else {
                clearCache()
                return
            }

            let deduplicated = uniqueRecords(loaded)
            if state.nextPage == 1 {
                // 流水是追加型账本；刷新首页异常返回空数组时不抹掉已显示记录。
                if !deduplicated.isEmpty || state.records.isEmpty {
                    state.records = deduplicated
                }
            } else {
                let existingIDs = Set(state.records.map(\.id))
                state.records.append(contentsOf: deduplicated.filter { !existingIDs.contains($0.id) })
            }
            state.nextPage += 1
            state.nextOffset = loaded.last?.cursor
            state.hasMore = loaded.count == pageSize && (tab == .diamonds || state.nextOffset != nil)
            state.didLoad = true
            state.didFailLoading = false
            cache[tab] = state
            apply(state)
        } catch is CancellationError {
            return
        } catch {
            guard requestID == id else { return }
            guard canAccessAssets() else {
                clearCache()
                return
            }
            state.didFailLoading = true
            cache[tab] = state
            apply(state)
        }
    }

    private func apply(_ state: CachedState) {
        records = state.records
        hasMore = state.hasMore
        didFailLoading = state.didFailLoading
    }

    private func uniqueRecords(_ records: [PartyCurrencyRecord]) -> [PartyCurrencyRecord] {
        var ids = Set<String>()
        return records.filter { ids.insert($0.id).inserted }
    }

    nonisolated private static func defaultCanAccessAssets() -> Bool {
        #if HILY_TESTS
        // HilyTests 独立编译，不链接 SessionStore / SelfPermissionBridge+Shared。
        return true
        #else
        return SelfPermissionBridge.shared.gate(.wallet, action: "partyCurrencyRecords")
        #endif
    }
}
