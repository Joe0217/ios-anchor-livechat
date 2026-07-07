import SwiftUI

/// 主播段位 badge（对齐 H5 `list.vue:362-367`：Lv.X 彩色渐变胶囊 + crown 图标）。
///
/// **对齐 H5 `userLevelStatus.ts` 11 段渐变配置**（`Sources/Message/UI/UserLevelBadge.swift`）：
/// - 1-9   浅紫 → 桃紫
/// - 10-19 深紫 → 亮紫
/// - 20-29 亮紫 → 品红
/// - 30-39 电紫 → 玫红
/// - 40-44 深紫 → 灰紫
/// - 45-49 紫罗兰 → 深紫红
/// - 50-54 紫 → 粉紫
/// - 55-59 亮紫 → 玫粉
/// - 60-64 灰紫 → 玫棕
/// - 65-70 紫 → 棕红
/// - 70+   紫 → 橘棕
///
/// **图标**：SF Symbol `crown.fill` 占位（H-2 真图标 vipX.webp 素材替换）
struct UserLevelBadge: View {
    let levelName: String   // 传入非空非"0"字符串（View 层判 shouldShow 后再渲染）

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "crown.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white)
            Text("Lv.\(levelName)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            LinearGradient(colors: Self.gradient(for: levelName),
                           startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(Capsule())
        .accessibilityLabel(L10n.messageA11yLevelFormat(levelName))
    }

    private static func gradient(for levelName: String) -> [Color] {
        let n = Int(levelName) ?? 0
        switch n {
        case 1...9:   return [Color(hex: 0x64439D), Color(hex: 0x8F5DB6)]
        case 10...19: return [Color(hex: 0x583B8E), Color(hex: 0x924CB7)]
        case 20...29: return [Color(hex: 0x906CC9), Color(hex: 0xBD5DD8)]
        case 30...39: return [Color(hex: 0x924CEC), Color(hex: 0xC737F0)]
        case 40...44: return [Color(hex: 0x541ABA), Color(hex: 0x84459A)]
        case 45...49: return [Color(hex: 0x6E2BD8), Color(hex: 0x8D3AB0)]
        case 50...54: return [Color(hex: 0x5B2C9A), Color(hex: 0xAB56A6)]
        case 55...59: return [Color(hex: 0x7D44DB), Color(hex: 0xD263C7)]
        case 60...64: return [Color(hex: 0x604685), Color(hex: 0xB07793)]
        case 65...69: return [Color(hex: 0x6B49A8), Color(hex: 0xB16B72)]
        default:      return [Color(hex: 0x724EB2), Color(hex: 0xDA9885)]
        }
    }
}

/// VIP 图标 badge（对齐 H5 `list.vue:368-372`：金色 star.circle 占位）。
struct VIPBadge: View {
    var body: some View {
        Image(systemName: "star.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(
                LinearGradient(colors: [Color(hex: 0xFFD700), Color(hex: 0xFF9900)],
                               startPoint: .top, endPoint: .bottom)
            )
            .accessibilityLabel(L10n.messageA11yVIP)
    }
}

/// 活跃大 R badge（对齐 H5 `CActiveTycoonBadge`：闪电/宝石图标）。
struct ActiveTycoonBadge: View {
    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(3)
            .background(
                LinearGradient(colors: [Color(hex: 0xFF6B6B), Color(hex: 0xE94E77)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(Capsule())
            .accessibilityLabel(L10n.messageA11yActiveTycoon)
    }
}

// MARK: - Color hex helper

extension Color {
    /// 从 24-bit hex int 构造 Color（例：`0x64439D`）
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
