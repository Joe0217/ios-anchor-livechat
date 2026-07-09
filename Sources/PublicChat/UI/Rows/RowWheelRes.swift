import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L529-546
/// 视觉：max-w249 min-h22 rounded-24 p-8 · bg-[rgba(238,102,67,0.6)] 橙 · border rgb(255,190,174)/60
/// 内容：rouletteMsg.webp(h28 w28) + Lv/VIP 徽章 + 昵称 #1AFFCD + " hit " + resultText #FFED68 + " on the wheel"
struct RowWheelRes: View {
    let sender: SenderProfile?
    let resultText: String
    let resultHighlight: String?
    let theme: PublicChatTheme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 20))
                .foregroundColor(.orange)
                .frame(width: 28, height: 28)
            HStack(spacing: 4) {
                if let s = sender {
                    if let lv = s.userLevel, lv > 0 { PublicChatLevelBadge(level: lv) }
                    if s.isVip { PublicChatVipBadge() }
                    Text(s.nickname)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))   // #1AFFCD
                        .lineLimit(1)
                }
                Text("hit")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Text("\"\(resultHighlight ?? resultText)\"")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 237/255, blue: 104/255))   // #FFED68
                    .lineLimit(1)
                Text("on the wheel")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
}
