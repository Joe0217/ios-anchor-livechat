import SwiftUI

/// SEND_GIFT 礼物消息气泡（H-2 spec §1，对齐 H5 `msgItem.vue:272-288`）。
///
/// **视觉**：68pt 粉色渐变卡片，文案 + 50pt 礼物图 + 可选数量。
struct SystemGiftBubbleView: View {
    let smallImg: URL?
    let giftNum: Int

    var body: some View {
        HStack(spacing: 0) {
            Text("You received a gift, show him your happiness.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 100, alignment: .leading)

            giftIcon
                .frame(width: 50, height: 50)
                .padding(.horizontal, 4)

            if giftNum > 1 {
                Text("x \(giftNum)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 68)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xFF9D9F), Color(hex: 0xFFEBEB)],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    @ViewBuilder
    private var giftIcon: some View {
        if let url = smallImg {
            CachedAsyncImage(url: url, contentMode: .fit, persistent: true, cdn: (.gift, .fit)) {
                Color.white.opacity(0.3)
            }
        } else {
            Image(systemName: "gift.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.18))
        }
    }
}
