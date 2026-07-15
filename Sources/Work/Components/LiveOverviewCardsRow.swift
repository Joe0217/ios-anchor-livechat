import SwiftUI

/// 4 张数据预览卡（2×2 网格）—— 激活 H5 蓝本 `work/index.vue` L443-491 被注释的卡组。
/// 布局：Calls Today / Coins 一行；Diamonds / Gems 一行。
/// - Calls Today / Coins 从 `AnchorInfoStore.info.dataStatistics` 派生（`callNum` / `weeklyDiamonds`）
/// - Diamonds / Gems 从 sapi `getBalance` 拉取（fail-silent 保持 0）
///
/// ⚠️ 字段语义与 StatCardsRow 冲突（详见 WorkViewModel `dailyCalls` / `weeklyCoins` 注释），
/// 待真机首次拉取后向用户报告冲突判断。
struct LiveOverviewCardsRow: View {
    @ObservedObject var vm: WorkViewModel

    var body: some View {
        // 卡片间距对齐 3 张卡（StatCardsRow.Theme.Metric.statCardGap = 10）
        VStack(spacing: Theme.Metric.statCardGap) {
            HStack(spacing: Theme.Metric.statCardGap) {
                LiveOverviewCard(icon: "callsToday",
                                 number: "\(vm.dailyCalls)",
                                 numberColor: Color(hex: 0xFA06F4),
                                 label: L10n.workCallsToday)
                LiveOverviewCard(icon: "coins",
                                 number: "\(vm.weeklyCoins)",
                                 numberColor: Color(hex: 0xF9991A),
                                 label: L10n.workCoins)
            }
            HStack(spacing: Theme.Metric.statCardGap) {
                LiveOverviewCard(icon: "diamonds",
                                 number: "\(vm.walletDiamonds)",
                                 numberColor: Color(hex: 0xF640DC),
                                 label: L10n.workDiamonds)
                LiveOverviewCard(icon: "gems",
                                 number: "\(vm.walletGems)",
                                 numberColor: Color(hex: 0x3A8AE0),
                                 label: L10n.workGems)
            }
        }
    }
}

/// 单张预览卡：图标 + label 同行(顶行) + 数字大字独占底行。
private struct LiveOverviewCard: View {
    let icon: String
    let number: String
    let numberColor: Color
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.statNumberToCaption) {
            // 顶行：图标 + label 横排
            HStack(spacing: 6) {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            // 底行：数字大字，色对齐图标主色
            Text(number)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(numberColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metric.cardPadding)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.statCard, style: .continuous))
    }
}
