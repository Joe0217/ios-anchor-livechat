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

    // MARK: - Live 页（设计稿还原）
    /// 顶部子 tab 名称
    static var liveSubTabLive: String { localize("live.subTab.live", comment: "Live") }
    static var liveSubTabList: String { localize("live.subTab.list", comment: "List") }
    static var liveSubTabMatch: String { localize("live.subTab.match", comment: "Match") }
    static var liveSubTabCysle: String { localize("live.subTab.cysle", comment: "Cysle") }
    /// 占位子 tab 提示
    static var liveSubTabComingSoon: String { localize("live.subTab.comingSoon", comment: "占位文案：敬请期待") }
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
    static var liveErrorNoCover: String { localize("live.error.noCover", comment: "开播失败：账号还没有直播封面") }

    // 公屏系统消息（用户在直播间内可见）
    static var imSystemLoginFailedFormat: String { localize("im.system.loginFailedFormat", comment: "公屏系统消息：IM 登录失败 code=%@") }
    static var imSystemJoinFailedFormat: String { localize("im.system.joinFailedFormat", comment: "公屏系统消息：加入聊天室失败 code=%@") }
    static var imSystemJoined: String { localize("im.system.joined", comment: "公屏系统消息：已进入聊天室") }
    static var imSystemGiftPlaceholder: String { localize("im.system.giftPlaceholder", comment: "公屏系统消息：礼物消息占位") }
}
