import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L474-484
/// 视觉：`.lucky-gift-box` width 268 height 50 padding 10x8 rounded 24
/// 粉黄渐变 rgba(255,50,227,0.8) → rgba(248,201,48,0.8)
/// 内容：luck-gift icon(h28 w28) + " nickname #1AFFCD + win + '<totalReward>' #F2FF00 + diamond + by sending lucky + giftImg + xN"
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
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: 268, height: 50)
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

    /// 富文本：nickname #1AFFCD · " win " · "<totalReward> 💎" #F2FF00 · " by sending lucky " · giftIcon · " xN"
    private var content: some View {
        Text(nicknameTextRun) + Text(winPrefix) + Text(rewardRun) + Text(sendingSuffix) + Text(giftSuffix)
    }

    private var nicknameTextRun: AttributedString {
        var a = AttributedString(sender?.nickname ?? "")
        a.font = .system(size: 13, weight: .semibold)
        a.foregroundColor = Color(red: 26/255, green: 1.0, blue: 205/255)   // #1AFFCD
        return a
    }

    private var winPrefix: AttributedString {
        var a = AttributedString(" won ")
        a.font = .system(size: 13)
        a.foregroundColor = .white
        return a
    }

    private var rewardRun: AttributedString {
        var a = AttributedString("\(totalReward) 💎")
        a.font = .system(size: 13, weight: .semibold)
        a.foregroundColor = Color(red: 242/255, green: 1.0, blue: 0)   // #F2FF00
        return a
    }

    private var sendingSuffix: AttributedString {
        var a = AttributedString(" by sending lucky ")
        a.font = .system(size: 13)
        a.foregroundColor = .white
        return a
    }

    private var giftSuffix: AttributedString {
        var a = AttributedString("x\(count)")
        a.font = .system(size: 13, weight: .medium)
        a.foregroundColor = .white
        return a
    }
}
