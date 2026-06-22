import SwiftUI

/// 设计系统 token（首个引入）。
///
/// 取值源自 Work 设计稿（750×1860 = 375pt@2x）多 agent 提取 + 人工读图校验。
/// 后续页面复用此处的配色 / 间距 / 字号，避免每屏重新猜测，保证多屏一致性。
/// 颜色用 0xRRGGBB 字面量声明；布局尺寸为 375pt 逻辑宽度下的点值。
enum Theme {

    // MARK: - 配色
    enum Palette {
        /// 页面背景：近黑带极淡紫，纯色非渐变
        static let screenBackground = Color(hex: 0x0B0010)
        /// 卡片 / 面板悬浮表面
        static let cardFill         = Color(hex: 0x2B213E)
        /// 卡片内细分隔线
        static let divider          = Color(hex: 0x3A3150)
        /// 主文本（标题 / 收益数字）
        static let textPrimary      = Color.white
        /// 次要文本（caption / 说明）
        static let textSecondary    = Color(hex: 0x95909E)
        /// 强调黄（通话数 / 周收益 / 激活 tab）
        static let accentYellow     = Color(hex: 0xFFE600)
        /// 强调绿（好评率）
        static let accentGreen      = Color(hex: 0x08FF77)
        /// 描边胶囊（Detail / Withdrawal）边框与文字
        static let outlinePill      = Color(hex: 0x95909E)
        /// 未激活 tab 文字
        static let tabInactiveLabel = Color(hex: 0x6E6483)
        /// 激活 tab（Work）
        static let tabActive        = Color(hex: 0xFFE600)
    }

    // MARK: - 间距
    enum Metric {
        /// 屏幕左右安全边距
        static let screenMargin: CGFloat   = 12
        /// 主区块间垂直间距
        static let sectionSpacing: CGFloat = 16
        /// 卡片内边距
        static let cardPadding: CGFloat    = 14
        /// 三张 stat 卡之间水平间距
        static let statCardGap: CGFloat    = 10
        /// stat 卡内：数字与 caption 间距
        static let statNumberToCaption: CGFloat = 6
        /// 工具图标 tile 边长
        static let toolTile: CGFloat       = 56
        /// 工具网格行间距
        static let toolRowSpacing: CGFloat = 22
        /// 底部 tab 栏可见高度（图标+标签，不含 home indicator 安全区）
        static let tabBarHeight: CGFloat   = 52
    }

    // MARK: - 圆角
    enum Radius {
        static let statCard: CGFloat = 12
        static let bigCard: CGFloat  = 16
        static let toolTile: CGFloat = 14
    }

    // MARK: - 字号
    enum Typography {
        /// stat 卡大数字（128 / 98% / 999999）
        static let bigStat   = Font.system(size: 26, weight: .bold)
        /// 收益网格数字（222 / 1280 …）
        static let income    = Font.system(size: 22, weight: .semibold)
        /// 卡片 / 区块标题（Today's Income / Tools）
        static let sectionTitle = Font.system(size: 18, weight: .semibold)
        /// caption / 说明文字
        static let caption   = Font.system(size: 13, weight: .regular)
        /// 描边胶囊文字
        static let pill      = Font.system(size: 12, weight: .regular)
        /// 分数行
        static let score     = Font.system(size: 14, weight: .regular)
        /// 段位标签（D C NEW B A S SS）
        static let tier      = Font.system(size: 12, weight: .bold)
        /// 工具图标标签
        static let toolLabel = Font.system(size: 13, weight: .regular)
        /// 底部 tab 标签
        static let tabLabel  = Font.system(size: 11, weight: .medium)
    }

    // MARK: - 渐变与段位光谱
    enum Gradients {
        /// 段位光谱色（D→SS），既用于彩虹进度条也用于段位标签着色
        static let tierSpectrum: [Color] = [
            Color(hex: 0x00E0FF), // D  青
            Color(hex: 0x3B82F6), // C  蓝
            Color(hex: 0x8B5CF6), // NEW 紫
            Color(hex: 0xD946EF), // B  品红
            Color(hex: 0xFF3D7F), // A  粉红
            Color(hex: 0xFF8A3D), // S  橙
            Color(hex: 0xFFE600), // SS 黄
        ]

        /// 彩虹进度条
        static let rainbow = LinearGradient(
            colors: tierSpectrum,
            startPoint: .leading,
            endPoint: .trailing
        )

        /// 等级徽章胶囊（紫→品红→粉）
        static let levelBadge = LinearGradient(
            colors: [Color(hex: 0x7C3AED), Color(hex: 0xC026D3), Color(hex: 0xEC4899)],
            startPoint: .leading,
            endPoint: .trailing
        )

        /// 头像描边环（金黄→粉，角向）
        static let avatarRing = AngularGradient(
            colors: [
                Color(hex: 0xFFD60A), Color(hex: 0xFF6B9D),
                Color(hex: 0xC026D3), Color(hex: 0xFFD60A),
            ],
            center: .center
        )
    }
}

// MARK: - Color(hex:) 便捷构造

extension Color {
    /// 用 0xRRGGBB 字面量构造（sRGB，无 alpha 参数时不透明）
    init(hex: UInt, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
