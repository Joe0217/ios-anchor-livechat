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
        /// 朋友圈评论块背景（比 cardFill 更深一档，对齐 H5 `#F5F7F8` 反色语义）
        static let momentCommentsBackground = Color(hex: 0x1A1428)
        /// 朋友圈评论昵称色（H5 `text-color-purple`）
        static let momentCommentNickname    = Color(hex: 0xA961FF)
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
        /// transient toast 背景（黑 60%）
        static let blocklistToastBackground = Color.black.opacity(0.6)

        // MARK: UserProfile 详情页（H-0，对照 H5 视觉）
        /// like/favorite 卡片底色（H5 #2B213E）
        static let userProfileStatsCardFill = Color(hex: 0x2B213E)
        /// 头像三色光环（H5 #72ACF6 / #A211FC / #FA226A）
        static let userProfileAvatarRing1  = Color(hex: 0x72ACF6)
        static let userProfileAvatarRing2  = Color(hex: 0xA211FC)
        static let userProfileAvatarRing3  = Color(hex: 0xFA226A)
        /// FOLLOW 渐变 #8515FF → #E40132
        static let userProfileFollowGradientStart = Color(hex: 0x8515FF)
        static let userProfileFollowGradientEnd   = Color(hex: 0xE40132)
        /// FOLLOWING 紫罗兰半透明
        static let userProfileFollowingButton     = Color(hex: 0x9E7DDC).opacity(0.5)
        /// 详情页主文字 / uid 50% / stats label 50%
        static let userProfileNickname            = Color.white
        static let userProfileUid                 = Color.white.opacity(0.5)
        static let userProfileStatsLabel          = Color.white.opacity(0.5)
        /// 占位 / coming-soon 背景（与 blocklistRetryButton 同语义）
        static let userProfilePlaceholderBg       = Color.white.opacity(0.1)
        /// 菜单 / popup 黑底（H5 CMenuPop 风格）
        static let userProfileMenuBackground      = Color(hex: 0x1F1830)

        // MARK: LiveRoom 直播间（设计稿还原）
        /// 顶部主播胶囊 / 观众数徽章 / 底部输入框 通用半透明黑底
        static let liveRoomChipBackground   = Color.black.opacity(0.4)
        /// 顶部主播胶囊内主播名（14pt medium）
        static let liveRoomAnchorName       = Color.white
        /// 顶部主播胶囊内热度 / 时长（10pt）
        static let liveRoomAnchorMeta       = Color.white.opacity(0.85)
        /// Task/Diamond/Rank 徽章 row 底色（黑 30%）
        static let liveRoomBadgeBackground  = Color.black.opacity(0.3)
        /// 顶部钻石 / 排行 数字色
        static let liveRoomBadgeNumber      = Color.white
        /// 顶部 "No.27 >" 数字色（金黄）
        static let liveRoomRankNumber       = Color(hex: 0xFFD700)
        /// Underway 徽章底色（红色胶囊）
        static let liveRoomUnderwayFill     = Color(hex: 0xF43F3F)
        /// Underway 徽章文字（白）
        static let liveRoomUnderwayText     = Color.white
        /// Wishlist 卡片背景（半透黑）
        static let liveRoomWishlistBg       = Color.black.opacity(0.35)
        /// Wishlist 数字（金黄）
        static let liveRoomWishlistNumber   = Color(hex: 0xFFE066)
        /// Wishlist 进度条底色
        static let liveRoomWishlistTrack    = Color.white.opacity(0.2)
        /// Wishlist 进度条填充（金黄）
        static let liveRoomWishlistProgress = Color(hex: 0xFFE066)
        /// 公屏消息背景（半透黑胶囊）
        static let liveRoomChatBackground   = Color.black.opacity(0.35)
        /// 公屏消息 - 昵称粉（对齐 H5 color-#FD79C1）
        static let liveRoomChatNickname     = Color(hex: 0xFD79C1)
        /// 公屏消息 - 昵称高亮绿（贡献 top / to 用户）
        static let liveRoomChatNicknameHi   = Color(hex: 0x1AFFCD)
        /// 公屏消息 - 正文白
        static let liveRoomChatText         = Color.white
        /// 公屏消息 - 翻译副文（灰白）
        static let liveRoomChatTranslation  = Color.white.opacity(0.7)
        /// 公屏消息 - Host 徽章底色（红）
        static let liveRoomChatHostBadge    = Color(hex: 0xF43F3F)
        /// 公屏消息 - 等级徽章渐变起（紫）
        static let liveRoomChatLevelStart   = Color(hex: 0x7C3AED)
        /// 公屏消息 - 等级徽章渐变止（品红）
        static let liveRoomChatLevelEnd     = Color(hex: 0xEC4899)
        /// Pavate Call 按钮文字色（品红 / 与 H5 FD79C1 对齐）
        static let liveRoomPrivateCallText  = Color(hex: 0xFD79C1)
        /// 底部工具栏输入框背景（黑 30%）
        static let liveRoomInputBackground  = Color.black.opacity(0.3)
        /// 底部工具栏输入框 placeholder 文字（白 50%）
        static let liveRoomInputPlaceholder = Color.white.opacity(0.5)
        /// 底部快捷礼物 tile 底色
        static let liveRoomGiftTileBg       = Color.black.opacity(0.35)
        /// 底部快捷礼物 tile 文字
        static let liveRoomGiftTileText     = Color.white
        /// 底部快捷礼物 "Free" 蓝
        static let liveRoomGiftFreeColor    = Color(hex: 0x1AFFCD)

        // MARK: Match tab（L 里程碑设计稿还原）
        /// Match tab 选中态文字（黄，对齐 profileTabActive）
        static let matchTabSelected     = Color(hex: 0xFFE600)
        /// Match tab 未选中态文字（白）
        static let matchTabUnselected   = Color.white
        /// 跑马灯胶囊左端渐变起点（对齐 H5 c-marquee 内层 90deg #E40132）
        static let matchMarqueeBgStart  = Color(hex: 0xE40132)
        /// 跑马灯胶囊右端渐变止点（对齐 H5 90deg #6021BD）
        static let matchMarqueeBgEnd    = Color(hex: 0x6021BD)
        /// 跑马灯胶囊描边渐变起（对齐 H5 border-style 90deg #FF0026）
        static let matchMarqueeBorderStart = Color(hex: 0xFF0026)
        /// 跑马灯胶囊描边渐变止（对齐 H5 90deg #FF0088）
        static let matchMarqueeBorderEnd   = Color(hex: 0xFF0088)
        /// 跑马灯 caller 昵称绿（对齐 H5 text-#15FF3E）
        static let matchMarqueeCaller   = Color(hex: 0x15FF3E)
        /// 跑马灯 receiver 昵称黄（对齐 H5 text-#FFE600）
        static let matchMarqueeReceiver = Color(hex: 0xFFE600)
        /// 跑马灯正文白
        static let matchMarqueeText     = Color.white
        /// 主副标题白
        static let matchTitle           = Color.white
        /// 副标描述白 80%
        static let matchSubtitle        = Color.white.opacity(0.8)
        /// 页面背景（顶部渐变到 screenBackground）
        static let matchPageBackground  = screenBackground

        // MARK: Party 大厅（E 期设计稿还原 202607091b）
        /// 页面背景（复用直播间底色）
        static let partyListBackground   = liveBottomDark
        /// 房间卡片背景填充
        static let partyCardFill         = Color(hex: 0x2E1A4F, opacity: 0.75)
        /// 房间卡片描边
        static let partyCardBorder       = Color.white.opacity(0.04)
        /// 房主名字白
        static let partyRoomName         = Color.white
        /// 欢迎语灰白
        static let partyGreeting         = Color.white.opacity(0.55)
        /// pill Live+Voice 渐变起（粉红）
        static let partyPillLiveA        = Color(hex: 0xFB4DA6)
        /// pill Live+Voice 渐变止（紫粉）
        static let partyPillLiveB        = Color(hex: 0xFF6BE3)
        /// pill Voice 绿
        static let partyPillVoice        = Color(hex: 0x2ED573)
        /// pill 语言 蓝紫
        static let partyPillLanguage     = Color(hex: 0x6C4CFF)
        /// pill 文字白
        static let partyPillText         = Color.white
        /// Create Room 按钮渐变起（紫粉）
        static let partyCreateBtnA       = Color(hex: 0xC03AFF)
        /// Create Room 按钮渐变止（品红）
        static let partyCreateBtnB       = Color(hex: 0xFF3D8F)
        /// 火苗数字文字（灰白）
        static let partyHeatText         = Color.white.opacity(0.85)
        /// crown +100K badge 底（深紫圆角胶囊）
        static let partyCrownBadgeBg     = Color(hex: 0x2C1042, opacity: 0.9)
        /// crown 金黄
        static let partyCrownGold        = Color(hex: 0xFFD54A)
        /// crown badge 数字文字
        static let partyCrownText        = Color(hex: 0xFFD54A)
        /// tab icon Party inactive 用（tabBarInactive 复用）
        static let partyTabInactive      = tabBarInactive

        // MARK: Party 创房页（E-spec v5，2026-07-10）
        /// 创房页 section 标题紫（"Room name" / "Room Tagline" 等）
        static let partyCreateSectionTitle = Color(hex: 0x9B7BE2)
        /// 输入框背景
        static let partyCreateInputFill    = Color(hex: 0x2E1A4F, opacity: 0.6)
        /// 输入框描边
        static let partyCreateInputBorder  = Color.white.opacity(0.08)
        /// 输入框主文本白
        static let partyCreateInputText    = Color.white
        /// 输入框字数计数灰紫
        static let partyCreateInputCounter = Color(hex: 0x9B7BE2)
        /// picker chevron 紫粉
        static let partyCreateChevron      = Color(hex: 0xC060FF)
        /// 头像圆环渐变（从 Palette 头像 avatarRing3 借用）
        static let partyCreateAvatarRing1  = Color(hex: 0xFFC542)
        static let partyCreateAvatarRing2  = Color(hex: 0xFF5C39)
        /// 头像相机小图标背景
        static let partyCreateAvatarCameraBg = Color(hex: 0xFF9438)
        /// mode picker sheet 顶部 tab 选中态渐变（对齐 H5 create.vue linear-gradient 90deg #FF9438 #FF0090 #FE00DE）
        static let partyCreateModeTabA     = Color(hex: 0xFF9438)
        static let partyCreateModeTabB     = Color(hex: 0xFF0090)
        static let partyCreateModeTabC     = Color(hex: 0xFE00DE)
        /// mode picker sheet 顶部 tab 未选中文字
        static let partyCreateModeTabInactive = Color.white.opacity(0.5)
        /// mode picker 模板卡片选中态描边
        static let partyCreateTempSelected = Color(hex: 0xFB0FEB)
        /// mode picker 卡片底色（Lock/Unlock 都用）
        static let partyCreateTempFill     = Color(hex: 0x1F1235)

        // MARK: Party 房间内（设计稿还原 2026-07-11）
        /// 房间背景色（image 115 未覆盖处的兜底纯色）
        static let partyRoomBackground     = Color(hex: 0x0B0010)
        /// 内容层暗化遮罩（覆盖背景大图，让文字可读）
        static let partyRoomOverlay        = Color.black.opacity(0.35)
        /// 顶部主播名 白
        static let partyRoomAnchorName     = Color.white
        /// 顶部 ID 浅灰紫
        static let partyRoomAnchorId       = Color.white.opacity(0.55)
        /// 关注按钮底色（紫灰半透明）
        static let partyRoomFollowFill     = Color(hex: 0x8B84B0, opacity: 0.55)
        /// 顶部工具栏图标 tint
        static let partyRoomToolbarIcon    = Color.white
        /// 收益金黄（趟马灯/奖杯数字/箭头）
        static let partyRoomHeatGold       = Color(hex: 0xFFD54A)
        /// 观众数白
        static let partyRoomViewerCount    = Color.white
        /// 麦位视频/占位背景色（相机关时的深灰底）
        static let partyRoomSeatFill       = Color(hex: 0x1F1A26)
        /// 麦位空态椅子 stroke（粉紫圆环内的椅子）
        static let partyRoomSeatChair      = Color.white.opacity(0.5)
        /// 麦位名字胶囊底（黑透）
        static let partyRoomSeatNameFill   = Color.black.opacity(0.5)
        /// 麦位名字文字白
        static let partyRoomSeatNameText   = Color.white
        /// 麦位下方 Gems 数字胶囊底（黑透）
        static let partyRoomGemsFill       = Color.black.opacity(0.55)
        /// Gems 数字文字白
        static let partyRoomGemsText       = Color.white
        /// 静音角标底色（灰透黑）
        static let partyRoomMuteBadgeFill  = Color.black.opacity(0.35)
        /// 空占位数字（"3"、"4"、"7"）文字白
        static let partyRoomEmptyIndex     = Color.white
        /// Tab strip 选中态文字色（黄）
        static let partyRoomTabActive      = Color(hex: 0xFFE600)
        /// Tab strip 未选中态（白 55%）
        static let partyRoomTabInactive    = Color.white.opacity(0.55)
        /// Tab strip 选中下划线（黄）
        static let partyRoomTabUnderline   = Color(hex: 0xFFE600)
        /// 欢迎消息文字绿
        static let partyRoomWelcomeText    = Color(hex: 0x4EFFB0)
        /// 聊天用户名文字白
        static let partyRoomChatName       = Color.white
        /// 聊天正文白
        static let partyRoomChatText       = Color.white
        /// 礼物消息胶囊底（半透黑）
        static let partyRoomGiftMsgFill    = Color.black.opacity(0.35)
        /// 礼物消息文字白
        static let partyRoomGiftMsgText    = Color.white
        /// 底部输入框半透明底
        static let partyRoomInputFill      = Color.black.opacity(0.35)
        /// 底部输入框描边（微弱白）
        static let partyRoomInputBorder    = Color.white.opacity(0.12)
        /// 底部输入框 placeholder 白 50%
        static let partyRoomInputPlaceholder = Color.white.opacity(0.5)
        /// 底部工具栏图标圆按钮底（半透黑）
        static let partyRoomToolBtnFill    = Color.black.opacity(0.3)
        /// Lv 徽章紫渐变起
        static let partyRoomLevelStart     = Color(hex: 0x7C3AED)
        /// Lv 徽章紫渐变止
        static let partyRoomLevelEnd       = Color(hex: 0xC026D3)

        // MARK: Auth 登录页（设计稿还原 2026-07-13）
        /// 登录按钮胶囊纯色粉(设计稿采样 #FF55CC)
        static let authLoginButton        = Color(hex: 0xFF55CC)
        /// 登录按钮文字白
        static let authLoginButtonText    = Color.white
        /// 输入框填充(暗紫半透明,盖在 blur bg 上)
        static let authInputFill          = Color(hex: 0x2E1A4F, opacity: 0.45)
        /// 输入框主文本(用户输入)白
        static let authInputText          = Color.white
        /// 输入框 placeholder 白 55%
        static let authInputPlaceholder   = Color.white.opacity(0.55)
        /// 输入框右侧眼睛图标 tint(白 65%)
        static let authInputIconTint      = Color.white.opacity(0.65)
        /// Forget Password 灰紫(采样 #9E97AE)
        static let authForgetText         = Color(hex: 0x9E97AE)
        /// 错误提示红(复用 iOS system red)
        static let authErrorText          = Color(hex: 0xFF453A)
        /// 背景兜底色(切图加载失败时的近黑紫)
        static let authBackgroundFallback = Color(hex: 0x2A1F44)
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

        // MARK: UserProfile 详情页（H-0，对照 H5 视觉）
        /// 屏幕左右内边距（H5 px-16）
        static let userProfileScreenHPadding: CGFloat = 16
        /// 头像尺寸（H5 70x70）
        static let userProfileAvatarSize: CGFloat = 70
        /// 三色光环 stroke 宽 + gap
        static let userProfileAvatarRingWidth: CGFloat = 2
        static let userProfileAvatarRingGap: CGFloat   = 2
        /// 顶部 NavBar 操作行垂直内边距
        static let userProfileHeaderVPadding: CGFloat = 12
        /// 昵称 + gender icon 行水平间距
        static let userProfileNicknameToGenderGap: CGFloat = 6
        /// gender icon 尺寸（H5 h-14 w-22）
        static let userProfileGenderIconWidth: CGFloat  = 22
        static let userProfileGenderIconHeight: CGFloat = 14
        /// uid 行上下 margin
        static let userProfileUidTopMargin: CGFloat = 5
        static let userProfileUidBottomMargin: CGFloat = 15
        /// meta 行（country + age + connRate）icon 尺寸 + 间距
        static let userProfileMetaIconSize: CGFloat = 12
        static let userProfileMetaIconTextGap: CGFloat = 5
        static let userProfileMetaGroupGap: CGFloat = 20
        /// meta 行底部 margin
        static let userProfileMetaBottomMargin: CGFloat = 20
        /// stats 卡片间距 + 内边距 + 图标
        static let userProfileStatsCardGap: CGFloat = 8
        static let userProfileStatsCardPadding: CGFloat = 16
        static let userProfileStatsCardRadius: CGFloat = 12
        static let userProfileStatsIconSize: CGFloat = 20
        static let userProfileStatsIconToTextGap: CGFloat = 16
        /// FOLLOW/FOLLOWING 按钮（H5 me-20 / p-[7px_16px]）
        static let userProfileFollowBtnHPadding: CGFloat = 16
        static let userProfileFollowBtnVPadding: CGFloat = 7
        static let userProfileFollowBtnIconSize: CGFloat = 14
        static let userProfileFollowBtnIconGap: CGFloat = 5
        static let userProfileFollowBtnRadius: CGFloat = 20
        /// 占位区块（礼物墙 / ActionBar）
        static let userProfilePlaceholderHPadding: CGFloat = 16
        static let userProfilePlaceholderVPadding: CGFloat = 24
        static let userProfilePlaceholderRadius: CGFloat = 12
        static let userProfileSectionVTop: CGFloat = 10
        /// ActionBar 按钮高
        static let userProfileActionBarBtnHeight: CGFloat = 44
        static let userProfileActionBarBtnGap: CGFloat = 12
        static let userProfileActionBarHPadding: CGFloat = 16
        static let userProfileActionBarVPadding: CGFloat = 16
        /// 拉黑 confirm popup
        static let userProfilePopupWidth: CGFloat = 319
        static let userProfilePopupRadius: CGFloat = 16
        static let userProfilePopupBtnHeight: CGFloat = 44
        static let userProfilePopupBtnWidth: CGFloat = 128
        static let userProfilePopupBtnGap: CGFloat = 12
        static let userProfilePopupVPadding: CGFloat = 24
        static let userProfilePopupMsgHPadding: CGFloat = 24
        static let userProfilePopupMsgBottomGap: CGFloat = 20

        // MARK: LiveRoom 直播间（设计稿还原）
        /// 屏幕左右安全边距
        static let liveRoomScreenHPadding: CGFloat  = 12
        /// 顶部主播胶囊内 padding
        static let liveRoomChipHPadding: CGFloat    = 8
        static let liveRoomChipVPadding: CGFloat    = 6
        /// 顶部胶囊头像尺寸
        static let liveRoomChipAvatar: CGFloat      = 28
        /// 顶部两个 Top 观众头像尺寸
        static let liveRoomTopViewerSize: CGFloat   = 32
        /// 顶部观众数徽章尺寸
        static let liveRoomViewerCountSize: CGFloat = 32
        /// 关闭 X 按钮尺寸（2026-07-11 用户明示对齐观众图标 32pt）
        static let liveRoomCloseSize: CGFloat       = 32
        /// Task/Diamond/Rank 徽章 tile 高度
        static let liveRoomBadgeHeight: CGFloat     = 28
        /// Task/Diamond/Rank 徽章 tile 之间 gap
        static let liveRoomBadgeGap: CGFloat        = 6
        /// Underway 徽章尺寸（红胶囊）
        static let liveRoomUnderwayHeight: CGFloat  = 24
        static let liveRoomUnderwayHPadding: CGFloat = 10
        /// Wishlist 卡片 padding
        static let liveRoomWishlistPadding: CGFloat = 8
        /// Wishlist 内礼物图尺寸
        static let liveRoomWishlistGiftSize: CGFloat = 32
        /// Wishlist 进度条高度
        static let liveRoomWishlistTrackH: CGFloat  = 4
        /// 公屏消息之间 gap
        static let liveRoomChatMsgGap: CGFloat      = 4
        /// 公屏消息内 padding
        static let liveRoomChatHPadding: CGFloat    = 10
        static let liveRoomChatVPadding: CGFloat    = 6
        /// 公屏消息最大宽度占屏幕比
        static let liveRoomChatMaxWidthRatio: CGFloat = 0.7
        /// Pavate Call 按钮尺寸
        static let liveRoomPrivateCallSize: CGFloat = 56
        /// 底部工具栏 gap
        static let liveRoomToolbarGap: CGFloat      = 10
        /// 底部工具栏圆按钮尺寸
        static let liveRoomToolButtonSize: CGFloat  = 36
        /// 底部输入框高度
        static let liveRoomInputHeight: CGFloat     = 36
        /// 底部输入框 padding
        static let liveRoomInputHPadding: CGFloat   = 14
        /// 底部快捷礼物 tile 尺寸
        static let liveRoomGiftTileSize: CGFloat    = 44
        /// 底部快捷礼物 row gap
        static let liveRoomGiftTileGap: CGFloat     = 6

        // MARK: Match tab（L 里程碑设计稿还原）
        /// 跑马灯胶囊高度（对齐 H5 h-40）
        static let matchMarqueeHeight: CGFloat  = 40
        /// 跑马灯胶囊左右内边距（对齐 H5 px-12）
        static let matchMarqueeHPadding: CGFloat = 12
        /// 跑马灯胶囊左右外边距（左右预留呼吸空间）
        static let matchMarqueeHMargin: CGFloat = 20
        /// 跑马灯 caller/receiver 头像尺寸（对齐 H5 w20 h20）
        static let matchMarqueeAvatarSize: CGFloat = 20
        /// 跑马灯 call 图标宽（对齐 H5 w-33 h-10）
        static let matchMarqueeCallIconWidth: CGFloat = 33
        static let matchMarqueeCallIconHeight: CGFloat = 10
        /// 顶部 tab（Live/List/Match/Circle）行高
        static let matchTopTabBarHeight: CGFloat = 44
        /// 顶部 tab 之间水平间距
        static let matchTopTabGap: CGFloat = 20
        /// 顶部 tab 选中标志（小圆点）尺寸
        static let matchTabSelectedDot: CGFloat = 6
        /// 顶部右侧图标（信号/刷新/排行榜）尺寸
        static let matchTopIconSize: CGFloat = 24
        /// 顶部右侧图标之间间距
        static let matchTopIconGap: CGFloat = 12
        /// 主视觉图高度（对齐 H5 h-410）
        static let matchHeroHeight: CGFloat = 410
        /// 主标题（"6 Matches Found!"）字号
        static let matchTitleSize: CGFloat = 20
        /// 主标题上下间距
        static let matchTitleTopGap: CGFloat = 8
        static let matchTitleBottomGap: CGFloat = 12
        /// 底部小头像 grid：头像尺寸 + 间距
        static let matchRecentAvatarSize: CGFloat = 32
        static let matchRecentAvatarGap: CGFloat  = 8
        /// 描述文字上下间距
        static let matchSubtitleTopGap: CGFloat = 8
        /// 匹配开关按钮尺寸（对齐 H5 h-58 w-58）
        static let matchButtonSize: CGFloat = 58
        /// 匹配开关按钮距底部（避开 tab bar，用户体验预留）
        static let matchButtonBottomInset: CGFloat = 100
        /// 匹配开关按钮距右侧
        static let matchButtonTrailingInset: CGFloat = 20

        // MARK: Party 房间内（设计稿还原 2026-07-11）
        /// 屏幕左右安全边距
        static let partyRoomScreenH: CGFloat        = 12
        /// 顶部主播条：头像尺寸
        static let partyRoomAnchorAvatar: CGFloat   = 44
        /// 顶部主播条：奖杯装饰宽（覆盖头像上方）
        static let partyRoomAnchorTrophy: CGFloat   = 38
        /// 顶部关注按钮
        static let partyRoomFollowSize: CGFloat     = 30
        /// 顶部工具栏图标尺寸
        static let partyRoomToolbarIconSize: CGFloat = 22
        /// 顶部工具栏图标间距
        static let partyRoomToolbarIconGap: CGFloat = 12
        /// 顶部条上下 padding
        static let partyRoomTopBarV: CGFloat        = 8
        /// 收益/观众条上下 padding
        static let partyRoomStatRowV: CGFloat       = 6
        /// 收益条黄色数字 icon 尺寸
        static let partyRoomStatIconSize: CGFloat   = 16
        /// 收益条箭头尺寸
        static let partyRoomStatArrowSize: CGFloat  = 10
        /// 大麦位（3 列）之间水平间距（0pt 让 3 个 BigSeatCell 严格无缝相邻）
        static let partyRoomBigSeatGap: CGFloat     = 0
        /// 大麦位区高度（1/1 aspect 三格铺满宽度）
        /// 用 aspectRatio 保持不写死，避免不同屏幕拉伸
        /// 小麦位（5 列）水平间距
        static let partyRoomSmallSeatGap: CGFloat   = 8
        /// 小麦位每 cell 头像尺寸
        static let partyRoomSmallSeatAvatar: CGFloat = 46
        /// 小麦位 name+gems 与头像间距
        static let partyRoomSmallSeatVGap: CGFloat  = 4
        /// 麦位 name 胶囊
        static let partyRoomSeatNameHPadding: CGFloat = 6
        static let partyRoomSeatNameVPadding: CGFloat = 2
        /// Gems 胶囊 padding
        static let partyRoomGemsHPadding: CGFloat   = 6
        static let partyRoomGemsVPadding: CGFloat   = 2
        static let partyRoomGemsIconSize: CGFloat   = 12
        /// Tab strip 上下 padding
        static let partyRoomTabV: CGFloat           = 8
        /// Tab 项之间水平间距
        static let partyRoomTabGap: CGFloat         = 20
        /// Tab 下划线宽/高
        static let partyRoomTabUnderlineW: CGFloat  = 20
        static let partyRoomTabUnderlineH: CGFloat  = 3
        /// 聊天区 padding
        static let partyRoomChatHPadding: CGFloat   = 12
        /// 聊天消息之间垂直 gap
        static let partyRoomChatMsgGap: CGFloat     = 8
        /// 聊天头像尺寸
        static let partyRoomChatAvatar: CGFloat     = 32
        /// 聊天头像与文字 gap
        static let partyRoomChatAvatarGap: CGFloat  = 10
        /// 底部输入栏高度
        static let partyRoomInputHeight: CGFloat    = 40
        /// 底部输入栏左右 padding
        static let partyRoomInputHPadding: CGFloat  = 14
        /// 底部工具栏圆按钮尺寸
        static let partyRoomToolBtnSize: CGFloat    = 36
        /// 底部工具栏圆按钮内图标尺寸
        static let partyRoomToolBtnIconSize: CGFloat = 22
        /// 底部工具栏之间 gap
        static let partyRoomToolBtnGap: CGFloat     = 8
        /// 底部输入栏与工具栏间距
        static let partyRoomInputToolGap: CGFloat   = 6

        // MARK: Auth 登录页（设计稿还原 2026-07-13）
        /// 屏幕左右内边距
        static let authScreenHPadding: CGFloat  = 24
        /// logo 尺寸(切图正方)
        static let authLogoSize: CGFloat        = 94
        /// logo 距顶部安全区间距
        static let authLogoTopGap: CGFloat      = 110
        /// logo 与标题图之间垂直间距
        static let authLogoToTitleGap: CGFloat  = 110
        /// 标题图渲染高度(切图 233x30 @1x → 逻辑 30pt 高)
        static let authTitleHeight: CGFloat     = 30
        /// 标题图与邮箱输入框之间垂直间距
        static let authTitleToEmailGap: CGFloat = 40
        /// 输入框之间垂直间距
        static let authInputGap: CGFloat        = 16
        /// 输入框高度(pill)
        static let authInputHeight: CGFloat     = 54
        /// 输入框内左右内边距
        static let authInputHPadding: CGFloat   = 24
        /// 输入框右侧眼睛图标尺寸
        static let authEyeIconSize: CGFloat     = 20
        /// 密码框到登录按钮的垂直间距
        static let authPasswordToLoginGap: CGFloat = 60
        /// 登录按钮高度
        static let authLoginBtnHeight: CGFloat  = 54
        /// 登录按钮与 Forget Password 垂直间距
        static let authLoginToForgetGap: CGFloat = 30
        /// 错误提示行上下 padding
        static let authErrorVPadding: CGFloat   = 6
        /// 错误提示行左右 padding
        static let authErrorHPadding: CGFloat   = 8
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

        // MARK: LiveRoom 直播间（设计稿还原）
        /// 顶部主播胶囊 / 观众数徽章圆角
        static let liveRoomChip: CGFloat        = 20
        /// Task/Diamond/Rank 徽章圆角
        static let liveRoomBadge: CGFloat       = 14
        /// Underway 徽章圆角
        static let liveRoomUnderway: CGFloat    = 6
        /// Wishlist 卡片圆角
        static let liveRoomWishlist: CGFloat    = 12
        /// 公屏消息圆角
        static let liveRoomChatBubble: CGFloat  = 12
        /// 底部输入框圆角
        static let liveRoomInput: CGFloat       = 18
        /// 底部快捷礼物 tile 圆角
        static let liveRoomGiftTile: CGFloat    = 10

        // MARK: Match tab（L 里程碑设计稿还原）
        /// 跑马灯胶囊圆角（对齐 H5 rounded-12 = 12pt / 但 h-40 是半高 20 更接近视觉）
        static let matchMarquee: CGFloat = 20
        /// 匹配开关按钮不用圆角（直接切图圆形，无需 clip）

        // MARK: Party 房间内（设计稿还原 2026-07-11）
        /// 关注按钮圆
        static let partyRoomFollow: CGFloat        = 15
        /// 大麦位圆角（无圆角，方形铺满）
        static let partyRoomBigSeat: CGFloat       = 0
        /// 名字胶囊/Gems 胶囊
        static let partyRoomChip: CGFloat          = 10
        /// 底部输入栏
        static let partyRoomInput: CGFloat         = 20
        /// 底部工具栏圆按钮
        static let partyRoomToolBtn: CGFloat       = 18
        /// 礼物消息胶囊
        static let partyRoomGiftMsg: CGFloat       = 8

        // MARK: Auth 登录页（设计稿还原 2026-07-13）
        /// 输入框圆角(pill,取半高)
        static let authInput: CGFloat              = 27
        /// 登录按钮圆角(pill,取半高)
        static let authLoginBtn: CGFloat           = 27
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

        // MARK: UserProfile 详情页（H-0）
        /// 昵称（H5 没明示，按视觉 18pt semibold）
        static let userProfileNickname    = Font.system(size: 18, weight: .semibold)
        /// uid 行（H5 默认）
        static let userProfileUid         = Font.system(size: 13, weight: .regular)
        /// meta 行 country/age/connRate（H5 默认 ~14）
        static let userProfileMeta        = Font.system(size: 14, weight: .regular)
        /// stats 数字（H5 text-20 font-600）
        static let userProfileStatsValue  = Font.system(size: 20, weight: .semibold)
        /// stats label（H5 text-12 font-600）
        static let userProfileStatsLabel  = Font.system(size: 12, weight: .semibold)
        /// section 标题（H5 default）
        static let userProfileSection     = Font.system(size: 15, weight: .medium)
        /// FOLLOW/FOLLOWING 按钮文字
        static let userProfileFollowBtn   = Font.system(size: 12, weight: .semibold)
        /// 占位 coming-soon 文字
        static let userProfilePlaceholder = Font.system(size: 13, weight: .regular)
        /// 拉黑 popup 标题
        static let userProfilePopupTitle  = Font.system(size: 16, weight: .semibold)
        /// 菜单项 / ActionBar 按钮
        static let userProfileMenuItem    = Font.system(size: 15, weight: .medium)

        // MARK: LiveRoom 直播间（设计稿还原）
        /// 顶部主播胶囊内主播名
        static let liveRoomAnchorName    = Font.system(size: 13, weight: .medium)
        /// 顶部主播胶囊内热度 + 时长
        static let liveRoomAnchorMeta    = Font.system(size: 10, weight: .regular)
        /// 顶部观众数徽章数字
        static let liveRoomViewerCount   = Font.system(size: 10, weight: .bold)
        /// Task/Diamond/Rank 徽章文字
        static let liveRoomBadgeText     = Font.system(size: 12, weight: .medium)
        /// Underway 徽章文字
        static let liveRoomUnderwayText  = Font.system(size: 11, weight: .semibold)
        /// Wishlist 卡片数字
        static let liveRoomWishlistNumber = Font.system(size: 12, weight: .bold)
        /// Wishlist 卡片进度文字
        static let liveRoomWishlistProgress = Font.system(size: 10, weight: .regular)
        /// 公屏消息 - 昵称
        static let liveRoomChatNickname  = Font.system(size: 12, weight: .semibold)
        /// 公屏消息 - 正文
        static let liveRoomChatText      = Font.system(size: 12, weight: .regular)
        /// 公屏消息 - Host 徽章文字
        static let liveRoomChatHostBadge = Font.system(size: 9, weight: .bold)
        /// 公屏消息 - 等级徽章文字
        static let liveRoomChatLevel     = Font.system(size: 9, weight: .bold)
        /// Pavate Call 按钮文字
        static let liveRoomPrivateCall   = Font.system(size: 11, weight: .semibold)
        /// 底部输入框 placeholder
        static let liveRoomInputPlaceholder = Font.system(size: 13, weight: .regular)
        /// 底部快捷礼物 tile 价格
        static let liveRoomGiftPrice     = Font.system(size: 10, weight: .semibold)

        // MARK: Party 房间内（设计稿还原 2026-07-11）
        /// 主播名
        static let partyRoomAnchorName    = Font.system(size: 16, weight: .medium)
        /// ID:1234567
        static let partyRoomAnchorId      = Font.system(size: 12, weight: .regular)
        /// 收益数字（380.7K）
        static let partyRoomHeatNumber    = Font.system(size: 15, weight: .semibold)
        /// 观众数字（88）
        static let partyRoomViewerNumber  = Font.system(size: 14, weight: .medium)
        /// 大麦位名字胶囊
        static let partyRoomSeatName      = Font.system(size: 11, weight: .medium)
        /// 大麦位空位数字（"3"、"4"）
        static let partyRoomEmptyIndex    = Font.system(size: 14, weight: .medium)
        /// Gems 数字
        static let partyRoomGemsNumber    = Font.system(size: 11, weight: .semibold)
        /// 小麦位名字（用户名）
        static let partyRoomSmallSeatName = Font.system(size: 11, weight: .regular)
        /// Tab 项（All / Chat / Gift）
        static let partyRoomTab           = Font.system(size: 15, weight: .semibold)
        /// 欢迎绿字
        static let partyRoomWelcome       = Font.system(size: 13, weight: .regular)
        /// 聊天用户名
        static let partyRoomChatName      = Font.system(size: 13, weight: .semibold)
        /// 聊天正文
        static let partyRoomChatText      = Font.system(size: 13, weight: .regular)
        /// 礼物消息
        static let partyRoomGiftMsg       = Font.system(size: 12, weight: .regular)
        /// 底部输入 placeholder
        static let partyRoomInputPlaceholder = Font.system(size: 14, weight: .regular)

        // MARK: Auth 登录页（设计稿还原 2026-07-13）
        /// 输入框内文字(用户输入)
        static let authInputText     = Font.system(size: 16, weight: .regular)
        /// 输入框 placeholder(与 input 同字号)
        static let authInputPlaceh   = Font.system(size: 16, weight: .regular)
        /// 登录按钮文字 "Log in / Register"
        static let authLoginButton   = Font.system(size: 20, weight: .medium)
        /// Forget Password? 链接文字
        static let authForget        = Font.system(size: 14, weight: .regular)
        /// 错误提示文字
        static let authError         = Font.system(size: 13, weight: .regular)
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

        // MARK: Match tab（L 里程碑设计稿还原）
        /// 跑马灯胶囊背景（对齐 H5 90deg #E40132 → #6021BD）
        static let matchMarqueeBg = LinearGradient(
            colors: [Palette.matchMarqueeBgStart, Palette.matchMarqueeBgEnd],
            startPoint: .leading,
            endPoint: .trailing
        )
        /// 跑马灯胶囊描边（对齐 H5 border-style 90deg #FF0026 → #FF0088）
        static let matchMarqueeBorder = LinearGradient(
            colors: [Palette.matchMarqueeBorderStart, Palette.matchMarqueeBorderEnd],
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
