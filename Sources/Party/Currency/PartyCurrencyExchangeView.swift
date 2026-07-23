import SwiftUI

/// 房币资产页：Diamonds 只读并可查看流水；Gems 支持兑换与查看流水。
struct PartyCurrencyExchangeView: View {
    @StateObject private var store: PartyCurrencyStore
    @State private var activeTab: PartyCurrencyWalletTab
    private let service: PartyCurrencyService

    init(
        initialTab: PartyCurrencyWalletTab = .gems,
        service: PartyCurrencyService = DefaultPartyCurrencyService()
    ) {
        self.service = service
        _store = StateObject(wrappedValue: PartyCurrencyStore(service: service))
        _activeTab = State(initialValue: initialTab)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                walletTabPicker

                if let balance = store.balance {
                    balanceSection(balance)

                    if activeTab == .gems {
                        exchangeSection(balance)
                    }
                } else if store.isLoadingBalance {
                    loadingState
                } else {
                    failedState
                }

                if activeTab == .gems {
                    gemsExplanationSection
                }
            }
            .padding(20)
        }
        .background(Theme.Palette.screenBackground)
        .navigationTitle(L10n.Party.currencyExchangeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.loadBalance() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoadingBalance || store.isExchanging)
                .accessibilityLabel(L10n.Party.currencyRefresh)
            }
        }
        .task {
            await store.loadBalance()
        }
        .refreshable {
            await store.loadBalance()
        }
    }

    private var walletTabPicker: some View {
        Picker(L10n.Party.currencyBalanceTitle, selection: $activeTab) {
            Text(L10n.Party.currencyDiamonds).tag(PartyCurrencyWalletTab.diamonds)
            Text(L10n.Party.currencyGems).tag(PartyCurrencyWalletTab.gems)
        }
        .pickerStyle(.segmented)
    }

    private func balanceSection(_ balance: PartyCurrencyBalance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Party.currencyBalanceTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            balanceRow(
                value: activeTab == .diamonds ? String(balance.diamonds) : balance.gemsDisplayValue,
                imageName: activeTab == .diamonds ? "diamonds" : "gems"
            )
        }
    }

    private func balanceRow(value: String, imageName: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                Text(value)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 12)
            recordEntry
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var recordEntry: some View {
        NavigationLink {
            PartyCurrencyRecordView(initialTab: activeTab, service: service)
        } label: {
            HStack(spacing: 5) {
                Text(L10n.Party.currencyRecord)
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.Palette.partyCreateBtnA)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Party.currencyRecord)
    }

    private func exchangeSection(_ balance: PartyCurrencyBalance) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Party.currencyExchangeTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                exchangeTargetOption(
                    target: .diamond,
                    imageName: "diamonds",
                    title: L10n.Party.currencyDiamonds
                )
                exchangeTargetOption(
                    target: .coin,
                    imageName: "coins",
                    title: L10n.Party.currencyCoins
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.Party.currencyGems)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(L10n.Party.currencyAvailable): \(balance.gemsDisplayValue)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                }

                HStack(spacing: 12) {
                    TextField(
                        L10n.Party.currencyAmountPlaceholder,
                        text: Binding(
                            get: { store.amountText },
                            set: { store.setAmount($0) }
                        )
                    )
                    .keyboardType(.numberPad)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                    Button(L10n.Party.currencyAll) {
                        store.fillAllGems()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.partyCreateBtnA)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 58)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let validationError = store.validationError {
                Text(validationText(validationError))
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.9))
            }

            targetHint

            Button {
                Task {
                    handle(await store.exchange())
                }
            } label: {
                Group {
                    if store.isExchanging {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(L10n.Party.currencyExchangeAction)
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
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
            .disabled(store.isExchanging || store.amountText.isEmpty)
            .opacity(store.isExchanging || store.amountText.isEmpty ? 0.5 : 1)
        }
    }

    private func exchangeTargetOption(
        target: PartyCurrencyTarget,
        imageName: String,
        title: String
    ) -> some View {
        Button {
            store.select(target: target)
        } label: {
            HStack(spacing: 6) {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(store.selectedTarget == target ? .white : .white.opacity(0.65))
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                store.selectedTarget == target ? Theme.Palette.partyCreateBtnA.opacity(0.38) : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(store.selectedTarget == target ? Theme.Palette.partyCreateBtnA : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var gemsExplanationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Party.currencyExplainTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(hex: 0xFFCF3F))

            explanationItem(
                title: L10n.Party.currencyGemHowToGet,
                detail: L10n.Party.currencyGemHowToGetDetail
            )
            explanationItem(
                title: L10n.Party.currencyGemUse,
                detail: L10n.Party.currencyGemUseCoinDetail,
                secondaryDetail: L10n.Party.currencyGemUseDiamondDetail
            )
        }
        .padding(.top, 4)
    }

    private func explanationItem(
        title: String,
        detail: String,
        secondaryDetail: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondaryDetail {
                    Text(secondaryDetail)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var targetHint: some View {
        if store.selectedTarget == .diamond {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right")
                Text(L10n.Party.currencyDiamondRate)
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.65))
        } else {
            Text(L10n.Party.currencyCoinRateHint)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text(L10n.Party.loading)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var failedState: some View {
        VStack(spacing: 12) {
            Text(L10n.Party.currencyBalanceLoadFailed)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Button(L10n.Party.retry) {
                Task { await store.loadBalance() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func validationText(_ error: PartyCurrencyValidationError) -> String {
        switch error {
        case .invalidAmount:
            return L10n.Party.currencyInvalidAmount
        case .insufficientGems:
            return L10n.Party.currencyInsufficientBalance
        }
    }

    private func handle(_ outcome: PartyCurrencyExchangeOutcome) {
        switch outcome {
        case .success(let gems, .diamond):
            AppToastCenter.shared.show(
                String(format: L10n.Party.currencyDiamondExchangeSuccessFormat, gems)
            )
        case .success:
            AppToastCenter.shared.show(L10n.Party.currencyCoinExchangeSuccess)
        case .failed:
            AppToastCenter.shared.show(L10n.Party.currencyExchangeFailed)
        case .validation, .cancelled, .ignored:
            break
        }
    }
}

/// Diamonds / Gems 流水页。两个 tab 各自保留服务端对应的分页策略。
private struct PartyCurrencyRecordView: View {
    @StateObject private var store: PartyCurrencyRecordStore
    @State private var activeTab: PartyCurrencyWalletTab

    init(
        initialTab: PartyCurrencyWalletTab,
        service: PartyCurrencyService = DefaultPartyCurrencyService()
    ) {
        _store = StateObject(wrappedValue: PartyCurrencyRecordStore(service: service))
        _activeTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.Party.currencyRecord, selection: $activeTab) {
                Text(L10n.Party.currencyDiamonds).tag(PartyCurrencyWalletTab.diamonds)
                Text(L10n.Party.currencyGems).tag(PartyCurrencyWalletTab.gems)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.records.isEmpty, store.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if store.records.isEmpty, store.didFailLoading {
                        failedState
                    } else if store.records.isEmpty {
                        Text(L10n.Party.currencyRecordEmpty)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(store.records) { record in
                            recordRow(record)
                        }

                        loadMoreFooter
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(Theme.Palette.screenBackground)
        .navigationTitle(L10n.Party.currencyRecord)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: activeTab) {
            await store.activate(tab: activeTab)
        }
        .refreshable {
            await store.refresh(tab: activeTab)
        }
        .onDisappear {
            store.clearCache()
        }
    }

    private func recordRow(_ record: PartyCurrencyRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.remark.isEmpty ? "--" : record.remark)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(recordTime(record))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
            Text(recordAmount(record))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(record.amount < 0 ? Color(hex: 0xFF5C91) : Color(hex: 0x31D77A))
        }
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.white.opacity(0.1))
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if store.didFailLoading {
            Button(L10n.Party.retry) {
                Task { await store.loadMore(tab: activeTab) }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.Palette.partyCreateBtnA)
            .frame(maxWidth: .infinity, minHeight: 52)
            .buttonStyle(.plain)
        } else if store.hasMore {
            Button {
                Task { await store.loadMore(tab: activeTab) }
            } label: {
                if store.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(L10n.Party.currencyLoadMore)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .frame(maxWidth: .infinity, minHeight: 52)
            .buttonStyle(.plain)
            .disabled(store.isLoading)
        }
    }

    private var failedState: some View {
        VStack(spacing: 12) {
            Text(L10n.Party.currencyRecordLoadFailed)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Button(L10n.Party.retry) {
                Task { await store.refresh(tab: activeTab) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func recordAmount(_ record: PartyCurrencyRecord) -> String {
        let value = NSDecimalNumber(decimal: record.amount).stringValue
        return record.amount > 0 ? "+\(value)" : value
    }

    private func recordTime(_ record: PartyCurrencyRecord) -> String {
        guard let milliseconds = record.timestampMilliseconds, milliseconds > 0 else { return "--" }
        let seconds = milliseconds > 10_000_000_000
            ? TimeInterval(milliseconds) / 1_000
            : TimeInterval(milliseconds)
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
