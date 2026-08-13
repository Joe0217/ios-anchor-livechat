import SwiftUI

/// Android Work 专属的 2x2 概览卡；H5 当前未启用此区块。
struct LiveOverviewCardsRow: View {
    @ObservedObject var vm: WorkViewModel
    let onCurrencyTap: (PartyCurrencyWalletTab) -> Void
    @ObservedObject private var permission = SelfPermissionBridge.shared

    private struct CardData: Identifiable {
        let id: String
        let icon: String
        let number: String
        let numberColor: Color
        let label: String
        let currencyTab: PartyCurrencyWalletTab?
    }

    private var cards: [CardData] {
        var items: [CardData] = []
        if permission.canCall {
            items.append(CardData(id: "callsToday", icon: "callsToday", number: "\(vm.dailyCalls)", numberColor: Color(hex: 0xFA06F4), label: L10n.workCallsToday, currencyTab: nil))
        }
        items.append(CardData(id: "coins", icon: "coins", number: "\(vm.weeklyCoins)", numberColor: Color(hex: 0xF9991A), label: L10n.workCoins, currencyTab: nil))
        items.append(CardData(id: "diamonds", icon: "diamonds", number: "\(vm.walletDiamonds)", numberColor: Color(hex: 0xF640DC), label: L10n.workDiamonds, currencyTab: .diamonds))
        items.append(CardData(id: "gems", icon: "gems", number: "\(vm.walletGems)", numberColor: Color(hex: 0x3A8AE0), label: L10n.workGems, currencyTab: .gems))
        return items
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.Metric.statCardGap), count: cards.count == 3 ? 3 : 2)
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: Theme.Metric.statCardGap) {
            ForEach(cards) { card in
                Group {
                    if let tab = card.currencyTab {
                        Button { onCurrencyTap(tab) } label: { cardView(card) }
                            .buttonStyle(.plain)
                            .accessibilityHint(L10n.Party.currencyExchangeTitle)
                    } else {
                        cardView(card)
                    }
                }
            }
        }
    }

    private func cardView(_ card: CardData) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.statNumberToCaption) {
            HStack(spacing: 6) {
                CDNAssetImage(card.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(card.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(card.number)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(card.numberColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metric.cardPadding)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.statCard, style: .continuous))
    }
}
