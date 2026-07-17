import SwiftUI

/// 今日收益卡：标题 + 提现入口 + 3×2 收益网格。
/// P 项目权限管理 v2：canCall=false 时剔除 callIncomes（网格自动重排）；
/// giftIncomes / totalIncomes 保留不受权限影响（用户明示）。
struct TodayIncomeCard: View {
    @ObservedObject var vm: WorkViewModel
    /// P 项目权限管理：观察 canCall 决定是否显示 callIncomes 单元格
    @ObservedObject private var permission = SelfPermissionBridge.shared

    private var items: [(number: String, caption: String)] {
        var arr: [(number: String, caption: String)] = []
        if permission.canCall {
            arr.append(("\(vm.callIncomes)", L10n.workCallIncomes))
        }
        arr.append(("\(vm.giftIncomes)",    L10n.workGiftIncomes))
        arr.append(("\(vm.taskIncomes)",    L10n.workTaskIncomes))
        arr.append(("\(vm.inviteIncomes)",  L10n.workInviteIncomes))
        arr.append(("\(vm.managedIncomes)", L10n.workManagedIncomes))
        arr.append(("\(vm.totalIncomes)",   L10n.workTotalIncomes))
        return arr
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
