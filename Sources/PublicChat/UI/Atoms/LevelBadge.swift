import SwiftUI

/// H5 messageScroller `setLevelBg(item)` 对齐：Lv.N 徽章 h14 w39 rounded-27
/// 分档背景从 tier 0-10 派色（Phase 1 用简化 tier→色；未来接 UserLevelBadge tier gradient 表）
struct PublicChatLevelBadge: View {
    let level: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.system(size: 8))
                .foregroundColor(.white)
            Text("Lv.\(level)")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: 39, height: 14)
        .background(tierBackground, in: Capsule())
    }

    private var tierBackground: LinearGradient {
        let tier = LevelTierResolver.tier(for: level)
        let colors: [Color]
        switch tier {
        case 0...2: colors = [Color(red: 0.55, green: 0.65, blue: 0.75), Color(red: 0.35, green: 0.45, blue: 0.55)]
        case 3...5: colors = [Color(red: 0.20, green: 0.65, blue: 0.95), Color(red: 0.10, green: 0.45, blue: 0.85)]
        case 6...8: colors = [Color(red: 0.75, green: 0.20, blue: 0.85), Color(red: 0.55, green: 0.10, blue: 0.65)]
        default:    colors = [Color(red: 0.95, green: 0.55, blue: 0.20), Color(red: 0.85, green: 0.35, blue: 0.05)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}
