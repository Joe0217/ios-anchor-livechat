import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L528-547
/// 视觉：max-w249 min-h22 rounded-24 p-8 · bg-[rgba(238,102,67,0.6)] 橙 · border rgba(255,190,174,0.6)
/// 结构：图(h28 w28) + [Lv 徽章 + VIP 徽章 + 昵称#1AFFCD + " hit " + "\"result\"" #FFED68 + " on the wheel"]
///   text-13 color-#fff line-height-16 font-bold；徽章 inline-block 与文本混排（可换行）
///
/// v22（2026-07-10）：改 Text concat inline 混排，允许 wrap；徽章 HStack 前置
struct RowWheelRes: View {
    let sender: SenderProfile?
    let resultText: String
    let resultHighlight: String?
    let theme: PublicChatTheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // rouletteMsg.webp 占位 —— iOS 无本地 asset，用 SF Symbol 圆盘图形
            Image(systemName: "circle.grid.hex.fill")
                .font(.system(size: 24))
                .foregroundColor(Color(red: 1.0, green: 0.83, blue: 0.20))   // 金黄
                .frame(width: 28, height: 28)

            HStack(alignment: .top, spacing: 4) {
                badgesCluster
                inlineText
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: 249, alignment: .leading)
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
                if s.isVip { PublicChatVipBadge() }
            }
        }
    }

    /// 昵称 + hit + "result" + on the wheel — inline text run wrap
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
