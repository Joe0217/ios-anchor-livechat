import SwiftUI

/// 心愿达成飘屏 view（对齐 H5 attachType 252/253 顶部飘屏动画）
///
/// 位置：屏幕上部 top 100pt
/// 动画：`.scale + .opacity` 出入场 + 3s 消失
struct WishAchievedFloat: View {
    @ObservedObject var queue: WishAchievedQueue

    var body: some View {
        ZStack {
            if let item = queue.current {
                content(item)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: item.id)
                    .id(item.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 100)
        .allowsHitTesting(false)
    }

    private func content(_ item: WishAchievedQueue.Item) -> some View {
        HStack(spacing: 8) {
            Text("🎉")
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.wishlistAchievedTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Text(item.giftName)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: 0xFFE600))
            }
            Image(systemName: "gift.fill")
                .font(.system(size: 18))
                .foregroundColor(Color(hex: 0xFFE600))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(
            LinearGradient(colors: [Color(hex: 0xFFBB02, opacity: 0.9),
                                    Color(hex: 0xFF3CC4, opacity: 0.85)],
                           startPoint: .leading, endPoint: .trailing),
            in: Capsule()
        )
        .shadow(color: Color(hex: 0xFFBB02, opacity: 0.4), radius: 8)
    }
}
