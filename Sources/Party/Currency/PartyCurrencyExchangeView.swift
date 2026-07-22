import SwiftUI

/// 房主资产页：查询宝石/钻石/金币余额，并将整数宝石兑换为钻石或金币。
struct PartyCurrencyExchangeView: View {
    @StateObject private var store: PartyCurrencyStore

    init(service: PartyCurrencyService = DefaultPartyCurrencyService()) {
        _store = StateObject(wrappedValue: PartyCurrencyStore(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let balance = store.balance {
                    balanceSection(balance)
                    exchangeSection(balance)
                } else if store.isLoadingBalance {
                    loadingState
                } else {
                    failedState
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

    private func balanceSection(_ balance: PartyCurrencyBalance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Party.currencyBalanceTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 8) {
                balanceTile(
                    title: L10n.Party.currencyGems,
                    value: balance.gemsDisplayValue,
                    imageName: "gems"
                )
                balanceTile(
                    title: L10n.Party.currencyDiamonds,
                    value: String(balance.diamonds),
                    imageName: "diamonds"
                )
                balanceTile(
                    title: L10n.Party.currencyCoins,
                    value: String(balance.coins),
                    imageName: "coins"
                )
            }
        }
    }

    private func balanceTile(title: String, value: String, imageName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func exchangeSection(_ balance: PartyCurrencyBalance) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Party.currencyExchangeTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            Picker(
                L10n.Party.currencyTarget,
                selection: Binding(
                    get: { store.selectedTarget },
                    set: { store.select(target: $0) }
                )
            ) {
                Text(L10n.Party.currencyDiamonds).tag(PartyCurrencyTarget.diamond)
                Text(L10n.Party.currencyCoins).tag(PartyCurrencyTarget.coin)
            }
            .pickerStyle(.segmented)

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
