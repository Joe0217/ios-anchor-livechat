import SwiftUI

/// 主播 / 用户 **等级徽章公共组件**（视觉基准：Message 列表设计稿；逻辑对齐 H5 `c-levelBadge.vue`）。
///
/// **本工程唯一等级胶囊组件** —— PublicChat / Live / PK / Message / Call / UserCard 全部走它，
/// 禁止再写 ad-hoc `HStack + Text("Lv.\(n)")` 实现（参 [prefer-shared-component-over-adhoc]）。
///
/// **视觉基准**：Message 列表设计稿（2026-07-10 用户明示"直接使用"）——Capsule + padding + `crown.fill`
/// SF Symbol + 白色文本。**不**照抄 H5 rounded-8 + vipX.webp 切图（iOS 侧无此资源）。
///
/// **逻辑对齐 H5 `userLevelStatus.ts` 11 段渐变配置**（1-9 / 10-19 / 20-29 / 30-39 / 40-44 /
/// 45-49 / 50-54 / 55-59 / 60-64 / 65-70 / 70+），每档独立 linear gradient。
///
/// **Size 三档**（padding / icon / text 按比例缩放，Capsule 形状不变）：
/// - `.small`  padding H4/V1 · icon7 · text8（PublicChat 公屏 / marquee 密集场景，等同旧 PublicChatLevelBadge）
/// - `.medium` padding H5/V2 · icon8 · text9（**默认**；等同 Message 列表原视觉基准）
/// - `.large`  padding H6/V3 · icon10 · text11（详情页 / 用户名片）
///
/// **用法**：
/// ```swift
/// UserLevelBadge(level: 25)                          // Int 直接传，默认 .medium
/// UserLevelBadge(level: 25, size: .small)            // 明示 size
/// UserLevelBadge(levelName: user.levelName)          // 从接口 String? 传，nil/空/"0" 自动不渲染
/// ```
struct UserLevelBadge: View {
    enum Size {
        case small, medium, large

        var paddingH: CGFloat { self == .small ? 4 : self == .medium ? 5 : 6 }
        var paddingV: CGFloat { self == .small ? 1 : self == .medium ? 2 : 3 }
        var iconSize: CGFloat { self == .small ? 7 : self == .medium ? 8 : 10 }
        var textSize: CGFloat { self == .small ? 8 : self == .medium ? 9 : 11 }
    }

    let level: Int
    let size: Size

    /// 主入口：Int 等级值
    init(level: Int, size: Size = .medium) {
        self.level = level
        self.size = size
    }

    /// 便捷入口：从接口 String? 传入；nil/空/非数字自动转 0 → body 内不渲染（调用方无需判空）
    init(levelName: String?, size: Size = .medium) {
        self.level = Int(levelName ?? "") ?? 0
        self.size = size
    }

    var body: some View {
        // level <= 0 时不渲染（对齐 H5 `<div v-if="level">` 语义）
        if level > 0 {
            HStack(spacing: 2) {
                Image(systemName: "crown.fill")
                    .font(.system(size: size.iconSize))
                    .foregroundStyle(.white)
                Text("Lv.\(level)")
                    .font(.system(size: size.textSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, size.paddingH)
            .padding(.vertical, size.paddingV)
            .background(
                LinearGradient(colors: Self.gradient(for: level),
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(Capsule())
            .accessibilityLabel(L10n.messageA11yLevelFormat("\(level)"))
        }
    }

    /// 11 段渐变映射（对齐 H5 c-levelBadge.vue levelConfigs 表）
    static func gradient(for level: Int) -> [Color] {
        switch level {
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
