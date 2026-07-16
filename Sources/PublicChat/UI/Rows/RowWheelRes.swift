import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L528-547
/// 视觉：max-w249 min-h22 rounded-24 p-8 · bg-[rgba(238,102,67,0.6)] 橙 · border rgba(255,190,174,0.6)
/// 结构：图(h28 w28 rouletteMsg.webp) + [Lv 徽章 + VIP 徽章 + 昵称#1AFFCD + " hit " + "\"result\"" #FFED68 + " on the wheel"]
///   text-13 color-#fff line-height-16 font-bold；徽章 inline-block 与文本混排（可换行）
struct RowWheelRes: View {
    let sender: SenderProfile?
    let resultText: String
    let resultHighlight: String?
    let theme: PublicChatTheme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // v22（2026-07-11）：真设计切图 liveRoomRouletteMsgIcon（用户提供 rouletteMsg 3x png）
            Image("liveRoomRouletteMsgIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)

            HStack(alignment: .center, spacing: 4) {
                badgesCluster
                inlineText
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: 249, minHeight: 22, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 238/255, green: 102/255, blue: 67/255).opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color(red: 1.0, green: 190/255, blue: 174/255).opacity(0.6), lineWidth: 1)
                )
        )
    }

    @ViewBuilder private var badgesCluster: some View {
        if let s = sender {
            HStack(spacing: 4) {
                if let lv = s.userLevel, lv > 0 { UserLevelBadge(level: lv, size: .small) }
                if s.isVip { VIPBadge(size: .small) }
            }
        }
    }

    /// 昵称 + hit + "result" + on the wheel — inline text run wrap（H5 `w-full flex flex-wrap`）
    /// line-height 16pt 对齐 H5 line-height-16
    private var inlineText: Text {
        let nick = Text(sender?.nickname ?? "")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))   // #1AFFCD
        let hit = Text(" hit ")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
        let result = Text("\"\(resultHighlight ?? resultText)\"")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(Color(red: 1.0, green: 237/255, blue: 104/255))   // #FFED68
        let suffix = Text(" on the wheel")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
        return nick + hit + result + suffix
    }
}
