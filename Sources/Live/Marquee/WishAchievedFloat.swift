import SwiftUI

/// 心愿达成飘屏（对齐 H5 `wishlist-complete-float.vue`）。
/// H5 使用顶部全宽横幅：右侧滑入，停留，左侧滑出，共 6 秒。
struct WishAchievedFloat: View {
    @ObservedObject var queue: WishAchievedQueue

    var body: some View {
        ZStack {
            if let item = queue.current {
                content
                    .id(item.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 50)
        .animation(.easeInOut(duration: 0.35), value: queue.current?.id)
        .allowsHitTesting(false)
    }

    private var content: some View {
        HStack(spacing: 6) {
            Text(L10n.wishlistFloatComplete)
                .foregroundColor(Color(hex: 0xFFD243))
            Text(L10n.wishlistFloatThanks)
                .foregroundColor(.white)
        }
        .font(.system(size: 12, weight: .bold))
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background {
            CachedAsyncImage(
                url: URL(string: "https://file.lovetravel.link/mstatic/live/wishlist-nav-bg.webp"),
                contentMode: .fill,
                persistent: true
            ) {
                Color.black.opacity(0.45)
            }
        }
        .shadow(color: Color(hex: 0xFFDC64B8, opacity: 0.45), radius: 6)
    }
}
