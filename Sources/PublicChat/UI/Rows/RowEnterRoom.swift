import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L565-585
/// 视觉：h26 min-w212 rounded-20 px8 · setLevelEnterBg 按 tier 派背景（[6-95] L65-92）
/// 内容：Lv 徽章 + VIP 徽章 + 昵称 #1AFFCD max-w50 truncate + " Entered Room" + 可选座驾图(size 26)
struct RowEnterRoom: View {
    let sender: SenderProfile?
    let vehicleImg: String?
    let itemSmallImg: String?
    let theme: PublicChatTheme

    var body: some View {
        HStack(spacing: 4) {
            if let s = sender {
                // v24（B1）：大 R 徽章前置（仅 Live 场景，对齐 H5 §9.6 messageScroller.vue L577）
                if s.isActiveTycoon && theme.scene == .live { ActiveTycoonBadge(style: .bigRText, size: .small) }
                if let lv = s.userLevel, lv > 0 { UserLevelBadge(level: lv, size: .small) }
                if s.isVip { VIPBadge(size: .small) }
                Text(s.nickname)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))   // #1AFFCD
                    .lineLimit(1)
                    .frame(maxWidth: 50, alignment: .leading)
            }
            Text("Entered Room")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            if let img = itemSmallImg ?? vehicleImg, let url = URL(string: img), !img.isEmpty {
                CachedAsyncImage(url: url, contentMode: .fit) { Color.clear }
                    .frame(width: 26, height: 26)
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 212, minHeight: 26)
        .background(levelEnterBg, in: RoundedRectangle(cornerRadius: 20))
    }

    /// H5 setLevelEnterBg tier → 单色渐变（bg1-6：CSS 纯色 → 0 透明；bg7-11：H5 是 border image，iOS 简化为类似色渐变）
    /// 对齐 H5 L65-92 分档：0 / 1 / 2-10 / 11-20 / 21-30 / 31-40 / 41-45 / 46-50 / 51-55 / 56-60 / 61-65 / 66+
    ///
    /// v24（B1）：`sender.isActiveTycoon && theme.scene == .live` 覆盖为**金色 gradient**
    /// （对齐 H5 messageScroller.vue L878-888 `tycoon-enter-bg` 紫红→橙 + 金边）
    private var levelEnterBg: LinearGradient {
        let s = sender
        if s?.isActiveTycoon == true && theme.scene == .live {
            return LinearGradient(
                colors: [Color(red: 227/255, green: 106/255, blue: 205/255),   // 紫红 #E36ACD
                         Color(red: 255/255, green: 187/255, blue: 2/255)],    // 橙金 #FFBB02
                startPoint: .leading, endPoint: .trailing
            )
        }
        let lv = s?.userLevel ?? 0
        let color = tierColor(lv)
        return LinearGradient(
            colors: [color, color.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func tierColor(_ level: Int) -> Color {
        switch level {
        case 0:           return Color.black.opacity(0.16)   // bg0：默认灰半透（H5 undefined 沿用 rgba(0,0,0,0.16) 视觉）
        case 1:           return Color(red: 95/255, green: 143/255, blue: 188/255)   // #5F8FBC bg1
        case 2...10:      return Color(red: 94/255, green: 90/255, blue: 207/255)    // #5E5ACF bg2
        case 11...20:     return Color(red: 222/255, green: 132/255, blue: 132/255)  // #DE8484 bg3
        case 21...30:     return Color(red: 191/255, green: 134/255, blue: 94/255)   // #BF865E bg4
        case 31...40:     return Color(red: 221/255, green: 109/255, blue: 155/255)  // #DD6D9B bg5
        case 41...45:     return Color(red: 232/255, green: 98/255, blue: 154/255)   // #E8629A bg6
        case 46...50:     return Color(red: 255/255, green: 140/255, blue: 90/255)   // bg7 border image 简化色
        case 51...55:     return Color(red: 200/255, green: 90/255, blue: 200/255)   // bg8 简化色
        case 56...60:     return Color(red: 255/255, green: 100/255, blue: 150/255)  // bg9 简化色
        case 61...65:     return Color(red: 220/255, green: 60/255, blue: 100/255)   // bg10 简化色
        default:          return Color(red: 255/255, green: 80/255, blue: 60/255)    // bg11/12 简化色
        }
    }
}
