import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L486-518
/// 视觉：max-w249 min-h24 rounded-12 px8 py5 · bg rgba(0,0,0,0.16)
/// 昵称 #1AFFCD · gift icon h20 w20 · " x N" 白字
struct RowGift: View {
    let sender: SenderProfile?
    let iconURL: String?
    let name: String
    let count: Int
    let theme: PublicChatTheme

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if let s = sender {
                if let lv = s.userLevel, lv > 0 { PublicChatLevelBadge(level: lv) }
                if s.isVip { PublicChatVipBadge() }
                Text("\(s.nickname):")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))  // #1AFFCD
                    .lineLimit(1)
            }
            PublicChatGiftIconBubble(iconURL: iconURL, count: count, iconSize: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 249, alignment: .leading)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
    }
}
