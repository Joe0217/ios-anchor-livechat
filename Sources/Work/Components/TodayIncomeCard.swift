import SwiftUI

/// 今日收益卡：标题 + 提现入口 + 3×2 收益网格。
struct TodayIncomeCard: View {
    @ObservedObject var vm: WorkViewModel

    private var items: [(number: String, caption: String)] {
        [
            ("\(vm.callIncomes)",    L10n.workCallIncomes),
            ("\(vm.giftIncomes)",    L10n.workGiftIncomes),
            ("\(vm.taskIncomes)",    L10n.workTaskIncomes),
            ("\(vm.inviteIncomes)",  L10n.workInviteIncomes),
            ("\(vm.managedIncomes)", L10n.workManagedIncomes),
            ("\(vm.totalIncomes)",   L10n.workTotalIncomes),
        ]
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading),
                                count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.workTodaysIncome)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(.white)
                Spacer()
                OutlineChevronPill(title: L10n.workWithdrawal)
            }

            Rectangle()
                .fill(Theme.Palette.divider)
                .frame(height: 1)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(items[i].number)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(items[i].caption)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Theme.Metric.cardPadding)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bigCard, style: .continuous))
    }
}
