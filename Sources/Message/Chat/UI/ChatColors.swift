import SwiftUI

/// P2P 私聊页视觉规范集中管理（H-2 spec §1，对齐 H5 chat 页 CSS 提取）。
///
/// **来源**：H5 `src/views/chat/*.vue` + `assets/app.less` CSS 值。修主题色时**只改本文件**。
enum ChatPalette {
    /// 主色渐变（send 按钮 / 高亮）：`#8515FF → #E40132`
    static let primaryGradient = LinearGradient(
        colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
        startPoint: .leading, endPoint: .trailing
    )

    /// 主色浅色渐变（按压 / 提示）：`#B673FF → #EF6784`
    static let primaryLightGradient = LinearGradient(
        colors: [Color(hex: 0xB673FF), Color(hex: 0xEF6784)],
        startPoint: .leading, endPoint: .trailing
    )

    /// 页面背景：`#0B0010`
    static let pageBackground = Color(hex: 0x0B0010)

    /// 卡片背景 / 输入栏背景 / 相册 item：`#2B213E`
    static let cardBackground = Color(hex: 0x2B213E)

    /// 输入框边框：`#492E7C`
    static let inputBorder = Color(hex: 0x492E7C)

    /// nav 渐变（chat 页专用）：`#09001C → #0C002B`
    static let navGradient = LinearGradient(
        colors: [Color(hex: 0x09001C), Color(hex: 0x0C002B)],
        startPoint: .leading, endPoint: .trailing
    )

    /// 我方气泡背景：`#2D1F47`
    static let myBubbleBackground = Color(hex: 0x2D1F47)

    /// 对方气泡背景：`#4E1B4D`
    static let peerBubbleBackground = Color(hex: 0x4E1B4D)

    /// 系统提示 tip 卡片背景（未展示但预留 H-3）
    static let tipBackground = Color(hex: 0x2B213E)

    /// 时间分隔字色
    static let timeSeparator = Color(hex: 0x999999)

    /// 半透明白（系统提示字色）
    static let whiteAlpha60 = Color.white.opacity(0.6)
}

/// H5 消息时间分隔阈值（对齐 `msgItem.vue:195` 300000ms = 5min）
enum ChatConstants {
    /// 5 分钟：相邻两条消息时间差 ≥ 此值 → 显示时间分隔线
    static let timeSeparatorThresholdMs: Int64 = 5 * 60 * 1000

    /// 语音最长（对齐 recording.vue:34）
    static let voiceMaxDurationSec: Int = 60

    /// 语音最短（<1s 弃）
    static let voiceMinDurationSec: Int = 1

    /// 文字气泡最大宽度（H5 `max-w-210`）
    static let textBubbleMaxWidth: CGFloat = 210

    /// 图片气泡宽度（H5 `w100`）
    static let imageBubbleWidth: CGFloat = 100

    /// 音频气泡宽度（H5 `w-80`）
    static let audioBubbleWidth: CGFloat = 80

    /// 消息列表头像尺寸
    static let listAvatarSize: CGFloat = 36

    /// nav 头像尺寸
    static let navAvatarSize: CGFloat = 24
}

// MARK: - Color hex helper

extension Color {
    /// 从 0xRRGGBB int 构造（简洁替代 UIColor+hex 全套）
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
