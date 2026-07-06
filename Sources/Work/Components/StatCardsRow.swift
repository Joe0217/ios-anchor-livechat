import SwiftUI

/// 三项概览卡：在线时长 / 平均通话时长 / 好评率。对齐 H5 work/index.vue。
struct StatCardsRow: View {
    @ObservedObject var vm: WorkViewModel

    var body: some View {
        HStack(spacing: Theme.Metric.statCardGap) {
            StatCard(icon: "statOnlineTime",
                     number: Self.timeString(vm.onlineTimeSec),
                     numberColor: Theme.Palette.accentYellow,
                     caption: L10n.workOnlineTime)
            StatCard(icon: "statAvgCallDuration",
                     number: Self.timeString(vm.avgCallDurationSec),
                     numberColor: Theme.Palette.accentYellow,
                     caption: L10n.workAvgCallDuration)
            StatCard(icon: "statRating",
                     number: "\(vm.positiveRating)%",
                     numberColor: Theme.Palette.accentGreen,
                     caption: L10n.workPositiveRating)
        }
    }

    /// HH:MM:SS（H5 secondsToTime 同格式），秒对齐"padStart(2,'0')"
    private static func timeString(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
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
                .padding(.bottom, 4)   // 图标↔数值固定间距 = 6(VStack) + 4 = 10
                .accessibilityHidden(true)

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
