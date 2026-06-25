import Foundation

/// 本地化查表入口。
///
/// - Release：走标准 `NSLocalizedString`，按 Bundle.main.preferredLocalizations 解析（系统语言）
/// - DEBUG：若 `DebugLocaleStore.shared.current != .system`，从对应 `.lproj` sub-bundle 直接查表
///   —— 这样运行时切换语言无需重启 app，文案立即更新（配合 DebugLocaleEnvironment 的 .id() 触发子树重建）。
///
/// 所有 L10n 字段是 computed property（每次访问重新查表），切语言后 View 重绘时自动取到新文案。
fileprivate func localize(_ key: String, comment: String = "") -> String {
    #if DEBUG
    if let sub = DebugLocaleStore.shared.subBundle {
        let value = sub.localizedString(forKey: key, value: "__MISSING__", table: nil)
        if value != "__MISSING__" { return value }
    }
    #endif
    return NSLocalizedString(key, comment: comment)
}

/// i18n 本地化 key 中转（B 里程碑 spec §13 i18n 声明）。
///
/// 三语言目录就绪：en/ar/tr 均有 Localizable.strings 完整翻译。
/// 引入 SwiftGen 后本文件可自动生成；B 阶段手工维护。
enum L10n {
    // 强制下播原因（UI 文案）
    static var forceEndDisconnected: String { localize("forceEnd.disconnected", comment: "网络异常已断连") }
    static var forceEndBanned: String { localize("forceEnd.banned", comment: "账号违规已封禁") }
    static var forceEndCameraFailure: String { localize("forceEnd.cameraFailure", comment: "相机采集失败") }
    static var forceEndNoPermission: String { localize("forceEnd.noPermission", comment: "权限校验失败") }
    static var forceEndWeakNetwork: String { localize("forceEnd.weakNetwork", comment: "网络环境过差") }

    // 美颜降级提示
    static var beautyUnavailableHint: String { localize("beauty.unavailable", comment: "美颜不可用") }

    // 网络弱网降级提示（v5 分层）
    static var networkWarning: String { localize("network.warning", comment: "网络较差，已切换低帧率") }

    // 开播前置校验
    static var prepareTitleEmpty: String { localize("prepare.titleEmpty", comment: "请输入直播标题") }
    static var prepareCoverEmpty: String { localize("prepare.coverEmpty", comment: "请设置直播封面") }
    static var prepareCooldown: String { localize("prepare.cooldown", comment: "距上次下播不足 60 秒") }
    static var prepareIMOffline: String { localize("prepare.imOffline", comment: "聊天服务未连接，请稍后重试") }

    // 公屏
    static var imChatroomReconnecting: String { localize("im.chatroom.reconnecting", comment: "聊天室重连中...") }
    static var imChatroomReconnected: String { localize("im.chatroom.reconnected", comment: "聊天室已重连") }
    static var userJoined: String { localize("im.userJoined", comment: "有用户进入了直播间") }
    static var sendGiftAction: String { localize("im.sendGiftAction", comment: "送出") }
    static var complianceWarningDefault: String { localize("im.complianceWarningDefault", comment: "您的直播内容已被警告") }
    static var anonymous: String { localize("im.anonymous", comment: "匿名") }

    // MARK: - G 直播 PK 玩法（26 条；spec §9 全表）
    enum PK {
        static var entryTitle: String { localize("pk.entry.title", comment: "发起 PK") }
        static var entryRandom: String { localize("pk.entry.random", comment: "随机匹配") }
        static var entryInvite: String { localize("pk.entry.invite", comment: "邀请对方") }

        static var matchingTitle: String { localize("pk.matching.title", comment: "匹配中") }
        static var matchingSubtitle: String { localize("pk.matching.subtitle", comment: "搜索中等待") }
        static var matchingCancel: String { localize("pk.matching.cancel", comment: "取消") }
        static var matchingCancelled: String { localize("pk.matching.cancelled", comment: "匹配已取消") }

        static var inviteTitle: String { localize("pk.invite.title", comment: "邀请 PK") }
        static var invitePlaceholder: String { localize("pk.invite.placeholder", comment: "对手 UID") }
        static var inviteDurationLabel: String { localize("pk.invite.durationLabel", comment: "PK 时长") }
        static var inviteSend: String { localize("pk.invite.send", comment: "发送邀请") }
        static var inviteWaiting: String { localize("pk.invite.waiting", comment: "等待对方接受") }
        static var inviteCancel: String { localize("pk.invite.cancel", comment: "取消邀请") }
        static var inviteDuration3: String { localize("pk.invite.duration3", comment: "3 分钟") }
        static var inviteDuration5: String { localize("pk.invite.duration5", comment: "5 分钟") }
        static var inviteDuration10: String { localize("pk.invite.duration10", comment: "10 分钟") }
        static var inviteDuration15: String { localize("pk.invite.duration15", comment: "15 分钟") }

        static var invitedTitle: String { localize("pk.invited.title", comment: "收到邀请") }
        static var invitedAccept: String { localize("pk.invited.accept", comment: "接受") }
        static var invitedReject: String { localize("pk.invited.reject", comment: "拒绝") }

        static var arenaEndPK: String { localize("pk.arena.endPK", comment: "结束 PK") }
        static var punishingTitle: String { localize("pk.punishing.title", comment: "惩罚阶段") }
        static var punishingEnd: String { localize("pk.punishing.endPunish", comment: "结束惩罚") }
        static var resultTitle: String { localize("pk.result.title", comment: "PK 结束") }
        static var resultConfirm: String { localize("pk.result.confirm", comment: "确认") }

        static var toastInviteRejectedFormat: String { localize("pk.toast.inviteRejectedFormat", comment: "%@ 拒绝了你的 PK 邀请") }
        static var toastInviteAcceptedFormat: String { localize("pk.toast.inviteAcceptedFormat", comment: "%@ 接受了你的 PK 邀请") }
        static var toastInviteTimeout: String { localize("pk.toast.inviteTimeout", comment: "PK 邀请超时") }

        // MARK: - 推荐列表 + 搜索 + 5 态按钮（2026-06-25 §1.2 反悔扩展）
        static var inviteSearchPlaceholder: String { localize("pk.invite.searchPlaceholder", comment: "UID 或昵称") }
        static var inviteRecommendTitle: String { localize("pk.invite.recommendTitle", comment: "推荐") }
        static var inviteSearchResultTitle: String { localize("pk.invite.searchResultTitle", comment: "搜索结果") }
        static var inviteEmpty: String { localize("pk.invite.empty", comment: "暂无数据") }
        static var inviteAcceptSwitch: String { localize("pk.invite.acceptSwitch", comment: "接受 PK 邀请") }
        static var inviteBtnInvite: String { localize("pk.invite.btn.invite", comment: "邀请") }
        static var inviteBtnWaiting: String { localize("pk.invite.btn.waiting", comment: "等待中") }
        static var inviteBtnPKing: String { localize("pk.invite.btn.pking", comment: "PK 中") }
        static var inviteToastBusy: String { localize("pk.invite.toast.busy", comment: "对方繁忙，请稍后再试") }
        static var inviteToastBeingInvited: String { localize("pk.invite.toast.beingInvited", comment: "对方正在处理其他邀请") }
        static var inviteToastSelf: String { localize("pk.invite.toast.self", comment: "不能邀请自己") }
        static var inviteToastLimit: String { localize("pk.invite.toast.limit", comment: "邀请已达上限") }
        static var inviteToastMatching: String { localize("pk.invite.toast.matching", comment: "随机匹配中，请先取消") }
        static var inviteToastInviteSent: String { localize("pk.invite.toast.sent", comment: "PK 邀请已发送") }
    }

    // MARK: - Work 工作台（设计稿还原）
    static var workWeeklyLevel: String { localize("work.weeklyLevel", comment: "周等级") }
    static var workDetail: String { localize("work.detail", comment: "详情") }
    static var workScorePrefix: String { localize("work.scorePrefix", comment: "分数前缀") }
    static var workNeedMoreFormat: String { localize("work.needMoreFormat", comment: "升级还需 %d 分") }

    static var workCallsToday: String { localize("work.callsToday", comment: "今日通话数") }
    static var workPositiveRating: String { localize("work.positiveRating", comment: "好评率") }
    static var workWeeklyRevenue: String { localize("work.weeklyRevenue", comment: "周收益") }

    static var workTodaysIncome: String { localize("work.todaysIncome", comment: "今日收益") }
    static var workWithdrawal: String { localize("work.withdrawal", comment: "提现") }
    static var workCallIncomes: String { localize("work.callIncomes", comment: "通话收益") }
    static var workGiftIncomes: String { localize("work.giftIncomes", comment: "礼物收益") }
    static var workTaskIncomes: String { localize("work.taskIncomes", comment: "任务收益") }
    static var workInviteIncomes: String { localize("work.inviteIncomes", comment: "邀请收益") }
    static var workManagedIncomes: String { localize("work.managedIncomes", comment: "管理收益") }
    static var workTotalIncomes: String { localize("work.totalIncomes", comment: "总收益") }

    static var workTools: String { localize("work.tools", comment: "工具") }
    static var workOnline: String { localize("work.online", comment: "在线") }
    static var workOnlineOn: String { localize("work.online.on", comment: "在线开关-开") }
    static var workOnlineOff: String { localize("work.online.off", comment: "在线开关-关") }
    static var workOffline: String { localize("work.offline", comment: "离线（开关关态文字）") }

    // 工具图标标签
    static var toolHi: String { localize("work.tool.hi", comment: "打招呼") }
    static var toolGoLive: String { localize("work.tool.goLive", comment: "开播") }
    static var toolMatch: String { localize("work.tool.match", comment: "匹配") }
    static var toolTask: String { localize("work.tool.task", comment: "任务") }
    static var toolBeauty: String { localize("work.tool.beauty", comment: "美颜") }
    static var toolPoints: String { localize("work.tool.points", comment: "积分") }
    static var toolGiftMessage: String { localize("work.tool.giftMessage", comment: "礼物消息") }
    static var toolProfileUpdate: String { localize("work.tool.profileUpdate", comment: "资料更新") }
    static var toolInvite: String { localize("work.tool.invite", comment: "邀请") }
    static var toolWorkingGuide: String { localize("work.tool.workingGuide", comment: "工作指南") }
    static var toolBackpack: String { localize("work.tool.backpack", comment: "背包") }

    // 底部 tab 标签
    static var tabHome: String { localize("tab.home", comment: "首页") }
    static var tabMessages: String { localize("tab.messages", comment: "消息") }
    static var tabWork: String { localize("tab.work", comment: "工作台") }
    static var tabProfile: String { localize("tab.profile", comment: "我的") }

    // MARK: - Home 顶部 4 tab（trial #1 重命名自 live.subTab，case cysle typo → cycle）
    static var homeTopTabLive: String  { localize("home.topTab.live",  comment: "Live") }
    static var homeTopTabList: String  { localize("home.topTab.list",  comment: "List") }
    static var homeTopTabMatch: String { localize("home.topTab.match", comment: "Match") }
    static var homeTopTabCycle: String { localize("home.topTab.cycle", comment: "Cycle") }
    /// 占位子 tab 提示（Match / Cycle Official 等未实现 tab 共用）
    static var homeTopTabComingSoon: String { localize("home.topTab.comingSoon", comment: "占位文案：敬请期待") }

    // MARK: - Cycle 朋友圈内 3 子 tab（trial #1 A-spec §6B.8）
    static var cycleSubTabOfficial: String { localize("home.cycle.official.label", comment: "Cycle 子 tab Official") }
    static var cycleSubTabMoment: String   { localize("home.cycle.moment.label",   comment: "Cycle 子 tab Moment（全站圈）") }
    static var cycleSubTabMe: String       { localize("home.cycle.me.label",       comment: "Cycle 子 tab Me（我的）") }
    /// Moment 加载失败提示
    static var cycleMomentLoadError: String { localize("home.cycle.moment.error.title", comment: "Moment 加载失败提示") }
    /// 观看人数后缀（a11y）
    static var liveViewers: String { localize("live.viewers", comment: "观看人数 a11y 后缀") }
    /// 顶部右侧按钮 a11y
    static var liveRankBadge: String { localize("live.rankBadge", comment: "排行榜按钮 a11y") }
    static var liveRefresh: String { localize("live.refresh", comment: "刷新按钮 a11y") }
    static var liveOnlineDot: String { localize("live.onlineDot", comment: "在线状态 a11y") }

    // MARK: - List 子页（设计稿还原）
    /// 顶部 Online/Prime 分段
    static var liveListSegmentOnline: String { localize("liveList.segment.online", comment: "Online 分段") }
    static var liveListSegmentPrime: String { localize("liveList.segment.prime", comment: "Prime 分段") }
    /// Invite friends banner
    static var liveListInviteTitle: String { localize("liveList.invite.title", comment: "邀请好友标题") }
    static var liveListInviteSubtitle: String { localize("liveList.invite.subtitle", comment: "邀请好友副标题") }
    /// 卡片右侧动作按钮 a11y
    static var liveListActionChat: String { localize("liveList.action.chat", comment: "聊天按钮 a11y") }
    static var liveListActionLive: String { localize("liveList.action.live", comment: "直播按钮 a11y") }
    static var liveListActionMatch: String { localize("liveList.action.match", comment: "匹配按钮 a11y") }
    static var liveListActionOffline: String { localize("liveList.action.offline", comment: "下线开关 a11y") }

    // MARK: - Profile 个人页（设计稿还原）
    /// 顶部按钮 a11y
    static var profileSettings: String { localize("profile.settings", comment: "设置按钮 a11y") }
    static var profileEditName: String { localize("profile.editName", comment: "编辑昵称按钮 a11y") }
    /// ID 前缀
    static var profileIdPrefix: String { localize("profile.idPrefix", comment: "ID 前缀") }
    /// stats caption
    static var profileFollowing: String { localize("profile.following", comment: "关注数 caption") }
    static var profileFollowers: String { localize("profile.followers", comment: "粉丝数 caption") }
    static var profileFriends: String { localize("profile.friends", comment: "朋友数 caption") }
    /// 内容 tab
    static var profileTabAlbum: String { localize("profile.tab.album", comment: "Album tab") }
    static var profileTabGifts: String { localize("profile.tab.gifts", comment: "Gifts tab") }
    static var profileTabMoment: String { localize("profile.tab.moment", comment: "Moment tab") }
    /// section 标题格式
    static var profilePhotosFormat: String { localize("profile.photos.format", comment: "Photos (%d/%d)") }
    static var profileVideosFormat: String { localize("profile.videos.format", comment: "Videos (%d/%d)") }
    /// 网格 cell a11y
    static var profilePhotoCellA11y: String { localize("profile.cell.photo", comment: "相册 cell a11y") }
    static var profileVideoCellA11y: String { localize("profile.cell.video", comment: "视频 cell a11y") }
    /// 空 tab 占位文案
    static var profileEmptyPlaceholder: String { localize("profile.emptyPlaceholder", comment: "tab 暂无内容占位") }
    /// 数据加载错误 banner 格式 + 重试按钮
    static var profileLoadFailedFormat: String { localize("profile.loadFailed.format", comment: "加载失败 banner 文案，%@ 为底层错误描述") }
    static var profileLoading: String { localize("profile.loading", comment: "加载中 banner") }
    static var profileRetry: String { localize("profile.retry", comment: "重试按钮") }
    /// 单价格式（%d 是每分钟的数字）
    static var profileRatePerMinFormat: String { localize("profile.ratePerMin.format", comment: "单价格式，%d/min") }

    // MARK: - FollowList 关注/粉丝/朋友列表
    static var followActionFollow: String   { localize("followList.action.follow", comment: "关注按钮") }
    static var followActionFollowing: String { localize("followList.action.following", comment: "已关注按钮") }
    static var followActionUnfollow: String { localize("followList.action.unfollow", comment: "取关按钮") }
    static var followActionBlock: String    { localize("followList.action.block", comment: "拉黑按钮") }
    static var followListEnd: String        { localize("followList.end", comment: "列表已到底") }
    static var followListEmpty: String      { localize("followList.empty", comment: "列表无数据") }

    /// 相册/视频审核态徽章
    static var profileMediaReviewing: String { localize("profile.media.reviewing", comment: "审核中徽章") }
    static var profileMediaRejected: String  { localize("profile.media.rejected", comment: "已拒徽章") }

    /// 媒体预览关闭按钮 a11y
    static var mediaPreviewClose: String { localize("mediaPreview.close", comment: "媒体预览关闭按钮") }

    // MARK: - Settings 设置页
    static var settingsTitle: String           { localize("settings.title", comment: "设置页标题") }
    static var settingsSectionAccount: String  { localize("settings.section.account", comment: "账号区块") }
    static var settingsSectionGeneral: String  { localize("settings.section.general", comment: "通用区块") }
    static var settingsSectionAbout: String    { localize("settings.section.about", comment: "关于区块") }
    static var settingsBlocklist: String       { localize("settings.blocklist", comment: "黑名单条目") }
    static var settingsLanguage: String        { localize("settings.language", comment: "语言条目") }
    static var settingsFeedback: String        { localize("settings.feedback", comment: "反馈条目") }
    static var settingsVersion: String         { localize("settings.version", comment: "版本号 label") }
    static var settingsTermsOfService: String  { localize("settings.tos", comment: "用户协议") }
    static var settingsPrivacyPolicy: String   { localize("settings.privacy", comment: "隐私政策") }
    static var settingsLogout: String          { localize("settings.logout", comment: "退出登录按钮") }
    static var settingsLogoutConfirm: String   { localize("settings.logoutConfirm", comment: "退出登录确认") }
    static var settingsCancel: String          { localize("settings.cancel", comment: "取消") }

    // MARK: - Blocklist 黑名单列表（I-1，spec §10.3）
    static var blocklistTitle: String              { localize("blocklist.title", comment: "黑名单列表页标题") }
    static var blocklistEmptyDescription: String   { localize("blocklist.empty.description", comment: "黑名单空态文案") }
    static var blocklistRemoveConfirmTitle: String { localize("blocklist.removeConfirm.title", comment: "移除黑名单二次确认标题") }
    static var blocklistRemoveConfirmMessage: String { localize("blocklist.removeConfirm.message", comment: "移除黑名单二次确认正文") }
    static var blocklistRemoveConfirmAction: String { localize("blocklist.removeConfirm.action", comment: "移除按钮") }
    static var blocklistRemoveConfirmCancel: String { localize("blocklist.removeConfirm.cancel", comment: "取消按钮") }
    static var blocklistRemoveNetworkError: String { localize("blocklist.removeNetworkError", comment: "网络错误兜底") }
    static var blocklistRemoveBadUserId: String    { localize("blocklist.removeBadUserId", comment: "userId 非法") }
    static var blocklistLoadErrorRetry: String     { localize("blocklist.loadError.retry", comment: "加载失败 retry 文案") }
    static var blocklistLoadEnd: String            { localize("blocklist.loadEnd", comment: "列表加载到底") }
    static var blocklistAccessibilityRemoveButton: String { localize("blocklist.accessibility.removeButton", comment: "删除按钮无障碍 label") }
    /// %@ = nickname / %@ = 日期；使用 String(format:) 拼接
    static func blocklistAccessibilityRow(nickname: String, date: String) -> String {
        String(format: localize("blocklist.accessibility.row", comment: "行无障碍 label，参数: nickname, date"), nickname, date)
    }
    /// 行无障碍 label 当无拉黑日期时使用（review #11，避免朗读「blocked on —」古怪语义）
    static func blocklistAccessibilityRowNoDate(nickname: String) -> String {
        String(format: localize("blocklist.accessibility.rowNoDate", comment: "行无障碍 label 无日期分支，参数: nickname"), nickname)
    }
    /// footer 错误条目 retry 文案 format（review #15，避免硬编码中点 ·）
    /// 参数：%@ = 错误 message / %@ = "tap to retry"
    static func blocklistLoadErrorRetryFormat(message: String) -> String {
        String(format: localize("blocklist.loadError.retryFormat", comment: "加载失败 retry 拼接 format，参数: message"), message, blocklistLoadErrorRetry)
    }

    // MARK: - LevelDetail 段位详情页
    static var levelDetailTitle: String    { localize("level.title", comment: "段位详情标题") }
    static var levelDetailCurrent: String  { localize("level.current", comment: "当前段位 caption") }
    static var levelDetailSpectrum: String { localize("level.spectrum", comment: "段位光谱条 caption") }

    /// 礼物墙空态
    static var profileGiftsEmpty: String { localize("profile.gifts.empty", comment: "礼物墙空态文案") }

    // MARK: - Moment 动态卡片（Profile / Cycle 共用 MomentPostRow）
    /// 相对时间：刚刚发布（< 60 秒）
    static var momentRelativeJustNow: String       { localize("moment.relative.justNow", comment: "动态时间：刚刚") }
    /// 相对时间：分钟级，%d 代表数字
    static var momentRelativeMinutesFormat: String { localize("moment.relative.minutes.format", comment: "动态时间：%d 分钟前") }
    /// 相对时间：小时级
    static var momentRelativeHoursFormat: String   { localize("moment.relative.hours.format", comment: "动态时间：%d 小时前") }
    /// 相对时间：天级（< 7 天）
    static var momentRelativeDaysFormat: String    { localize("moment.relative.days.format", comment: "动态时间：%d 天前") }
    /// 点赞按钮 a11y（未点赞）
    static var momentActionLike: String            { localize("moment.action.like", comment: "动态点赞 a11y") }
    /// 取消点赞按钮 a11y（已点赞）
    static var momentActionUnlike: String          { localize("moment.action.unlike", comment: "动态取消点赞 a11y") }

    // MARK: - Auth 登录页
    static var authTitle: String { localize("auth.title", comment: "登录页大标题：主播登录") }
    static var authEnvHint: String { localize("auth.envHint", comment: "登录页环境提示（dev 域名）") }
    static var authEmail: String { localize("auth.email", comment: "邮箱输入框 placeholder") }
    static var authPassword: String { localize("auth.password", comment: "密码输入框 placeholder") }
    static var authLogin: String { localize("auth.login", comment: "登录按钮") }
    static var authLoggingIn: String { localize("auth.loggingIn", comment: "登录中 loading 文案") }

    // MARK: - LivePrepare 开播准备
    static var livePrepareNavTitle: String { localize("livePrepare.navTitle", comment: "开播 Demo 导航标题") }
    static var livePreparePanelTitle: String { localize("livePrepare.panelTitle", comment: "开播准备面板标题") }
    static var livePrepareTitlePlaceholder: String { localize("livePrepare.titlePlaceholder", comment: "直播标题输入框 placeholder") }
    static var livePrepareDefaultTitle: String { localize("livePrepare.defaultTitle", comment: "标题留空时默认显示文案") }
    static var livePrepareBeautyToggle: String { localize("livePrepare.beautyToggle", comment: "美颜开关") }
    static var livePrepareSliderBlur: String { localize("livePrepare.sliderBlur", comment: "磨皮 slider 标签") }
    static var livePrepareSliderWhiten: String { localize("livePrepare.sliderWhiten", comment: "美白 slider 标签") }
    static var livePrepareSliderEyeEnlarge: String { localize("livePrepare.sliderEyeEnlarge", comment: "大眼 slider 标签") }
    static var livePrepareSliderFaceThin: String { localize("livePrepare.sliderFaceThin", comment: "瘦脸 slider 标签") }
    static var livePrepareStart: String { localize("livePrepare.start", comment: "开始直播按钮") }
    static var livePrepareStarting: String { localize("livePrepare.starting", comment: "开播中 loading 文案") }
    static var livePrepareErrorNoChannel: String { localize("livePrepare.errorNoChannel", comment: "开播失败：响应里无频道/token") }
    static var livePrepareErrorPrefix: String { localize("livePrepare.errorPrefix", comment: "开播失败：%@ (%@)") }
    static var livePrepareErrorGeneric: String { localize("livePrepare.errorGeneric", comment: "开播失败：%@") }
    static var livePrepareGuardUnverified: String { localize("livePrepare.guardUnverified", comment: "userType 守卫：账号未审核为主播") }
    static var livePrepareGuardAgent: String { localize("livePrepare.guardAgent", comment: "userType 守卫：代理账号不支持开播") }

    // MARK: - LiveRoom 直播间
    static var liveRoomPermissionAlertTitle: String { localize("liveRoom.permissionAlertTitle", comment: "相机权限弹窗标题") }
    static var liveRoomPermissionAlertOK: String { localize("liveRoom.permissionAlertOK", comment: "相机权限弹窗确定按钮") }
    static var liveRoomPermissionAlertMessage: String { localize("liveRoom.permissionAlertMessage", comment: "相机权限弹窗内容") }
    static var liveRoomStatusLiveFormat: String { localize("liveRoom.statusLiveFormat", comment: "直播中状态（%@ 为时长）") }
    static var liveRoomStatusConnecting: String { localize("liveRoom.statusConnecting", comment: "连接中状态") }
    static var liveRoomAnchorDefault: String { localize("liveRoom.anchorDefault", comment: "主播默认昵称") }
    static var liveRoomToolBeauty: String { localize("liveRoom.toolBeauty", comment: "底部美颜按钮") }
    static var liveRoomEndLive: String { localize("liveRoom.endLive", comment: "结束直播按钮") }
    static var liveRoomBeautyPanelTitle: String { localize("liveRoom.beautyPanelTitle", comment: "美颜面板标题") }

    // MARK: - Call POC（调试态保留，上线前删除）
    static var callStatusWaitingRemote: String { localize("call.statusWaitingRemote", comment: "通话 POC：等待对端") }
    static var callPermissionTitle: String { localize("call.permissionTitle", comment: "通话 POC：需要摄像头权限") }
    static var callPermissionMessage: String { localize("call.permissionMessage", comment: "通话 POC：去设置开启相机") }
    static var callChannelLabel: String { localize("call.channelLabel", comment: "通话 POC：频道标签") }
    static var callChannelPlaceholder: String { localize("call.channelPlaceholder", comment: "通话 POC：频道名输入提示") }
    static var callHangup: String { localize("call.hangup", comment: "通话 POC：挂断按钮") }
    static var callConnecting: String { localize("call.connecting", comment: "通话 POC：接通中") }
    static var callJoin: String { localize("call.join", comment: "通话 POC：加入通话") }
    static var callBeautyBannerPassthrough: String { localize("call.beautyBannerPassthrough", comment: "通话 POC：直通预览 banner") }
    static var callBeautyBannerActive: String { localize("call.beautyBannerActive", comment: "通话 POC：相芯美颜激活 banner") }
    static var callErrorEmptyChannel: String { localize("call.errorEmptyChannel", comment: "通话 POC：频道名为空") }
    static var callErrorTokenFailed: String { localize("call.errorTokenFailed", comment: "通话 POC：获取 token 失败") }
    static var callErrorConnectPrefix: String { localize("call.errorConnectPrefix", comment: "通话 POC：接通失败：%@ (%@)") }
    static var callErrorConnectGeneric: String { localize("call.errorConnectGeneric", comment: "通话 POC：接通失败：%@") }

    // MARK: - Call 1v1 真实通话视图（CallView.swift）
    static var callSubtitleCallingOut: String { localize("call.subtitle.callingOut", comment: "1v1：主叫副标题") }
    static var callSubtitleIncoming: String { localize("call.subtitle.incoming", comment: "1v1：被叫副标题") }
    static var callActionCancel: String { localize("call.action.cancel", comment: "1v1：取消按钮（主叫端）") }
    static var callActionReject: String { localize("call.action.reject", comment: "1v1：拒接按钮") }
    static var callActionAccept: String { localize("call.action.accept", comment: "1v1：接听按钮") }
    static var callActionHangupBackToLive: String { localize("call.action.hangupBackToLive", comment: "1v1：挂断回直播（直播私 call）") }
    static var callActionHangup: String { localize("call.action.hangup", comment: "1v1：挂断按钮") }
    static var callLiveBanner: String { localize("call.liveBanner", comment: "1v1：直播私 call 顶部 banner") }

    // MARK: - LiveRoom 挂断后回直播倒计时覆盖层
    static var liveRoomCallEndedTitle: String { localize("liveRoom.callEndedTitle", comment: "挂断回直播：通话已结束") }
    static var liveRoomReturnCountdownFormat: String { localize("liveRoom.returnCountdownFormat", comment: "挂断回直播：%d 秒后回直播间") }

    // MARK: - 服务层错误（被 View 显示）
    static var authErrorNoToken: String { localize("auth.error.noToken", comment: "登录失败：服务未返回 token") }
    static var authErrorNetworkFormat: String { localize("auth.error.networkFormat", comment: "登录失败：网络错误（%@ 为系统错误描述）") }
    static var authErrorSessionInvalidated: String { localize("auth.error.sessionInvalidated", comment: "1004 挤下线 / 1005 token 失效统一文案") }
    static var liveErrorNoCover: String { localize("live.error.noCover", comment: "开播失败：账号还没有直播封面") }

    // 公屏系统消息（用户在直播间内可见）
    static var imSystemLoginFailedFormat: String { localize("im.system.loginFailedFormat", comment: "公屏系统消息：IM 登录失败 code=%@") }
    static var imSystemJoinFailedFormat: String { localize("im.system.joinFailedFormat", comment: "公屏系统消息：加入聊天室失败 code=%@") }
    static var imSystemJoined: String { localize("im.system.joined", comment: "公屏系统消息：已进入聊天室") }
    static var imSystemGiftPlaceholder: String { localize("im.system.giftPlaceholder", comment: "公屏系统消息：礼物消息占位") }

    // MARK: - H IM 完善 错误文案（NIMServiceError.errorDescription，与 APIError 对齐）
    static var imErrorLoginFailedFormat: String { localize("im.error.loginFailedFormat", comment: "IM 登录失败：code=%@ %@") }
    static var imErrorTokenInvalid: String { localize("im.error.tokenInvalid", comment: "1005 token 过期：会话已过期") }
    static var imErrorKickedOut: String { localize("im.error.kickedOut", comment: "1004 挤下线：账号已在其他设备登录") }
    static var imErrorChatroomEnterFailedFormat: String { localize("im.error.chatroomEnterFailedFormat", comment: "进入聊天室失败 (%@)") }
    static var imErrorNetworkErrorFormat: String { localize("im.error.networkErrorFormat", comment: "IM 网络错误 (%@)") }
    static var imErrorDecodingFormat: String { localize("im.error.decodingFormat", comment: "消息解析失败：%@") }
}
