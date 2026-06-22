import SwiftUI

/// 三项概览卡：今日通话数 / 好评率 / 周收益。
struct StatCardsRow: View {
    @ObservedObject var vm: WorkViewModel

    var body: some View {
        HStack(spacing: Theme.Metric.statCardGap) {
            StatCard(icon: "statCalls",
                     number: "\(vm.callsToday)",
                     numberColor: Theme.Palette.accentYellow,
                     caption: L10n.workCallsToday)
            StatCard(icon: "statRating",
                     number: "\(vm.positiveRating)%",
                     numberColor: Theme.Palette.accentGreen,
                     caption: L10n.workPositiveRating)
            StatCard(icon: "statRevenue",
                     number: "\(vm.weeklyRevenue)",
                     numberColor: Theme.Palette.accentYellow,
                     caption: L10n.workWeeklyRevenue)
        }
    }
}

private struct StatCard: View {
    let icon: String
    let number: String
    let numberColor: Color
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.statNumberToCaption) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

            Spacer(minLength: 6)

            Text(number)
                .font(Theme.Typography.bigStat)
                .foregroundStyle(numberColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(caption)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(Theme.Metric.cardPadding)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.statCard, style: .continuous))
    }
}
