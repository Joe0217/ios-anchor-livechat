import SwiftUI

/// SEND_GIFT 礼物消息气泡（H-2 spec §1，对齐 H5 `msgItem.vue:272-288`）。
///
/// **视觉**：粉色渐变卡片（H5 `#FF9D9F → #FFEBEB`），左侧文案 + 中间礼物图（50x50）+ 右侧数量 xN
/// **约束**：H5 h68（68pt 高）+ 圆角 16 + padding 12/6
struct SystemGiftBubbleView: View {
    let smallImg: URL?
    let giftNum: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("You received a gift, show him your happiness.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.black.opacity(0.9))
                .lineLimit(2)
                .frame(maxWidth: 100, alignment: .leading)

            giftIcon
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            if giftNum > 1 {
                Text("x \(giftNum)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black.opacity(0.9))
                    .monospacedDigit()
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 68)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xFF9D9F), Color(hex: 0xFFEBEB)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    @ViewBuilder
    private var giftIcon: some View {
        if let url = smallImg {
            CachedAsyncImage(url: url, contentMode: .fit, persistent: true) {
                Color.white.opacity(0.3)
            }
        } else {
            Image(systemName: "gift.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.pink.opacity(0.5))
        }
    }
}
