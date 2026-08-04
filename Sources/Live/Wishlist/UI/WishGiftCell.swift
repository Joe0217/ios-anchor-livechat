import SwiftUI

/// 单个心愿单礼物卡（对齐 H5 wishlist-anchor-panel.vue 礼物卡区）
///
/// 完成态：满格进度条 + "Complete" 徽章
/// 未完成态：部分进度条 + "x/y" 数字
struct WishGiftCell: View {
    let item: WishlistItem

    var body: some View {
        VStack(spacing: 6) {
            giftIcon
                .frame(width: 45, height: 45)

            Text(item.giftName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            HStack(spacing: 2) {
                CDNAssetImage("coins").resizable().frame(width: 10, height: 10)
                Text("\(item.giftPrice)")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: 0xFFE600))
            }

            progressSection
        }
        .padding(8)
        .background(
            LinearGradient(colors: item.isCompleted
                           ? [Color(hex: 0xFFBB02, opacity: 0.4), Color(hex: 0xFFE600, opacity: 0.2)]
                           : [Color(hex: 0x5300A1, opacity: 0.4), Color(hex: 0x3800A0, opacity: 0.2)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(item.isCompleted ? Color(hex: 0xFFBB02) : Color.white.opacity(0.15),
                        lineWidth: 1)
        )
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15)).frame(height: 5)
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0xFF9438), Color(hex: 0xFF0090), Color(hex: 0xFE00DE)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(item.progress), height: 5)
                }
            }
            .frame(height: 5)

            Text("\(item.completedCount) / \(item.targetCount)")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.85))

            if item.isCompleted {
                HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: 0x1AFFCD))
                Text(L10n.wishlistProgressComplete)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: 0x1AFFCD))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var giftIcon: some View {
        CachedAsyncImage(url: URL(string: item.giftIconUrl ?? ""), contentMode: .fit, cdn: (.gift, .fit)) {
            Image(systemName: "gift.fill")
                .font(.system(size: 22))
                .foregroundColor(Color(hex: 0xFFE600))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.1), in: Circle())
        }
    }
}
