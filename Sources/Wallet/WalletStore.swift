import Combine
import Foundation

@MainActor
final class WalletStore: ObservableObject {
    struct PasswordRequest: Equatable {
        let quote: WithdrawalQuote
        let account: WithdrawalAccount
        let config: WithdrawalPasswordConfig
    }

    @Published private(set) var summary: WalletSummary?
    @Published private(set) var ledgerEntries: [WalletLedgerEntry] = []
    @Published private(set) var ledgerFilter: WalletLedgerFilter = .call
    @Published private(set) var isLoadingLedger = false
    @Published private(set) var isLedgerFinished = false

    @Published private(set) var withdrawalWallet: WithdrawalWallet?
    @Published private(set) var accounts: [WithdrawalAccount] = []
    @Published var selectedAccountID: String?
    @Published private(set) var isLoadingWithdrawal = false
    @Published private(set) var records: [WithdrawalRecord] = []
    @Published private(set) var isLoadingRecords = false

    @Published var isFaceLivenessPresented = false
    @Published private(set) var isPreparingWithdrawal = false
    @Published private(set) var passwordRequest: PasswordRequest?
    @Published private(set) var isPasswordSubmitting = false
    @Published private(set) var isMutatingAccount = false
    @Published private(set) var supportWhatsAppPhone = "+86 185 0202 7264"
    @Published private(set) var completedWithdrawalID: UUID?

    private let service: WalletServicing
    private var nextLedgerPage = 1
    private var ledgerRequestID = UUID()
    private var withdrawalAuthorization: WithdrawalAuthorization?

    init(service: WalletServicing = WalletService.shared) {
        self.service = service
    }

    var selectedAccount: WithdrawalAccount? {
        guard let selectedAccountID else { return nil }
        return accounts.first { $0.id == selectedAccountID }
    }

    func loadInitial() async {
        async let summaryLoad: Void = loadSummary()
        async let ledgerLoad: Void = reloadLedger()
        async let supportLoad: Void = loadSupportWhatsApp()
        _ = await (summaryLoad, ledgerLoad, supportLoad)
    }

    func refresh() async {
        async let summaryLoad: Void = loadSummary()
        async let ledgerLoad: Void = reloadLedger()
        async let supportLoad: Void = loadSupportWhatsApp()
        _ = await (summaryLoad, ledgerLoad, supportLoad)
    }

    func loadSummary() async {
        do {
            summary = try await service.fetchSummary()
        } catch {
            showFailure(error, fallback: L10n.Wallet.loadFailed)
        }
    }

    func selectLedgerFilter(_ filter: WalletLedgerFilter) async {
        guard ledgerFilter != filter else { return }
        ledgerFilter = filter
        await reloadLedger(clearExisting: true)
    }

    func reloadLedger(clearExisting: Bool = false) async {
        let requestID = UUID()
        let filter = ledgerFilter
        ledgerRequestID = requestID
        isLoadingLedger = true
        nextLedgerPage = 1
        isLedgerFinished = false
        if clearExisting { ledgerEntries = [] }
        do {
            let entries = try await service.fetchLedger(filter: filter, page: 1, pageSize: 20)
            guard ledgerRequestID == requestID else { return }
            ledgerEntries = entries
            nextLedgerPage = 2
            isLedgerFinished = entries.count < 20
            isLoadingLedger = false
        } catch {
            guard ledgerRequestID == requestID else { return }
            // A failed request must not leave the list's paging trigger in a loop.
            if clearExisting { ledgerEntries = [] }
            isLedgerFinished = true
            isLoadingLedger = false
            showFailure(error, fallback: L10n.Wallet.loadFailed)
        }
    }

    func loadMoreLedgerIfNeeded(currentEntry: WalletLedgerEntry?) async {
        guard !isLoadingLedger, !isLedgerFinished,
              currentEntry == ledgerEntries.last else { return }
        let requestID = UUID()
        let filter = ledgerFilter
        let page = nextLedgerPage
        ledgerRequestID = requestID
        isLoadingLedger = true
        do {
            let entries = try await service.fetchLedger(filter: filter, page: page, pageSize: 20)
            guard ledgerRequestID == requestID else { return }
            ledgerEntries.append(contentsOf: entries)
            nextLedgerPage = page + 1
            isLedgerFinished = entries.count < 20
            isLoadingLedger = false
        } catch {
            guard ledgerRequestID == requestID else { return }
            isLedgerFinished = true
            isLoadingLedger = false
            showFailure(error, fallback: L10n.Wallet.loadFailed)
        }
    }

    func loadWithdrawalData() async {
        guard !isLoadingWithdrawal else { return }
        isLoadingWithdrawal = true
        defer { isLoadingWithdrawal = false }
        do {
            async let wallet = service.fetchWithdrawalWallet()
            async let accountList = service.fetchAccounts()
            let (loadedWallet, loadedAccounts) = try await (wallet, accountList)
            withdrawalWallet = loadedWallet
            accounts = loadedAccounts
            if let selectedAccountID, !loadedAccounts.contains(where: { $0.id == selectedAccountID }) {
                self.selectedAccountID = nil
            }
        } catch {
            showFailure(error, fallback: L10n.Wallet.loadFailed)
        }
    }

    func addAccount(type: String, address: String, name: String) async -> Bool {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty, !trimmedName.isEmpty,
              trimmedAddress.utf8.count <= 1_000, trimmedName.utf8.count <= 1_000 else {
            AppToastCenter.shared.show(L10n.Wallet.accountInfoRequired)
            return false
        }
        guard ["Digifinex", "USDT", "Epay"].contains(type) else {
            AppToastCenter.shared.show(L10n.Wallet.accountTypeInvalid)
            return false
        }
        isMutatingAccount = true
        defer { isMutatingAccount = false }
        do {
            try await service.addAccount(type: type, address: trimmedAddress, name: trimmedName)
            await loadWithdrawalData()
            AppToastCenter.shared.show(L10n.Wallet.accountAdded)
            return true
        } catch {
            showFailure(error, fallback: L10n.Wallet.accountSaveFailed)
            return false
        }
    }

    func removeAccount(_ account: WithdrawalAccount) async {
        guard !isMutatingAccount else { return }
        isMutatingAccount = true
        defer { isMutatingAccount = false }
        do {
            try await service.removeAccount(id: account.id)
            if selectedAccountID == account.id { selectedAccountID = nil }
            await loadWithdrawalData()
            AppToastCenter.shared.show(L10n.Wallet.accountRemoved)
        } catch {
            showFailure(error, fallback: L10n.Wallet.accountRemoveFailed)
        }
    }

    func quote(for amountText: String) -> WithdrawalQuote? {
        guard let wallet = withdrawalWallet,
              let account = selectedAccount,
              let amount = Int64(amountText), amount > 0,
              wallet.diamondRate > 0 else { return nil }
        return WithdrawalQuote(amount: amount, rate: wallet.diamondRate, serviceCharge: account.serviceCharge)
    }

    func validationError(for amountText: String) -> WithdrawalValidationError? {
        guard let account = selectedAccount else { return .missingAccount }
        guard ["Digifinex", "USDT", "Epay"].contains(account.type) else { return .missingAccount }
        guard !amountText.isEmpty else { return .missingAmount }
        guard let amount = Int64(amountText), amount > 0 else { return .invalidInteger }
        guard let wallet = withdrawalWallet else { return .missingAmount }
        guard amount <= wallet.canWithdrawalAmount else { return .exceedsBalance }
        guard amount >= 200 else { return .belowMinimumDiamond }
        guard wallet.diamondRate > 0, amount >= wallet.diamondRate else { return .belowExchangeRate }
        let quote = WithdrawalQuote(amount: amount, rate: wallet.diamondRate, serviceCharge: account.serviceCharge)
        if account.type == "Digifinex", quote.grossUSD < 20 { return .belowChannelMinimum }
        if account.type == "Epay", quote.grossUSD < 50 { return .belowChannelMinimum }
        return nil
    }

    func prepareWithdrawal(amountText: String) async {
        guard !isPreparingWithdrawal else { return }
        guard let error = validationError(for: amountText) else {
            guard let wallet = withdrawalWallet,
                  let account = selectedAccount,
                  let quote = quote(for: amountText),
                  let anchorID = SessionStore.shared.user?.userId else {
                AppToastCenter.shared.show(L10n.Wallet.loadFailed)
                return
            }
            isPreparingWithdrawal = true
            defer { isPreparingWithdrawal = false }
            withdrawalAuthorization = nil
            do {
                let needsFace = try await service.requiresFaceVerification(anchorID: anchorID)
                withdrawalAuthorization = WithdrawalAuthorization(
                    accountID: account.id,
                    diamondAmount: quote.diamondAmount,
                    faceVerified: !needsFace
                )
                if needsFace {
                    // 活体检测需要独占前摄；与开播/派对房入口一致，先静默退出匹配池。
                    if MatchStore.shared.state == .matching {
                        await MatchStore.shared.closeMatch(silent: true)
                    }
                    AnalyticsTracker.track("h_faceID_view")
                    isFaceLivenessPresented = true
                } else {
                    try await openPassword(for: quote, account: account)
                }
            } catch {
                showFailure(error, fallback: L10n.Wallet.verificationCheckFailed)
            }
            return
        }
        AppToastCenter.shared.show(validationText(error))
    }

    func completeFaceLiveness(jpegData: Data) async throws {
        guard let authorization = withdrawalAuthorization,
              let account = selectedAccount,
              authorization.accountID == account.id,
              let wallet = withdrawalWallet,
              authorization.diamondAmount <= wallet.canWithdrawalAmount,
              let anchorID = SessionStore.shared.user?.userId else {
            throw WalletServiceError.invalidResponse
        }
        try await service.verifyFace(jpegData: jpegData, anchorID: anchorID)
        withdrawalAuthorization = WithdrawalAuthorization(
            accountID: authorization.accountID,
            diamondAmount: authorization.diamondAmount,
            faceVerified: true
        )
        let quote = WithdrawalQuote(
            amount: authorization.diamondAmount,
            rate: wallet.diamondRate,
            serviceCharge: account.serviceCharge
        )
        try await openPassword(for: quote, account: account)
    }

    func cancelPreparedWithdrawal() {
        isFaceLivenessPresented = false
        passwordRequest = nil
        withdrawalAuthorization = nil
    }

    func finishFaceLiveness() {
        isFaceLivenessPresented = false
    }

    func dismissPassword() {
        passwordRequest = nil
        withdrawalAuthorization = nil
    }

    func submitPassword(_ password: String) async -> Bool {
        guard password.utf8.count == 6,
              password.utf8.allSatisfy({ (48...57).contains($0) }),
              let request = passwordRequest else {
            AppToastCenter.shared.show(L10n.Wallet.passwordSixDigits)
            return false
        }
        guard !isPasswordSubmitting else { return false }
        isPasswordSubmitting = true
        defer { isPasswordSubmitting = false }
        do {
            if !request.config.isSet {
                try await service.setWithdrawalPassword(password)
                passwordRequest = nil
                withdrawalAuthorization = nil
                AppToastCenter.shared.show(L10n.Wallet.passwordSet)
                return true
            }
            guard let authorization = withdrawalAuthorization,
                  authorization.faceVerified,
                  authorization.accountID == request.account.id,
                  authorization.diamondAmount == request.quote.diamondAmount else {
                throw WalletServiceError.invalidResponse
            }
            try await service.submitWithdrawal(
                account: request.account,
                diamondAmount: request.quote.diamondAmount,
                password: password
            )
            passwordRequest = nil
            withdrawalAuthorization = nil
            completedWithdrawalID = UUID()
            H5ActivityBridge.refreshTask()
            await loadWithdrawalData()
            await loadRecords()
            AppToastCenter.shared.show(L10n.Wallet.withdrawalSubmitted)
            return true
        } catch {
            showFailure(error, fallback: L10n.Wallet.withdrawalSubmitFailed)
            return false
        }
    }

    func loadRecords() async {
        guard !isLoadingRecords else { return }
        isLoadingRecords = true
        defer { isLoadingRecords = false }
        do {
            records = try await service.fetchRecords()
        } catch {
            showFailure(error, fallback: L10n.Wallet.loadFailed)
        }
    }

    func consumeCompletedWithdrawal() {
        completedWithdrawalID = nil
    }

    private func openPassword(for quote: WithdrawalQuote, account: WithdrawalAccount) async throws {
        let config = try await service.fetchPasswordConfig()
        passwordRequest = PasswordRequest(quote: quote, account: account, config: config)
    }

    private func loadSupportWhatsApp() async {
        if let phone = await AppConfigService.fetchWhatsAppPhone(), !phone.isEmpty {
            supportWhatsAppPhone = phone
        }
    }

    private func validationText(_ error: WithdrawalValidationError) -> String {
        switch error {
        case .missingAccount: return L10n.Wallet.selectAccount
        case .missingAmount: return L10n.Wallet.enterAmount
        case .invalidInteger: return L10n.Wallet.integerAmount
        case .exceedsBalance: return L10n.Wallet.amountExceedsBalance
        case .belowMinimumDiamond: return L10n.Wallet.minimumDiamond
        case .belowExchangeRate: return L10n.Wallet.minimumRate
        case .belowChannelMinimum: return L10n.Wallet.channelMinimum
        }
    }

    private func showFailure(_ error: Error, fallback: String) {
        if GlobalErrorBannerNotify.isCancellation(error) { return }
        let message = (error as? APIError)?.message
        AppToastCenter.shared.show(message?.isEmpty == false ? message! : fallback)
    }
}
