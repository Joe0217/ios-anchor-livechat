import SwiftUI
import UIKit

struct WalletView: View {
    @StateObject private var store = WalletStore()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                summaryCard
                ledgerSection
            }
            .padding(.horizontal, Theme.Metric.screenMargin)
            .padding(.vertical, 16)
        }
        .background(Theme.Palette.screenBackground)
        .navigationTitle(L10n.Wallet.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadInitial() }
        .refreshable { await store.refresh() }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Wallet.balance)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.72))
                    Text(store.summary?.balance ?? "0")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Color(hex: 0xFFE600))
                    Text("$\(store.summary?.balanceUSD ?? "0.00")")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.74))
                }
                Spacer(minLength: 14)
                NavigationLink {
                    WithdrawalView(store: store)
                } label: {
                    Label(L10n.Wallet.withdrawal, systemImage: "arrow.up.right.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(
                            LinearGradient(
                                colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(.white.opacity(0.14))

            HStack {
                Text(L10n.Wallet.todayIncome)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("+ \(store.summary?.todayIncome ?? "0")")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFFE600))
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x3C1F60), Color(hex: 0x251932)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var ledgerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Wallet.incomeDetails)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WalletLedgerFilter.allCases) { filter in
                        Button {
                            Task { await store.selectLedgerFilter(filter) }
                        } label: {
                            Text(filter.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(store.ledgerFilter == filter ? .black : .white.opacity(0.76))
                                .frame(minWidth: 66, minHeight: 34)
                                .padding(.horizontal, 6)
                                .background(
                                    store.ledgerFilter == filter ? Color(hex: 0xFFE600) : Color.white.opacity(0.09),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            WalletLedgerHeader(filter: store.ledgerFilter)

            if store.ledgerEntries.isEmpty, !store.isLoadingLedger {
                WalletEmptyState(title: L10n.commonNoContent)
            } else {
                ForEach(store.ledgerEntries) { entry in
                    WalletLedgerRow(entry: entry, filter: store.ledgerFilter)
                        .onAppear {
                            Task { await store.loadMoreLedgerIfNeeded(currentEntry: entry) }
                        }
                }
                if store.isLoadingLedger {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            }
        }
    }
}

private extension WalletLedgerFilter {
    var label: String {
        switch self {
        case .call: return L10n.Wallet.filterCall
        case .gift: return L10n.Wallet.filterGift
        case .task: return L10n.Wallet.filterTask
        case .invite: return L10n.Wallet.filterInvite
        case .message: return L10n.Wallet.filterMessage
        case .interaction: return L10n.Wallet.filterInteraction
        case .others: return L10n.Wallet.filterOthers
        }
    }
}

private struct WalletLedgerHeader: View {
    let filter: WalletLedgerFilter

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.Wallet.time).frame(maxWidth: .infinity, alignment: .leading)
            Text(filter == .task ? L10n.Wallet.source : L10n.Wallet.user).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.Wallet.detail).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.Wallet.income).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WalletLedgerRow: View {
    let entry: WalletLedgerEntry
    let filter: WalletLedgerFilter

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.createTime).frame(maxWidth: .infinity, alignment: .leading)
            Text(filter == .task ? entry.taskSourceText : entry.user)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.detail).frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.income).frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(Color(hex: 0xFFE600))
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .lineLimit(2)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct WithdrawalView: View {
    @ObservedObject var store: WalletStore
    @State private var amountText = ""
    @State private var quoteToConfirm: WithdrawalQuote?
    @State private var showRecords = false
    @FocusState private var isAmountFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WithdrawalBalanceCard(wallet: store.withdrawalWallet)

                NavigationLink(value: WorkRoute.invite(source: .withdrawal)) {
                    Label(L10n.Wallet.inviteEntry, systemImage: "person.2.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 14)
                        .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                accountSection
                amountSection

                if let description = store.withdrawalWallet?.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Metric.screenMargin)
            .padding(.bottom, 84)
        }
        .background(Theme.Palette.screenBackground)
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { isAmountFocused = false }
        .navigationTitle(L10n.Wallet.withdrawal)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    WithdrawalRecordsView(store: store)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel(L10n.Wallet.records)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                isAmountFocused = false
                if store.validationError(for: amountText) == nil {
                    quoteToConfirm = store.quote(for: amountText)
                } else {
                    Task { await store.prepareWithdrawal(amountText: amountText) }
                }
            } label: {
                Group {
                    if store.isPreparingWithdrawal {
                        ProgressView().tint(.white)
                    } else {
                        Text(L10n.Wallet.withdrawCash)
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    LinearGradient(
                        colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(store.isPreparingWithdrawal || store.withdrawalWallet == nil)
            .padding(.horizontal, Theme.Metric.screenMargin)
            .padding(.vertical, 10)
            .background(Theme.Palette.screenBackground)
        }
        .task { await store.loadWithdrawalData() }
        .refreshable { await store.loadWithdrawalData() }
        .sheet(item: $quoteToConfirm) { quote in
            WithdrawalQuoteSheet(quote: quote) {
                quoteToConfirm = nil
                Task { await store.prepareWithdrawal(amountText: amountText) }
            }
            .presentationDetents([.height(330)])
        }
        .fullScreenCover(isPresented: $store.isFaceLivenessPresented) {
            FaceLivenessView(
                verifyJPEG: { data in try await store.completeFaceLiveness(jpegData: data) },
                onSucceeded: { store.finishFaceLiveness() },
                onCancelled: { store.cancelPreparedWithdrawal() }
            )
        }
        .sheet(isPresented: Binding(
            get: { store.passwordRequest != nil },
            set: { if !$0 { store.dismissPassword() } }
        ), onDismiss: routeCompletedWithdrawal) {
            if let request = store.passwordRequest {
                WithdrawalPasswordSheet(store: store, request: request)
                    .presentationDetents([.height(370)])
            }
        }
        .navigationDestination(isPresented: $showRecords) {
            WithdrawalRecordsView(store: store)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.Wallet.selectAccount)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                NavigationLink {
                    WithdrawalAccountsView(store: store)
                } label: {
                    Label(L10n.Wallet.manageAccounts, systemImage: "creditcard")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Theme.Palette.partyCreateBtnA)
            }

            if store.accounts.isEmpty, !store.isLoadingWithdrawal {
                NavigationLink {
                    WithdrawalAccountsView(store: store)
                } label: {
                    Label(L10n.Wallet.addAccount, systemImage: "plus.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ForEach(store.accounts) { account in
                    Button {
                        isAmountFocused = false
                        store.selectedAccountID = account.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: accountIcon(account.type))
                                .font(.system(size: 20))
                                .foregroundStyle(Color(hex: 0xFFE600))
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.type).font(.system(size: 15, weight: .semibold))
                                Text(account.address).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: store.selectedAccountID == account.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(store.selectedAccountID == account.id ? Theme.Palette.partyCreateBtnA : .white.opacity(0.42))
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Wallet.enterAmount)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            if let wallet = store.withdrawalWallet {
                Text("\(L10n.Wallet.availableBalance): \(wallet.canWithdrawalAmount)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.partyCreateBtnA)
            }
            HStack(spacing: 12) {
                TextField(L10n.Wallet.amountPlaceholder, text: $amountText)
                    .keyboardType(.numberPad)
                    .focused($isAmountFocused)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .onChange(of: amountText) { newValue in
                        let digits = newValue.filter { $0.isASCII && $0.isNumber }
                        let maximum = store.withdrawalWallet?.canWithdrawalAmount ?? 0
                        if let amount = Int64(digits), maximum > 0, amount > maximum {
                            amountText = String(maximum)
                        } else if digits != newValue {
                            amountText = digits
                        }
                    }
                if let rate = store.withdrawalWallet?.diamondRate, rate > 0 {
                    Text("\(rate)=1$")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(hex: 0xFFE600))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let quote = store.quote(for: amountText) {
                Text("\(L10n.Wallet.estimatedReceive): $\(quote.finalText)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(14)
        .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func accountIcon(_ type: String) -> String {
        switch type {
        case "USDT": return "link"
        case "Digifinex": return "number.circle"
        default: return "envelope"
        }
    }

    private func routeCompletedWithdrawal() {
        guard store.completedWithdrawalID != nil else { return }
        store.consumeCompletedWithdrawal()
        showRecords = true
    }
}

private struct WithdrawalBalanceCard: View {
    let wallet: WithdrawalWallet?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.Wallet.cashableBalance)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.72))
            Text("\(wallet?.canWithdrawalAmount ?? 0)")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color(hex: 0xFFE600))
            if let diamondAmount = wallet?.diamondAmount {
                Text("\(L10n.Wallet.withdrawalBalance): \(diamondAmount)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.66))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(hex: 0x3C1F60), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WithdrawalQuoteSheet: View {
    let quote: WithdrawalQuote
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Wallet.withdrawalSummary)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            quoteRow(L10n.Wallet.grossAmount, "$\(quote.grossText)")
            quoteRow("\(L10n.Wallet.fee) (\(quote.feePercentText)%)", "-$\(quote.feeText)")
            quoteRow(L10n.Wallet.finalAmount, "$\(quote.finalText)")
            if quote.remainderDiamonds > 0 {
                Text("\(quote.remainderDiamonds) \(L10n.Wallet.remainderReturned)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xFFE600))
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(L10n.Wallet.cancel) { dismiss() }
                    .walletSecondaryButton()
                Button(L10n.Wallet.confirm) { onConfirm() }
                    .walletPrimaryButton()
            }
        }
        .padding(22)
        .background(Theme.Palette.screenBackground)
    }

    private func quoteRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.white.opacity(0.72))
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(.white)
        }
        .font(.system(size: 15))
    }
}

private struct WithdrawalPasswordSheet: View {
    @ObservedObject var store: WalletStore
    let request: WalletStore.PasswordRequest
    @State private var password = ""
    @FocusState private var isPasswordFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.config.isSet ? L10n.Wallet.enterPassword : L10n.Wallet.setPassword)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Text(request.config.isSet ? L10n.Wallet.enterPasswordDetail : L10n.Wallet.setPasswordDetail)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
            Button {
                UIPasteboard.general.string = store.supportWhatsAppPhone
                AppToastCenter.shared.show(L10n.commonCopySuccess)
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.Wallet.forgotPassword)
                    Text(store.supportWhatsAppPhone)
                        .foregroundStyle(Theme.Palette.partyCreateBtnA)
                    Image(systemName: "doc.on.doc")
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.commonCopySuccess)
            SecureField(L10n.Wallet.passwordPlaceholder, text: $password)
                .keyboardType(.numberPad)
                .focused($isPasswordFocused)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: password) { password = String($0.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(L10n.Wallet.cancel) {
                    isPasswordFocused = false
                    store.dismissPassword()
                }
                    .walletSecondaryButton()
                Button {
                    isPasswordFocused = false
                    Task {
                        if await store.submitPassword(password) { dismiss() }
                    }
                } label: {
                    if store.isPasswordSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Text(L10n.Wallet.confirm).frame(maxWidth: .infinity)
                    }
                }
                .walletPrimaryButton()
                .disabled(password.count != 6 || store.isPasswordSubmitting)
                .opacity(password.count == 6 ? 1 : 0.55)
            }
        }
        .padding(22)
        .background(Theme.Palette.screenBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            isPasswordFocused = false
        }
        .onAppear {
            isPasswordFocused = true
        }
    }
}

struct WithdrawalAccountsView: View {
    @ObservedObject var store: WalletStore
    @State private var accountToDelete: WithdrawalAccount?

    var body: some View {
        List {
            if store.accounts.isEmpty, !store.isLoadingWithdrawal {
                Text(L10n.commonNoContent)
                    .foregroundStyle(.white.opacity(0.7))
                    .listRowBackground(Theme.Palette.screenBackground)
            }
            ForEach(store.accounts) { account in
                HStack(spacing: 12) {
                    Image(systemName: "creditcard")
                        .foregroundStyle(Color(hex: 0xFFE600))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(account.type) \(L10n.Wallet.collection)")
                            .font(.system(size: 16, weight: .medium))
                        Text(account.address)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.64))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(role: .destructive) { accountToDelete = account } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.Wallet.removeAccount)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 6)
                .listRowBackground(Color(hex: 0x2B213E))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.screenBackground)
        .navigationTitle(L10n.Wallet.manageAccounts)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AddWithdrawalAccountView(store: store)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.Wallet.addAccount)
            }
        }
        .task { await store.loadWithdrawalData() }
        .alert(L10n.Wallet.removeAccount, isPresented: Binding(
            get: { accountToDelete != nil },
            set: { if !$0 { accountToDelete = nil } }
        ), presenting: accountToDelete) { account in
            Button(L10n.Wallet.remove, role: .destructive) {
                Task { await store.removeAccount(account) }
            }
            Button(L10n.Wallet.cancel, role: .cancel) {}
        } message: { account in
            Text("\(L10n.Wallet.removeAccountDetail) \(account.address)")
        }
    }
}

private struct AddWithdrawalAccountView: View {
    @ObservedObject var store: WalletStore
    @State private var type = "Digifinex"
    @State private var address = ""
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section(L10n.Wallet.collectionType) {
                Picker(L10n.Wallet.collectionType, selection: $type) {
                    Text("Digifinex").tag("Digifinex")
                    Text("USDT").tag("USDT")
                    Text("Epay").tag("Epay")
                }
            }
            Section(L10n.Wallet.collectionDetails) {
                if type == "Epay" {
                    TextField(L10n.Wallet.accountName, text: $name)
                }
                TextField(addressPlaceholder, text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(type == "Epay" ? .emailAddress : .asciiCapable)
            }
            Section {
                Text(type == "Digifinex" ? L10n.Wallet.digifinexMinimum : type == "Epay" ? L10n.Wallet.epayMinimum : L10n.Wallet.accountIrreversible)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.Wallet.addAccount)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.Wallet.confirm) {
                    Task {
                        let accountName = type == "Digifinex" ? "UID" : type == "USDT" ? "TRC20" : name
                        if await store.addAccount(type: type, address: address, name: accountName) {
                            dismiss()
                        }
                    }
                }
                .disabled(store.isMutatingAccount)
            }
        }
    }

    private var addressPlaceholder: String {
        switch type {
        case "Digifinex": return L10n.Wallet.uidPlaceholder
        case "USDT": return L10n.Wallet.addressPlaceholder
        default: return L10n.Wallet.emailPlaceholder
        }
    }
}

struct WithdrawalRecordsView: View {
    @ObservedObject var store: WalletStore

    var body: some View {
        List {
            if store.records.isEmpty, !store.isLoadingRecords {
                Text(L10n.commonNoContent)
                    .foregroundStyle(.white.opacity(0.7))
                    .listRowBackground(Theme.Palette.screenBackground)
            }
            ForEach(store.records) { record in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(record.accountType).font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Text(record.withdrawNum).foregroundStyle(Color(hex: 0xFFE600))
                    }
                    recordRow(L10n.Wallet.orderNumber, record.billId)
                    recordRow(L10n.Wallet.time, record.createTime)
                    HStack {
                        Text(L10n.Wallet.applicationStatus).foregroundStyle(.white.opacity(0.62))
                        Spacer()
                        Text(status(record.state).title).foregroundStyle(status(record.state).color)
                    }
                    .font(.system(size: 13))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 8)
                .listRowBackground(Color(hex: 0x2B213E))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.screenBackground)
        .navigationTitle(L10n.Wallet.records)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadRecords() }
        .refreshable { await store.loadRecords() }
    }

    private func recordRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.white.opacity(0.62))
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 13))
    }

    private func status(_ state: Int) -> (title: String, color: Color) {
        switch state {
        case 1: return (L10n.Wallet.reviewing, Color(hex: 0xE8A200))
        case 2: return (L10n.Wallet.paid, Color(hex: 0x22D956))
        case 3: return (L10n.Wallet.rejected, Color(hex: 0xF30034))
        default: return ("-", .white.opacity(0.6))
        }
    }
}

private struct WalletEmptyState: View {
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
            Text(title).font(.system(size: 14))
        }
        .foregroundStyle(.white.opacity(0.58))
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension View {
    func walletPrimaryButton() -> some View {
        self
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                LinearGradient(
                    colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .buttonStyle(.plain)
    }

    func walletSecondaryButton() -> some View {
        self
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .buttonStyle(.plain)
    }
}
