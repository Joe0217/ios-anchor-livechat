import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L474-484
/// 视觉：`.lucky-gift-box` width 268 padding 10x8 rounded 24
/// 粉黄渐变 rgba(255,50,227,0.8) → rgba(248,201,48,0.8)
/// 内容：luck-gift icon(h28 w28) + " nickname #1AFFCD + won + '<totalReward>' #F2FF00 + diamond + by sending lucky + xN"
///
/// v22（2026-07-10）：文案超长时允许自动换行 —— H5 用 `text-13 color-#fff` inline flex-wrap；
/// iOS 用 Text concat + fixedSize(v:true) + 移除固定 height（保 max-width 268 让内容决定高度）
struct RowLuckyGift: View {
    let sender: SenderProfile?
    let iconURL: String?
    let count: Int
    let totalReward: Int64
    let theme: PublicChatTheme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // luck-gift icon 占位（未来接切图 @/assets/icon/luck-gift.png）
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundColor(.yellow)
                .frame(width: 28, height: 28)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: 268, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 255/255, green: 50/255, blue: 227/255).opacity(0.8),
                    Color(red: 248/255, green: 201/255, blue: 48/255).opacity(0.8)
                ],
                startPoint: .leading, endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 24)
        )
    }

    /// 富文本：nickname #1AFFCD · " won " · "<totalReward> 💎" #F2FF00 · " by sending lucky " · " xN"
    private var content: Text {
        let nick = Text(sender?.nickname ?? "")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))   // #1AFFCD
        let won = Text(" won ")
            .font(.system(size: 13))
            .foregroundColor(.white)
        let reward = Text("\(totalReward) 💎")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color(red: 242/255, green: 1.0, blue: 0))   // #F2FF00
        let sending = Text(" by sending lucky ")
            .font(.system(size: 13))
            .foregroundColor(.white)
        let giftCount = Text("x\(count)")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
        return nick + won + reward + sending + giftCount
    }
}
