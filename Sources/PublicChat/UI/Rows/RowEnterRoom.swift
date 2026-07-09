import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L565-585
/// 视觉：h26 min-w212 rounded-20 px8 · 按 tier 派背景（setLevelEnterBg）
/// 内容：Lv 徽章 + VIP 徽章 + 昵称 #1AFFCD + " Entered Room" + 可选座驾图(size 26)
struct RowEnterRoom: View {
    let sender: SenderProfile?
    let vehicleImg: String?
    let itemSmallImg: String?
    let theme: PublicChatTheme

    var body: some View {
        HStack(spacing: 4) {
            if let s = sender {
                if let lv = s.userLevel, lv > 0 { PublicChatLevelBadge(level: lv) }
                if s.isVip { PublicChatVipBadge() }
                Text(s.nickname)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))
                    .lineLimit(1)
                    .frame(maxWidth: 50, alignment: .leading)
            }
            Text("Entered Room")
                .font(theme.textFont)
                .foregroundColor(.white)
            if let img = itemSmallImg ?? vehicleImg, let url = URL(string: img), !img.isEmpty {
                CachedAsyncImage(url: url, contentMode: .fit) { Color.clear }
                    .frame(width: 26, height: 26)
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 212, minHeight: 26)
        .background(enterBg, in: RoundedRectangle(cornerRadius: 20))
    }

    /// H5 setLevelEnterBg(userLevel) —— 按 tier 派渐变；简化为 3 档
    private var enterBg: LinearGradient {
        let tier = LevelTierResolver.tier(for: sender?.userLevel ?? 0)
        let colors: [Color]
        switch tier {
        case 0...2: colors = [Color.white.opacity(0.10), Color.clear]
        case 3...5: colors = [Color(red: 0.20, green: 0.60, blue: 0.95).opacity(0.5), Color.clear]
        case 6...8: colors = [Color(red: 0.75, green: 0.20, blue: 0.85).opacity(0.5), Color.clear]
        default:    colors = [Color(red: 0.95, green: 0.55, blue: 0.20).opacity(0.5), Color.clear]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}
