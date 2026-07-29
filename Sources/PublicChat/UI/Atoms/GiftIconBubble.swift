import SwiftUI

struct PublicChatGiftIconBubble: View {
    let iconURL: String?
    let count: Int
    var iconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 4) {
            iconView
            Text("x \(count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder private var iconView: some View {
        if let s = iconURL, let url = URL(string: s), !s.isEmpty {
            CachedAsyncImage(url: url, contentMode: .fill, cdn: (.gift, .fit)) {
                Color.white.opacity(0.15)
            }
            .frame(width: iconSize, height: iconSize)
        } else {
            Image(systemName: "gift.fill")
                .font(.system(size: iconSize * 0.6))
                .foregroundColor(.white)
                .frame(width: iconSize, height: iconSize)
        }
    }
}

/// H5 `new_user3.webp` 的公屏新人标；VIP 与新人同时存在时由调用方优先展示 VIP。
struct LiveNewUserBadge: View {
    var body: some View {
        CachedAsyncImage(
            url: URL(string: "https://img.hnhily.link/mstatic/live/new_user3.webp"),
            contentMode: .fit,
            persistent: true
        ) {
            Text("NEW")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 25, height: 12)
                .background(Color(red: 82 / 255, green: 178 / 255, blue: 1.0), in: Capsule())
        }
        .frame(width: 25, height: 12)
    }
}
