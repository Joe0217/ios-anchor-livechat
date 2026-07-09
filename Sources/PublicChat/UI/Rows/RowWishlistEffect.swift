import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L599-604
/// 组件 `<wishlist-chat-effect :effect="{ type, data }">` —— H5 独立组件，
/// Phase 1 iOS 简化为一行卡片提示：iconURL(如有) + 文本
struct RowWishlistEffect: View {
    let text: String
    let iconURL: String?
    let theme: PublicChatTheme

    var body: some View {
        HStack(spacing: 6) {
            if let s = iconURL, let u = URL(string: s), !s.isEmpty {
                CachedAsyncImage(url: u, contentMode: .fill) { Color.clear }
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: 14))
                    .foregroundColor(.yellow)
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 249, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 1.0, green: 100/255, blue: 200/255).opacity(0.5),
                         Color(red: 200/255, green: 100/255, blue: 1.0).opacity(0.5)],
                startPoint: .leading, endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}
