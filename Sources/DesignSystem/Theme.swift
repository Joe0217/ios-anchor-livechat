import SwiftUI

/// 设计系统 token（首个引入）。
///
/// 取值源自 Work 设计稿（750×1860 = 375pt@2x）多 agent 提取 + 人工读图校验。
/// 后续页面复用此处的配色 / 间距 / 字号，避免每屏重新猜测，保证多屏一致性。
/// 颜色用 0xRRGGBB 字面量声明；布局尺寸为 375pt 逻辑宽度下的点值。
enum Theme {

    // MARK: - 配色
    enum Palette {
        // MARK: 品牌主题色（单一来源，改主题改这里；下方场景色引用这些）
        /// 通用黄 / SS 级
        static let brandYellow = Color(hex: 0xFFE600)
        /// 通用橘 / S 级
        static let brandOrange = Color(hex: 0xFD8965)
        /// A 级
        static let brandPinkA  = Color(hex: 0xFB4DA6)
        /// 通用深粉 / B 级
        static let brandPink   = Color(hex: 0xFB0FEB)
        /// 通用紫 / New 级
        static let brandPurple = Color(hex: 0xBC53F5)
        /// C 级
        static let brandBlue   = Color(hex: 0x7CA2F5)
        /// D 级
        static let brandCyan   = Color(hex: 0x32F1EA)

        /// 通用次级白色文字 / 首页顶部 tab 未选中（白 60%）
        static let textSecondaryWhite = Color.white.opacity(0.6)
        /// 底部 tab bar 未选中文案
        static let tabBarInactive     = Color(hex: 0xAA9FC2)

        /// 在线状态
        static let statusOnline  = Color(hex: 0x10F496)
        /// 忙碌状态
        static let statusBusy    = Color(hex: 0xFF9E6A)
        /// 不在线状态
        static let statusOffline = Color(hex: 0x726B86)

        // MARK: 基础场景色
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
        static let accentYellow     = brandYellow
        /// 强调绿（好评率）
        static let accentGreen      = Color(hex: 0x08FF77)
        /// 描边胶囊（Detail / Withdrawal）边框与文字
        static let outlinePill      = Color(hex: 0x95909E)
        /// 未激活 tab 文字（底部 tab bar）
        static let tabInactiveLabel = tabBarInactive
        /// 激活 tab（Work）
        static let tabActive        = brandYellow
        /// 在线开关「关」态底色（灰紫）
        static let onlineToggleOff  = Color(hex: 0x463C5C)

        // MARK: Live 页（设计稿还原）
        /// Live 页顶部紫色亮区
        static let liveTopPurple        = Color(hex: 0x3D1862)
        /// Live 页中段深紫
        static let liveMidPurple        = Color(hex: 0x1F0938)
        /// Live 页底部近黑紫（与 screenBackground 相接）
        static let liveBottomDark       = Color(hex: 0x0B0010)
        /// 顶部子 tab 选中文字（橙金）
        static let liveSubTabSelected   = Color(hex: 0xFFB800)
        /// 顶部子 tab 未选中文字（白 60%）
        static let liveSubTabUnselected = textSecondaryWhite
        /// 在线绿点
        static let liveOnlineDot        = statusOnline
        /// 礼物通知条主紫
        static let liveNoticeBarPurple  = Color(hex: 0x4A2275)
        /// 礼物通知条强调粉
        static let liveNoticeBarPink    = Color(hex: 0xA03A8C)
        /// 礼物通知条玫红描边
        static let liveNoticeBarBorder  = Color(hex: 0xFF4D8F)
        /// 礼物通知条"Emma" 用户名绿
        static let liveNoticeUserGreen  = Color(hex: 0x3DFFA0)
        /// 礼物通知条数字金
        static let liveNoticeNumber     = Color(hex: 0xFFD700)
        /// 圣诞 banner 紫描边
        static let liveBannerBorder     = Color(hex: 0xA03AFF)
        /// 圣诞 banner 底色
        static let liveBannerFill       = Color(hex: 0x2A0E47)
        /// 直播卡片头像名称白
        static let liveCardName         = Color.white
        /// 观看人数徽章橙
        static let liveViewerBadge      = Color(hex: 0xFF6B00)

        // MARK: List 子页（设计稿还原）
        /// Online/Prime 切换器容器底色
        static let liveListSwitcherTrack    = Color(hex: 0x1A0F2E)
        /// Online/Prime 选中胶囊渐变起点
        static let liveListSwitcherOnA      = Color(hex: 0x6C2BCB)
        /// Online/Prime 选中胶囊渐变终点
        static let liveListSwitcherOnB      = Color(hex: 0xFF3D6E)
        /// 选中态文字（黄）
        static let liveListSwitcherSelected = Color(hex: 0xFFE600)
        /// 未选中文字
        static let liveListSwitcherUnselected = Color.white.opacity(0.85)
        /// Invite banner 渐变起点（紫）
        static let liveListInviteBgA        = Color(hex: 0x6722A5)
        /// Invite banner 渐变终点（粉）
        static let liveListInviteBgB        = Color(hex: 0xC04CE1)
        /// Invite banner 标题黄
        static let liveListInviteTitle      = Color(hex: 0xFFE066)
        /// Invite banner 副标题
        static let liveListInviteSubtitle   = Color.white.opacity(0.85)
        /// 用户卡片背景
        static let liveListCardFill         = Color(hex: 0x14082A, opacity: 0.85)
        /// 用户卡片描边
        static let liveListCardBorder       = Color.white.opacity(0.06)
        /// 用户卡片名称白
        static let liveListUserName         = Color.white
        /// 用户卡片次要描述粉
        static let liveListUserMeta         = Color(hex: 0xC9A0B8)
        /// 用户卡片地点文字
        static let liveListLocationText     = Color(hex: 0xC9A0B8)
        /// 头像在线小圆点（与 Live 页同款）
        static let liveListOnlineDot        = statusOnline

        // MARK: Profile 页（设计稿还原）
        /// 整页底色（顶部背景图下方继续到底部 tab 之间的近黑紫）
        static let profileBackground   = Color(hex: 0x0B0010)
        /// 名字白
        static let profileName         = Color.white
        /// ID 浅紫灰
        static let profileIdText       = Color(hex: 0xC8B6E0, opacity: 0.7)
        /// 年龄 / 位置 meta 文字
        static let profileMetaText     = Color.white.opacity(0.85)
        /// SS 段位粉红
        static let profileTier         = Color(hex: 0xFF3D7F)
        /// 800/min 白
        static let profileRate         = Color.white
        /// stats 分隔细线
        static let profileStatDivider  = Color.white.opacity(0.18)
        /// stats caption 灰
        static let profileStatCaption  = Color(hex: 0xC8B6E0, opacity: 0.8)
        /// 描述正文白
        static let profileDesc         = Color.white
        /// Tab 选中黄
        static let profileTabActive    = Color(hex: 0xFFE600)
        /// Tab 未选中灰
        static let profileTabInactive  = Color(hex: 0x95909E)
        /// section 标题白
        static let profileSection      = Color.white
        /// 网格 cell 占位（无图时）
        static let profileGridPlaceholder = Color(hex: 0x2B213E)

        // MARK: Blocklist 页（I-1 设计稿还原）
        /// 黑名单条目主文本（昵称）— 白
        static let blocklistName       = Color.white
        /// 黑名单条目次要文本（国家 / 年龄）— 白 85%
        static let blocklistMeta       = Color.white.opacity(0.85)
        /// 黑名单条目日期 + 删除图标 — 灰 #9CA3AF（H5 gray-400 同步）
        static let blocklistTertiary   = Color(hex: 0x9CA3AF)
        /// 默认头像兜底底色（无头像 URL / 加载失败时）— 复用 cardFill 同色 0x2B213E（review #17）
        static let blocklistAvatarFallback = cardFill
        /// 空态 + 错误态图标颜色（白 30%）
        static let blocklistEmptyIcon  = Color.white.opacity(0.3)
        /// retry 按钮 capsule 背景（白 15%）
        static let blocklistRetryButton = Color.white.opacity(0.15)
        /// retry 按钮 capsule 文字（白）
        static let blocklistRetryText   = Color.white
        /// 错误态 message 文字（白 80%）
        static let blocklistErrorMessage = Color.white.opacity(0.8)
        /// transient toast 背景（黑 70%）
        static let blocklistToastBackground = Color.black.opacity(0.7)
    }

    // MARK: - 间距
    enum Metric {
        /// 屏幕左右安全边距
        static let screenMargin: CGFloat   = 12
        /// 主区块间垂直间距（卡片之间的外边距）
        static let sectionSpacing: CGFloat = 10
        /// 卡片内边距
        static let cardPadding: CGFloat    = 10
        /// 三张 stat 卡之间水平间距
        static let statCardGap: CGFloat    = 10
        /// stat 卡内：数字与 caption 间距
        static let statNumberToCaption: CGFloat = 6
        /// 工具图标 tile 边长
        static let toolTile: CGFloat       = 36
        /// 工具网格行间距
        static let toolRowSpacing: CGFloat = 22
        /// 底部 tab 栏可见高度（图标+标签，不含 home indicator 安全区）
        static let tabBarHeight: CGFloat   = 52

        // MARK: Live 页（设计稿还原）
        /// Live 页内容左右边距
        static let liveScreenMargin: CGFloat   = 12
        /// 顶部子 tab 横向间距
        static let liveSubTabGap: CGFloat      = 24
        /// 顶部右侧操作按钮间距
        static let liveTopActionGap: CGFloat   = 10
        /// 礼物通知条高度
        static let liveNoticeBarHeight: CGFloat = 44
        /// 圣诞 banner 高度
        static let liveBannerHeight: CGFloat   = 96
        /// 直播卡片宽高比（宽/高，SwiftUI aspectRatio 语义）。3:4 竖向卡片
        static let liveCardWidthOverHeight: CGFloat = 3.0 / 4.0
        /// 直播卡片网格间距
        static let liveCardGap: CGFloat        = 8

        // MARK: List 子页（设计稿还原）
        /// Online/Prime 切换器高度
        static let liveListSwitcherHeight: CGFloat = 38
        /// Invite banner 高度
        static let liveListInviteHeight: CGFloat   = 100
        /// 用户卡片高度
        static let liveListCardHeight: CGFloat     = 80
        /// 用户卡片头像尺寸
        static let liveListAvatarSize: CGFloat     = 56
        /// 用户卡片右侧动作按钮尺寸
        static let liveListActionSize: CGFloat     = 48
        /// 用户卡片之间垂直间距
        static let liveListCardGap: CGFloat        = 10

        // MARK: Profile 页（设计稿还原）
        /// 顶部紫色背景图层覆盖高度（约等于 Header 实际内容高度；
        /// 实际 Header 由内容自适应，背景渐变到底色平滑过渡）
        static let profileHeaderHeight: CGFloat = 220
        /// 头像外环直径
        static let profileAvatarSize: CGFloat   = 72
        /// 头像内图直径（与外环间距 4pt 单边）
        static let profileAvatarInner: CGFloat  = 64
        /// 头像描边环宽度
        static let profileAvatarRing: CGFloat   = 3
        /// 描述文本左右内边距
        static let profileDescPadding: CGFloat  = 16
        /// Album/Gifts/Moment tab 间水平间距
        static let profileTabGap: CGFloat       = 24
        /// Photos / Videos 网格列数
        static let profileGridColumns: Int      = 3
        /// 网格 cell 间距（横纵相同）
        static let profileGridGap: CGFloat      = 6
        /// 网格 section 上下间距
        static let profileGridSectionGap: CGFloat = 18

        // MARK: Blocklist 页（I-1 设计稿还原）
        /// 行内左右内边距
        static let blocklistRowHPadding: CGFloat = 16
        /// 行内上下内边距
        static let blocklistRowVPadding: CGFloat = 12
        /// 头像直径
        static let blocklistAvatarSize: CGFloat  = 40
        /// 头像与文字之间间距
        static let blocklistAvatarGap: CGFloat   = 10
        /// 昵称与副信息（位置/年龄）之间垂直间距
        static let blocklistNameToMetaGap: CGFloat = 6
        /// meta 行内图标与文字间距
        static let blocklistMetaIconGap: CGFloat = 4
        /// meta 行内"位置"与"年龄"两组之间间距
        static let blocklistMetaGroupGap: CGFloat = 8
        /// 位置/年龄图标尺寸
        static let blocklistMetaIconSize: CGFloat = 12
        /// 删除按钮尺寸
        static let blocklistDeleteSize: CGFloat   = 16
        /// 日期与删除按钮垂直间距
        static let blocklistDateToDeleteGap: CGFloat = 6
        /// 按钮 disabled 透明度
        static let blocklistButtonDisabledOpacity: Double = 0.5
        /// 主信息区与右侧（日期+删除）之间最小间距
        static let blocklistMainToTrailingMin: CGFloat = 8
        /// 空态 + 错误态中心图标尺寸
        static let blocklistEmptyIconSize: CGFloat = 36
        /// 错误态警告图标尺寸
        static let blocklistErrorIconSize: CGFloat = 32
        /// 错误态间距（图标 / 文字 / 按钮垂直堆叠）
        static let blocklistErrorVStackSpacing: CGFloat = 12
        /// retry 按钮内边距
        static let blocklistRetryPaddingH: CGFloat = 20
        static let blocklistRetryPaddingV: CGFloat = 8
        /// 空态文字与图标的左右内边距
        static let blocklistEmptyTextHPadding: CGFloat = 32
        /// 错误态文字左右内边距
        static let blocklistErrorTextHPadding: CGFloat = 24
        /// footer 行垂直内边距
        static let blocklistFooterVPadding: CGFloat = 16
        /// transient toast 距顶部
        static let blocklistToastTopPadding: CGFloat = 8
        /// transient toast 横向内边距
        static let blocklistToastHPadding: CGFloat = 14
        /// transient toast 垂直内边距
        static let blocklistToastVPadding: CGFloat = 8
    }

    // MARK: - 圆角
    enum Radius {
        static let statCard: CGFloat = 12
        static let bigCard: CGFloat  = 16
        static let toolTile: CGFloat = 14

        // MARK: Live 页（设计稿还原）
        /// 礼物通知条胶囊
        static let liveNoticeBar: CGFloat = 22
        /// 圣诞活动 banner
        static let liveBanner: CGFloat    = 14
        /// 直播卡片
        static let liveCard: CGFloat      = 16
        /// 观看人数徽章
        static let liveViewerBadge: CGFloat = 6
        /// Online/Prime 切换器容器
        static let liveListSwitcher: CGFloat = 19
        /// Invite banner
        static let liveListInvite: CGFloat   = 16
        /// 用户卡片
        static let liveListCard: CGFloat     = 14

        // MARK: Profile 页（设计稿还原）
        /// 网格 cell 圆角
        static let profileGridCell: CGFloat = 10
    }

    // MARK: - 字号
    enum Typography {
        /// stat 卡大数字（128 / 98% / 999999）
        static let bigStat   = Font.system(size: 26, weight: .medium)
        /// 收益网格数字（222 / 1280 …）
        static let income    = Font.system(size: 22, weight: .medium)
        /// 卡片 / 区块标题（Today's Income / Tools）
        static let sectionTitle = Font.system(size: 15, weight: .medium)
        /// caption / 说明文字
        static let caption   = Font.system(size: 13, weight: .regular)
        /// 描边胶囊文字
        static let pill      = Font.system(size: 12, weight: .regular)
        /// 分数行
        static let score     = Font.system(size: 14, weight: .regular)
        /// 段位标签（D C NEW B A S SS）
        static let tier      = Font.system(size: 12, weight: .medium)
        /// 工具图标标签
        static let toolLabel = Font.system(size: 13, weight: .regular)
        /// 底部 tab 标签
        static let tabLabel  = Font.system(size: 11, weight: .medium)

        // MARK: Live 页（设计稿还原）
        /// 顶部子 tab 选中态字号 18pt medium
        static let liveSubTabActive   = Font.system(size: 18, weight: .medium)
        /// 顶部子 tab 未选中态字号 16pt medium
        static let liveSubTabInactive = Font.system(size: 16, weight: .medium)
        /// 礼物通知条用户名/正文
        static let liveNotice    = Font.system(size: 13, weight: .semibold)
        /// 礼物通知条金币数字
        static let liveNoticeNum = Font.system(size: 13, weight: .heavy)
        /// 直播卡片头像名称
        static let liveCardName  = Font.system(size: 14, weight: .semibold)
        /// 直播卡片观看人数徽章
        static let liveViewerBadge = Font.system(size: 12, weight: .bold)
        /// 排行榜徽章 +100K
        static let liveRankNum   = Font.system(size: 11, weight: .heavy)

        // MARK: List 子页
        /// Online/Prime 切换器文字
        static let liveListSwitcher = Font.system(size: 15, weight: .heavy)
        /// Invite banner 标题
        static let liveListInviteTitle    = Font.system(size: 22, weight: .heavy)
        /// Invite banner 副标题
        static let liveListInviteSubtitle = Font.system(size: 12, weight: .regular)
        /// 用户卡片昵称
        static let liveListUserName = Font.system(size: 16, weight: .semibold)
        /// 用户卡片次要描述（等级 / VIP / 地点）
        static let liveListMeta     = Font.system(size: 12, weight: .regular)

        // MARK: Profile 页（设计稿还原）
        /// 名字大字
        static let profileName     = Font.system(size: 20, weight: .medium)
        /// ID 灰色小字
        static let profileId       = Font.system(size: 10, weight: .regular)
        /// 年龄 / 国旗行
        static let profileMeta     = Font.system(size: 12, weight: .regular)
        /// SS 段位标签（大粉红）
        static let profileTier     = Font.system(size: 18, weight: .medium)
        /// 800/min 单价
        static let profileRate     = Font.system(size: 11, weight: .regular)
        /// stats 数字
        static let profileStatNum  = Font.system(size: 18, weight: .medium)
        /// stats caption
        static let profileStatCap  = Font.system(size: 11, weight: .regular)
        /// 描述正文（Starry Guide）
        static let profileDesc     = Font.system(size: 13, weight: .regular)
        /// Tab 选中
        static let profileTabActive   = Font.system(size: 16, weight: .medium)
        /// Tab 未选中
        static let profileTabInactive = Font.system(size: 15, weight: .regular)
        /// section 标题（Photos (6/9)）
        static let profileSection  = Font.system(size: 14, weight: .medium)

        // MARK: Blocklist 页（I-1 设计稿还原）
        /// 行内昵称（白色 medium 16pt）
        static let blocklistName    = Font.system(size: 16, weight: .medium)
        /// meta 行（位置/年龄）
        static let blocklistMeta    = Font.system(size: 12, weight: .regular)
        /// 日期（灰）
        static let blocklistDate    = Font.system(size: 12, weight: .regular)
        /// 空态文案
        static let blocklistEmpty   = Font.system(size: 14, weight: .regular)
        /// transient toast 字体
        static let blocklistToast   = Font.system(size: 13, weight: .medium)
    }

    // MARK: - 渐变与段位光谱
    enum Gradients {
        /// 段位光谱色（D→SS），既用于彩虹进度条也用于段位标签着色
        static let tierSpectrum: [Color] = [
            Palette.brandCyan,   // D  青
            Palette.brandBlue,   // C  蓝
            Palette.brandPurple, // NEW 紫
            Palette.brandPink,   // B  深粉
            Palette.brandPinkA,  // A  粉
            Palette.brandOrange, // S  橘
            Palette.brandYellow, // SS 黄
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

        /// 头像描边环（金黄→粉,角向）
        static let avatarRing = AngularGradient(
            colors: [
                Color(hex: 0xFFD60A), Color(hex: 0xFF6B9D),
                Color(hex: 0xC026D3), Color(hex: 0xFFD60A),
            ],
            center: .center
        )

        /// 在线开关「开」态胶囊（紫→品红→粉，横向）
        static let onlineToggleOn = LinearGradient(
            colors: [Color(hex: 0x9B1FC4), Color(hex: 0xD81E9E), Color(hex: 0xFF2E7E)],
            startPoint: .leading,
            endPoint: .trailing
        )

        // MARK: Live 页（设计稿还原）
        /// Live 页整页背景：顶部紫→中段深紫→底部近黑（与切图"背景填图"作底配合）
        static let livePageBackground = LinearGradient(
            colors: [Palette.liveTopPurple, Palette.liveMidPurple, Palette.liveBottomDark],
            startPoint: .top,
            endPoint: .bottom
        )

        /// 顶部子 tab "Live" 选中字渐变（橙→金）
        static let liveSubTabText = LinearGradient(
            colors: [Color(hex: 0xFF7A00), Color(hex: 0xFFB800)],
            startPoint: .top,
            endPoint: .bottom
        )

        /// 礼物通知条横向渐变背景（紫→品红→紫）
        static let liveNoticeBar = LinearGradient(
            colors: [
                Color(hex: 0x4A2275, opacity: 0.85),
                Color(hex: 0xA03A8C, opacity: 0.95),
                Color(hex: 0x4A2275, opacity: 0.85),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )

        /// 观看人数徽章渐变（橙→红）
        static let liveViewerBadge = LinearGradient(
            colors: [Color(hex: 0xFFB800), Color(hex: 0xFF4D00)],
            startPoint: .top,
            endPoint: .bottom
        )

        // MARK: List 子页
        /// Online/Prime 选中胶囊（紫→粉）
        static let liveListSwitcherSelected = LinearGradient(
            colors: [Palette.liveListSwitcherOnA, Palette.liveListSwitcherOnB],
            startPoint: .leading,
            endPoint: .trailing
        )

        /// Invite friends banner 横向渐变（紫→粉）
        static let liveListInviteBanner = LinearGradient(
            colors: [Palette.liveListInviteBgA, Palette.liveListInviteBgB],
            startPoint: .leading,
            endPoint: .trailing
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
