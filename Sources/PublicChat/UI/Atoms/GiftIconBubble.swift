import SwiftUI

struct PublicChatGiftIconBubble: View {
    let iconURL: String?
    let count: Int
    var iconSize: CGFloat = 20    // Live/Party 默认 20；Call 传 46

    var body: some View {
        HStack(spacing: 4) {
            iconView
            Text("x\(count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder private var iconView: some View {
        if let s = iconURL, let url = URL(string: s), !s.isEmpty {
            CachedAsyncImage(url: url, contentMode: .fill) {
                Color.white.opacity(0.15)
            }
            .frame(width: iconSize, height: iconSize)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "gift.fill")
                .font(.system(size: iconSize * 0.6))
                .foregroundColor(.white)
                .frame(width: iconSize, height: iconSize)
        }
    }
}
