import SwiftUI

/// Profile 礼物墙 tab：4 列网格，每个 cell 展示礼物图 + 名称 + 收到数量。
///
/// 数据源：ProfileViewModel.giftList，来自 anchorInfo.giftList 字段（蓝本 08 §3.4）。
/// 空态显示「No gifts yet」灰色提示。
struct ProfileGiftsTabView: View {
    @ObservedObject var vm: ProfileViewModel

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 4
    )

    var body: some View {
        if vm.giftList.isEmpty {
            emptyState
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(vm.giftList) { gift in
                    cell(for: gift)
                }
            }
            .padding(.horizontal, Theme.Metric.profileDescPadding)
            .padding(.top, 8)
        }
    }

    private func cell(for gift: GiftItem) -> some View {
        VStack(spacing: 6) {
            CachedAsyncImage(url: URL(string: gift.iconUrl ?? ""), contentMode: .fit, cdn: (.gift, .fit)) {
                Image(systemName: "gift")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(10)
            }
            .frame(width: 52, height: 52)

            if let name = gift.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }

            if let count = gift.count, count > 0 {
                Text("×\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.Palette.brandYellow)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gift")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))
            Text(L10n.profileGiftsEmpty)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.vertical, 50)
        .frame(maxWidth: .infinity)
    }
}
