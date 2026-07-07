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

    // 切后台超限（BackgroundMonitor 预警 + 本地通知，B 里程碑增补 spec §3）
    /// %d 已切次数 / %d 上限次数
    static var liveBackgroundCountWarningFormat: String {
        localize("live.background.count_warning", comment: "切后台次数预警 toast：已切 %d/%d 次，再切一次将下播")
    }
    /// %d 已累计分钟
    static var liveBackgroundCumulativeWarningFormat: String {
        localize("live.background.cumulative_warning", comment: "累计后台时长预警 toast：已累计 %d 分钟")
    }
    static var liveBackgroundNotifTitle: String {
        localize("live.background.notif.title", comment: "本地通知标题：回到 App 继续直播")
    }
    static var liveBackgroundNotifBody: String {
        localize("live.background.notif.body", comment: "本地通知正文：20 秒内不回则自动下播")
    }

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

        // MARK: - H5 pkLive/* popup 对齐（2026-07-06 iteration 3：PK 全套 UI 同步）
        /// 中断 PK 弹窗标题（H5 pk.Give up the PK）
        static var giveUpTitle: String { localize("pk.giveUp.title", comment: "中断 PK 弹窗标题") }
        /// 中断 PK 提示（H5 pk.confirm to interrupt this PK）
        static var giveUpConfirm: String { localize("pk.giveUp.confirm", comment: "中断 PK 提示") }
        /// 中断 PK 按钮（H5 pk.Give Up）
        static var giveUpAction: String { localize("pk.giveUp.action", comment: "中断 PK 按钮 Give Up") }
        /// 继续 PK 按钮（H5 pk.Continue PK）
        static var continuePK: String { localize("pk.continuePK", comment: "继续 PK 按钮") }

        /// 断开连线弹窗标题（H5 pk.PK Ended）
        static var pkEndedTitle: String { localize("pk.pkEnded.title", comment: "断开连线弹窗标题") }
        /// 断开连线按钮（H5 pk.Disconnect Live）
        static var disconnectAction: String { localize("pk.disconnect.action", comment: "断开连线按钮") }

        /// 匹配失败标题（H5 match.No match found temporarily）
        static var matchFailedTitle: String { localize("pk.matchFailed.title", comment: "匹配失败标题") }
        /// 匹配失败提示 1（H5 pk.Oops, no equal-strength streamer available now）
        static var matchFailedHint1: String { localize("pk.matchFailed.hint1", comment: "匹配失败提示 1") }
        /// 匹配失败提示 2（H5 pk.Matching off.Go pick a specific streamer for PK）
        static var matchFailedHint2: String { localize("pk.matchFailed.hint2", comment: "匹配失败提示 2") }
        /// 匹配失败发起 PK 按钮（H5 pk.Initiate PK）
        static var matchFailedInitiate: String { localize("pk.matchFailed.initiate", comment: "匹配失败发起 PK") }

        /// 邀请等待弹窗标题（H5 pk.Inviting to PK）
        static var invitingTitle: String { localize("pk.inviting.title", comment: "邀请等待弹窗标题") }
        /// 邀请等待副标题（H5 pk.Waiting PK acceptance）
        static var waitingAcceptance: String { localize("pk.waitingAcceptance", comment: "等待对方接受") }
        /// 邀请等待取消按钮（H5 pk.Cancel PK Invitation）
        static var cancelInvitation: String { localize("pk.cancelInvitation", comment: "取消邀请") }

        /// Battle 惩罚倒计时前缀（H5 Punish 字面量）
        static var punishLabel: String { localize("pk.punish.label", comment: "惩罚倒计时前缀 Punish") }
        /// Battle 结果 - Win（H5 pk-result-win 动画对应）
        static var resultWin: String { localize("pk.result.win", comment: "PK 结果 - 获胜") }
        /// Battle 结果 - Lose
        static var resultLose: String { localize("pk.result.lose", comment: "PK 结果 - 失败") }
        /// Battle 结果 - Draw
        static var resultDraw: String { localize("pk.result.draw", comment: "PK 结果 - 平局") }

        /// PK 记录弹窗标题
        static var historyTitle: String { localize("pk.history.title", comment: "PK 记录标题") }
        /// PK 规则弹窗标题
        static var ruleTitle: String { localize("pk.rule.title", comment: "PK 规则标题") }
        /// PK 排行榜标题
        static var rankTitle: String { localize("pk.rank.title", comment: "PK 排行榜标题") }
        /// 通用「敬请期待」占位（用于 History/Rule/Rank 视觉占位）
        static var comingSoon: String { localize("pk.comingSoon", comment: "PK 敬请期待占位") }

        /// 邀请 60s 倒计时后缀（H5 `{{ countdown }}s`）
        static var countdownSecondsFormat: String { localize("pk.countdownFormat", comment: "%ds 倒计时后缀") }

        /// 对手静音按钮 a11y（PKArenaView 右上角音量按钮）
        static var opponentMute: String { localize("pk.opponent.mute", comment: "静音对手 a11y") }
        static var opponentUnmute: String { localize("pk.opponent.unmute", comment: "取消静音对手 a11y") }
    }

    // MARK: - E/F 派对房（spec §1.4 + H i18n 收尾）
    enum Party {
        // 通用
        static var defaultRoomName: String { localize("party.defaultRoomName", comment: "派对房默认房名") }
        static var defaultUser: String { localize("party.defaultUser", comment: "用户兜底") }
        static var defaultGift: String { localize("party.defaultGift", comment: "礼物兜底") }
        static var cancel: String { localize("party.cancel", comment: "取消") }
        static var retry: String { localize("party.retry", comment: "重试") }
        static var loading: String { localize("party.loading", comment: "加载中…") }
        static var ok: String { localize("party.ok", comment: "好的") }
        static var alertTitle: String { localize("party.alert.title", comment: "提示") }
        static var onlineCountFormat: String { localize("party.onlineCount.format", comment: "在线 %d") }

        // 房列表（PartyRoomListView）
        static var listNavTitle: String { localize("party.list.navTitle", comment: "派对房列表标题") }
        static var listLoadMore: String { localize("party.list.loadMore", comment: "上拉加载更多") }
        static var listUnnamed: String { localize("party.list.unnamed", comment: "未命名房间") }
        static var listErrorLoadFailedFormat: String { localize("party.list.error.loadFailedFormat", comment: "加载失败：%@") }
        static var listErrorDecodeFormat: String { localize("party.list.error.decodeFormat", comment: "解码失败：%@") }

        // 创建房（PartyCreateRoomView）
        static var createNavTitle: String { localize("party.create.navTitle", comment: "创建派对房") }
        static var createSubmit: String { localize("party.create.submit", comment: "创建房间") }
        static var createSectionName: String { localize("party.create.section.name", comment: "房间名称") }
        static var createNamePlaceholder: String { localize("party.create.name.placeholder", comment: "最多 20 个字") }
        static var createSectionTemplate: String { localize("party.create.section.template", comment: "选择模板") }
        static var createTemplateLoading: String { localize("party.create.template.loading", comment: "加载模板…") }
        static var createTemplateEmpty: String { localize("party.create.template.empty", comment: "dev 暂无可用模板") }
        static var createTemplateFallbackFormat: String { localize("party.create.template.fallbackFormat", comment: "模板 %d") }
        static var createTemplateDetailFormat: String { localize("party.create.template.detailFormat", comment: "总麦位 %d · 视频 %d · 语聊 %d") }
        static var createErrorTemplateLoad: String { localize("party.create.error.templateLoad", comment: "模板加载失败") }
        static var createErrorTemplateLoadFormat: String { localize("party.create.error.templateLoadFormat", comment: "模板加载失败：%@") }
        static var createErrorNoRoomId: String { localize("party.create.error.noRoomId", comment: "服务端未返 roomId") }
        static var createErrorFailed: String { localize("party.create.error.failed", comment: "创建失败") }
        static var createErrorFailedFormat: String { localize("party.create.error.failedFormat", comment: "创建失败：%@") }

        // 房间内（PartyRoomView）
        static var inviteTitle: String { localize("party.invite.title", comment: "视频位邀请") }
        static var inviteAccept: String { localize("party.invite.accept", comment: "接受") }
        static var inviteReject: String { localize("party.invite.reject", comment: "拒绝") }
        static var inviteMessageFormat: String { localize("party.invite.messageFormat", comment: "%@ 邀请你上视频位 %d") }
        static var selfActionsTitle: String { localize("party.selfActions.title", comment: "我的麦位") }
        static var selfMicOn: String { localize("party.selfActions.micOn", comment: "开麦克风") }
        static var selfMicOff: String { localize("party.selfActions.micOff", comment: "关麦克风") }
        static var selfCamOn: String { localize("party.selfActions.camOn", comment: "开摄像头") }
        static var selfCamOff: String { localize("party.selfActions.camOff", comment: "关摄像头") }
        static var selfLeaveSeat: String { localize("party.selfActions.leaveSeat", comment: "下麦") }
        static var inputPlaceholder: String { localize("party.input.placeholder", comment: "说点什么…") }
        static var giftMessageFormat: String { localize("party.gift.messageFormat", comment: "🎁 %@ 送出 %@ x%d") }

        // 房态徽章
        static var stateJoined: String { localize("party.state.joined", comment: "已进房") }
        static var stateEntering: String { localize("party.state.entering", comment: "进房中…") }
        static var stateLeaving: String { localize("party.state.leaving", comment: "退房中…") }
        static var stateEnded: String { localize("party.state.ended", comment: "已离开") }

        // 麦位（PartySeatItemView）
        static var seatEmpty: String { localize("party.seat.empty", comment: "空麦位 a11y") }
        static var seatOccupied: String { localize("party.seat.occupied", comment: "麦上用户 a11y") }

        // 业务错误（PartyRoomError.errorDescription）
        static var errorEnterFailedFormat: String { localize("party.error.enterFailedFormat", comment: "进房失败：%@") }
        static var errorExitFailedFormat: String { localize("party.error.exitFailedFormat", comment: "退房失败：%@") }
        static var errorSeatOccupied: String { localize("party.error.seatOccupied", comment: "麦位已被占用") }
        static var errorSeatEmpty: String { localize("party.error.seatEmpty", comment: "麦位为空") }
        static var errorBanned: String { localize("party.error.banned", comment: "已被封禁") }
        static var errorLevelInsufficient: String { localize("party.error.levelInsufficient", comment: "等级不足") }
        static var errorNetworkLost: String { localize("party.error.networkLost", comment: "网络连接已断开") }
        static var errorKicked: String { localize("party.error.kicked", comment: "已被房主踢出") }
        static var errorPasswordWrong: String { localize("party.error.passwordWrong", comment: "进房密码错误") }
        static var errorMediaSwitchFailed: String { localize("party.error.mediaSwitchFailed", comment: "麦克风/摄像头切换失败") }
    }

    // MARK: - Work 工作台（设计稿还原）
    static var workWeeklyLevel: String { localize("work.weeklyLevel", comment: "周等级") }
    static var workDetail: String { localize("work.detail", comment: "详情") }
    static var workScorePrefix: String { localize("work.scorePrefix", comment: "分数前缀") }
    static var workNeedMoreFormat: String { localize("work.needMoreFormat", comment: "升级还需 %d 分") }

    static var workLevelTextTopHost: String { localize("work.levelText.topHost", comment: "顶级主播场景文案") }

    // Home 顶部刷新按钮 toast（对齐 H5 tabsNav.vue refreshIMOnline → showToast('call.reconnect')）
    static var callReconnect: String { localize("call.reconnect", comment: "重连 toast") }

    // 长时间无操作自动离线弹窗（对齐 H5 App.vue useDynamicInactivityTimer）
    static var autoOfflineTitle: String { localize("autoOffline.title", comment: "自动离线弹窗标题：Activity Verification") }
    static var autoOfflineMessage: String { localize("autoOffline.message", comment: "自动离线弹窗正文：inactive → 已改为离线，可点击恢复") }
    static var autoOfflineGoOnline: String { localize("autoOffline.goOnline", comment: "自动离线弹窗按钮：Go online") }

    // "今日已设为忙碌"弹窗（对齐安卓 SetToBusyDialog）
    static var setToBusyTitle: String { localize("setToBusy.title", comment: "已设为忙碌弹窗标题") }
    static var setToBusyDescription: String { localize("setToBusy.description", comment: "已设为忙碌弹窗描述") }
    static var setToBusyGoLive: String { localize("setToBusy.goLive", comment: "去直播按钮") }
    static var setToBusyGoMatch: String { localize("setToBusy.goMatch", comment: "去匹配按钮") }

    static var workOnlineTime: String { localize("work.onlineTime", comment: "在线时长") }
    static var workAvgCallDuration: String { localize("work.avgCallDuration", comment: "平均通话时长") }
    static var workPositiveRating: String { localize("work.positiveRating", comment: "好评率") }

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
    static var toolLiveData: String { localize("work.tool.liveData", comment: "直播数据") }

    // Invite 角标（H5 style: 金红渐变 "Earn Money"）
    static var inviteEarnMoney: String { localize("work.invite.earnMoney", comment: "邀请赚钱角标") }

    // 下线确认弹窗（对齐 H5 onlineStatus.*）
    static var offlineConfirmMessage: String { localize("work.offline.confirmMessage", comment: "确认下线？") }
    static var offlineConfirmYes: String { localize("work.offline.confirmYes", comment: "确认下线") }
    static var offlineConfirmNo: String { localize("work.offline.confirmNo", comment: "取消下线") }

    // 底部 tab 标签
    static var tabHome: String { localize("tab.home", comment: "首页") }
    static var tabMessages: String { localize("tab.messages", comment: "消息") }
    static var tabWork: String { localize("tab.work", comment: "工作台") }
    static var tabProfile: String { localize("tab.profile", comment: "我的") }

    // MARK: - Home 顶部 4 tab（对齐 H5 homeConfig.ts → key: live/list/match/circle）
    static var homeTopTabLive: String   { localize("home.topTab.live",   comment: "Live") }
    static var homeTopTabList: String   { localize("home.topTab.list",   comment: "List") }
    static var homeTopTabMatch: String  { localize("home.topTab.match",  comment: "Match") }
    static var homeTopTabCircle: String { localize("home.topTab.circle", comment: "Circle") }
    /// 占位子 tab 提示（Match / Circle Official 等未实现 tab 共用）
    static var homeTopTabComingSoon: String { localize("home.topTab.comingSoon", comment: "占位文案：敬请期待") }

    // MARK: - Circle 朋友圈内 3 子 tab（trial #1 A-spec §6B.8）
    static var circleSubTabOfficial: String { localize("home.circle.official.label", comment: "Circle 子 tab Official") }
    static var circleSubTabMoment: String   { localize("home.circle.moment.label",   comment: "Circle 子 tab Moment（全站圈）") }
    static var circleSubTabMe: String       { localize("home.circle.me.label",       comment: "Circle 子 tab Me（我的）") }
    /// Moment 加载失败提示
    static var circleMomentLoadError: String { localize("home.circle.moment.error.title", comment: "Moment 加载失败提示") }
    /// 观看人数后缀（a11y）
    static var liveViewers: String { localize("live.viewers", comment: "观看人数 a11y 后缀") }
    /// 顶部右侧按钮 a11y
    static var liveRankBadge: String { localize("live.rankBadge", comment: "排行榜按钮 a11y") }
    static var liveRefresh: String { localize("live.refresh", comment: "刷新按钮 a11y") }
    static var liveOnlineDot: String { localize("live.onlineDot", comment: "在线状态 a11y") }

    // MARK: - Live 广场（H5 liveList.vue 对齐）
    /// 广场空态提示（当前没有主播在直播）
    static var liveStreamEmpty: String { localize("liveStream.empty", comment: "Live 广场空数据提示") }
    /// PK 中角标 a11y
    static var liveStreamInPK: String { localize("liveStream.inPK", comment: "PK 中角标 a11y") }
    /// Banner 通用 a11y（本次不接跳转，仅描述）
    static var liveBannerA11y: String { localize("live.banner.a11y", comment: "首页 banner a11y") }
    /// 跑马灯"sends out a super rocket"文案（H5 i18n key `gift.sends out a super rocket`）
    static var giftSendSuperRocket: String { localize("gift.sendSuperRocket", comment: "跑马灯：发送超级火箭") }

    // MARK: - List 子页（设计稿还原）
    /// 顶部 Online/Prime 分段
    static var liveListSegmentOnline: String { localize("liveList.segment.online", comment: "Online 分段") }
    static var liveListSegmentPrime: String { localize("liveList.segment.prime", comment: "Prime 分段") }
    /// 卡片右侧动作按钮 a11y
    static var liveListActionChat: String { localize("liveList.action.chat", comment: "聊天按钮 a11y") }
    static var liveListActionLive: String { localize("liveList.action.live", comment: "直播按钮 a11y") }
    static var liveListActionMatch: String { localize("liveList.action.match", comment: "匹配按钮 a11y") }
    static var liveListActionOffline: String { localize("liveList.action.offline", comment: "下线开关 a11y") }
    /// 列表状态文案
    static var liveListEmpty: String { localize("liveList.empty", comment: "List 子页空数据提示") }
    static var liveListEnd: String { localize("liveList.end", comment: "List 子页已到底提示") }
    static var liveListLoadMoreFailed: String { localize("liveList.loadMoreFailed", comment: "触底加载失败提示") }
    static var liveListPullToRetry: String { localize("liveList.pullToRetry", comment: "首屏错误态引导下拉刷新") }

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
    /// 媒体预览图片 a11y 前缀
    static var mediaPreviewImage: String { localize("mediaPreview.image", comment: "媒体预览图片 a11y") }
    /// 媒体预览视频 a11y 前缀
    static var mediaPreviewVideo: String { localize("mediaPreview.video", comment: "媒体预览视频 a11y") }
    /// 媒体预览页码格式（%d/%d）
    static var mediaPreviewPositionFormat: String { localize("mediaPreview.positionFormat", comment: "媒体预览页码 %d/%d") }

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

    // MARK: - Message P2P 会话列表（H-1 MVP，spec §1.2 三分类）
    static var messageCategoryFlame: String     { localize("message.category.flame", comment: "会话分类 Flame") }
    static var messageCategoryStranger: String  { localize("message.category.stranger", comment: "会话分类 Stranger") }
    static var messageCategoryPrime: String     { localize("message.category.prime", comment: "会话分类 Prime") }
    static var messageEmptyFlame: String        { localize("message.empty.flame", comment: "Flame 空态文案") }
    static var messageEmptyStranger: String     { localize("message.empty.stranger", comment: "Stranger 空态文案") }
    static var messageEmptyPrime: String        { localize("message.empty.prime", comment: "Prime 空态文案") }
    static var messageLoadErrorRetry: String    { localize("message.loadError.retry", comment: "加载失败 retry") }
    static var messageActionStickTop: String    { localize("message.action.stickTop", comment: "置顶") }
    static var messageActionUnstickTop: String  { localize("message.action.unstickTop", comment: "取消置顶") }
    static var messageActionDelete: String      { localize("message.action.delete", comment: "删除会话") }
    static var messageActionFailedToast: String { localize("message.action.failedToast", comment: "操作失败通用 toast") }

    // MARK: - Message 顶部系统消息 3 入口（H-1c v4）
    static var messageSystemInboxStation: String       { localize("message.systemInbox.station", comment: "Flame 顶部 Station 入口标题") }
    static var messageSystemInboxNotification: String  { localize("message.systemInbox.notification", comment: "Flame 顶部 Notification 入口标题") }
    static var messageSystemInboxAdmin: String         { localize("message.systemInbox.admin", comment: "Flame 顶部 Admin 客服入口标题") }
    static var messageSystemInboxComingSoon: String    { localize("message.systemInbox.comingSoon", comment: "3 入口详情页留 H-2 未开放 toast") }

    // MARK: - Message 消息 preview 归一化（v5 F-3 i18n）
    static var messagePreviewImage: String          { localize("message.preview.image", comment: "会话预览：图片") }
    static var messagePreviewVoice: String          { localize("message.preview.voice", comment: "会话预览：语音") }
    static var messagePreviewVideo: String          { localize("message.preview.video", comment: "会话预览：视频") }
    static var messagePreviewLocation: String       { localize("message.preview.location", comment: "会话预览：位置") }
    static var messagePreviewGift: String           { localize("message.preview.gift", comment: "会话预览：礼物") }
    static var messagePreviewUnknown: String        { localize("message.preview.unknown", comment: "会话预览：未知消息") }
    static var messagePreviewCallMissed: String     { localize("message.preview.callMissed", comment: "会话预览：未接来电") }
    static var messagePreviewCallRejected: String   { localize("message.preview.callRejected", comment: "会话预览：拒接") }
    static var messagePreviewCallCancelled: String  { localize("message.preview.callCancelled", comment: "会话预览：已取消") }

    // MARK: - Message 通用操作（v5 F-4 i18n）
    static var messageActionCancel: String          { localize("message.action.cancel", comment: "confirmationDialog Cancel 按钮") }

    // MARK: - Message 时间格式（v5 F-5 i18n）
    static var messageTimeYesterday: String         { localize("message.time.yesterday", comment: "会话时间：昨天") }

    // MARK: - Message a11y label（v5 F-6 i18n；VoiceOver 朗读）
    static var messageA11yOnline: String            { localize("message.a11y.online", comment: "a11y 在线") }
    static var messageA11yOffline: String           { localize("message.a11y.offline", comment: "a11y 离线") }
    static var messageA11yPinned: String            { localize("message.a11y.pinned", comment: "a11y 已置顶") }
    static var messageA11yVIP: String               { localize("message.a11y.vip", comment: "a11y VIP") }
    static var messageA11yActiveTycoon: String      { localize("message.a11y.activeTycoon", comment: "a11y 活跃大 R") }
    /// %d = unread count
    static func messageA11yUnreadCountFormat(_ n: Int) -> String {
        String(format: localize("message.a11y.unreadCountFormat", comment: "a11y 未读数 format，参数: 数量"), n)
    }
    /// %@ = level number string
    static func messageA11yLevelFormat(_ level: String) -> String {
        String(format: localize("message.a11y.levelFormat", comment: "a11y 等级 format，参数: 等级"), level)
    }

    // MARK: - LevelDetail 段位详情页
    static var levelDetailTitle: String    { localize("level.title", comment: "段位详情标题") }
    static var levelDetailCurrent: String  { localize("level.current", comment: "当前段位 caption") }
    static var levelDetailSpectrum: String { localize("level.spectrum", comment: "段位光谱条 caption") }

    /// 礼物墙空态
    static var profileGiftsEmpty: String { localize("profile.gifts.empty", comment: "礼物墙空态文案") }

    // MARK: - Moment 动态卡片（Profile / Circle 共用 MomentPostRow）
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
    /// 删除动态按钮 a11y（仅 me 入口）
    static var momentActionDelete: String          { localize("moment.action.delete", comment: "动态删除 a11y") }

    // MARK: - J 里程碑：发布朋友圈页（spec §7 v3）
    enum Publish {
        static var navTitle: String        { localize("publish.navTitle", comment: "发布页导航标题") }
        static var cancel: String          { localize("publish.cancel", comment: "取消按钮") }
        static var release: String         { localize("publish.release", comment: "发布按钮") }
        static var placeholder: String     { localize("publish.placeholder", comment: "文本框占位") }
        static var charCountFormat: String { localize("publish.charCountFormat", comment: "字数计数 %d/500") }
        static var posting: String         { localize("publish.posting", comment: "上传遮罩文案") }
        static var addImage: String        { localize("publish.addImage", comment: "选图按钮 a11y") }
        static var removeImage: String     { localize("publish.removeImage", comment: "移除单张图 a11y") }
        static var fabLabel: String        { localize("publish.fabLabel", comment: "Circle 容器内 FAB a11y") }
        // 确认 dialog
        static var discardTitle: String    { localize("publish.discard.title", comment: "切走确认 dialog 标题") }
        static var discardMessage: String  { localize("publish.discard.message", comment: "切走确认正文") }
        static var discardConfirm: String  { localize("publish.discard.confirm", comment: "确认放弃按钮") }
        static var discardKeep: String     { localize("publish.discard.keep", comment: "保留编辑按钮") }
        // toast 文案（统一注入 ViewModel）
        static var textEmpty: String         { localize("publish.toast.textEmpty", comment: "请输入内容") }
        static var noImages: String          { localize("publish.toast.noImages", comment: "至少 1 张图") }
        static var imageTooLarge: String     { localize("publish.toast.imageTooLarge", comment: "图片过大 (>10MB)") }
        static var credentialFailed: String  { localize("publish.toast.credentialFailed", comment: "凭证获取失败") }
        static var uploadFailed: String      { localize("publish.toast.uploadFailed", comment: "上传失败") }
        static var createFailed: String      { localize("publish.toast.createFailed", comment: "发布失败兜底") }
        static var networkError: String      { localize("publish.toast.networkError", comment: "网络错误兜底") }
        static var publishSuccess: String    { localize("publish.toast.success", comment: "发布成功") }
    }

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

    // MARK: - LiveSettings 直播设置页（B-spec-开播设置页 v3；对齐 H5 5 张 CCard）
    static var liveSettingsNavTitle: String { localize("liveSettings.navTitle", comment: "H5 live.live setting") }
    static var liveSettingsBioTitle: String { localize("liveSettings.bioTitle", comment: "H5 live.live bio 卡片 title") }
    static var liveSettingsBioIntro: String { localize("liveSettings.bioIntro", comment: "H5 live.live bio desc 副标题") }
    static var liveSettingsBioPlaceholder: String { localize("liveSettings.bioPlaceholder", comment: "H5 common.please enter") }
    static var liveSettingsCoverTitle: String { localize("liveSettings.coverTitle", comment: "H5 live.live cover 卡片 title") }
    static var liveSettingsPrivateCallTitle: String { localize("liveSettings.privateCallTitle", comment: "H5 live.live call free 5 minute gift setup") }
    static var liveSettingsPrivateCallIntro: String { localize("liveSettings.privateCallIntro", comment: "H5 live.live call gift setup intro") }
    static var liveSettingsWishlistTitle: String { localize("liveSettings.wishlistTitle", comment: "H5 live.live wishlist") }
    static var liveSettingsWishlistIntro: String { localize("liveSettings.wishlistIntro", comment: "H5 live.live wishlist intro") }
    static var liveSettingsBeautyTitle: String { localize("liveSettings.beautyTitle", comment: "H5 beauty.beauty settings") }
    static var liveSettingsGoToSettings: String { localize("liveSettings.goToSettings", comment: "H5 beauty.go to setttings（H5 key typo 保留原样）") }
    static var liveSettingsComingSoon: String { localize("liveSettings.comingSoon", comment: "灰态占位后缀") }
    static var liveSettingsCounterFormat: String { localize("liveSettings.counterFormat", comment: "字符计数 %d/200") }

    // v5：Cover 上传 + Gift 选择
    static var liveSettingsCoverUploadHint: String { localize("liveSettings.coverUploadHint", comment: "tap 更换封面提示") }
    static var liveSettingsCoverUploading: String { localize("liveSettings.coverUploading", comment: "上传中 overlay 文案") }
    static var liveSettingsGiftAddHint: String { localize("liveSettings.giftAddHint", comment: "私 call 礼物添加提示") }
    static var liveSettingsGiftRemove: String { localize("liveSettings.giftRemove", comment: "移除已选礼物") }

    static var giftPickerTitle: String { localize("giftPicker.title", comment: "礼物选择弹窗标题") }
    static var giftPickerCancel: String { localize("giftPicker.cancel", comment: "取消") }
    static var giftPickerConfirm: String { localize("giftPicker.confirm", comment: "确认") }
    static var giftPickerRetry: String { localize("giftPicker.retry", comment: "重试") }
    static var giftPickerEmpty: String { localize("giftPicker.empty", comment: "空态") }

    // MARK: - L-spec-愿望单设置页 v1
    static var wishSettingNavTitle: String { localize("wishSetting.navTitle", comment: "Wish Setting 页顶部") }
    static var wishSettingRecord: String { localize("wishSetting.record", comment: "顶部 Record 审核记录按钮") }
    static var wishSettingThemeTitle: String { localize("wishSetting.themeTitle", comment: "Wish theme 卡片 title") }
    static var wishSettingThemeIntro: String { localize("wishSetting.themeIntro", comment: "Wish theme 副标题") }
    static var wishSettingSubmit: String { localize("wishSetting.submit", comment: "Wish theme Submit 审核") }
    static var wishSettingSelectTemplate: String { localize("wishSetting.selectTemplate", comment: "Select template 卡片 title") }
    static var wishSettingChooseTemplate: String { localize("wishSetting.chooseTemplate", comment: "dropdown 未选提示") }
    static var wishSettingTypeNoText: String { localize("wishSetting.type.noText", comment: "承诺档 No text") }
    static var wishSettingTypeCommon: String { localize("wishSetting.type.common", comment: "承诺档 Common template") }
    static var wishSettingTypePrivate: String { localize("wishSetting.type.private", comment: "承诺档 Private template") }
    static var wishSettingNoTemplateAvailable: String { localize("wishSetting.noTemplateAvailable", comment: "模板列表空") }
    static var wishSettingAddedFormat: String { localize("wishSetting.added.format", comment: "已添加 %d/%d") }
    static var wishSettingUpToFormat: String { localize("wishSetting.upTo.format", comment: "最多 %d 心愿礼物") }
    static var wishSettingGiftCount: String { localize("wishSetting.giftCount", comment: "sheet 内数量 label") }
    static var wishSettingMaxGiftNum: String { localize("wishSetting.maxGiftNum", comment: "礼物数量已达上限") }
    static var wishSettingRuleTitle: String { localize("wishSetting.ruleTitle", comment: "合规规范卡 title") }
    static var wishSettingRuleAgree: String { localize("wishSetting.ruleAgree", comment: "勾选合规规范文案") }
    static var wishSettingRuleLink: String { localize("wishSetting.ruleLink", comment: "合规规范链接文字") }
    static var wishSettingRuleDoc: String { localize("wishSetting.ruleDoc", comment: "合规规范只读文档正文") }
    static var wishSettingSave: String { localize("wishSetting.save", comment: "Save 按钮") }
    static var wishSettingPleaseEnterTheme: String { localize("wishSetting.pleaseEnterTheme", comment: "Wish theme 为空 toast") }
    static var wishSettingThemeMaxLen: String { localize("wishSetting.themeMaxLen", comment: "Wish theme > 15 chars") }
    static var wishSettingSubmittedForReview: String { localize("wishSetting.submittedForReview", comment: "Submit 成功 Alert 标题") }
    // P0-1 分层校验 toast + P1-2 保存成功 toast（对齐 H5 index.vue:351-397）
    static var wishSettingPleaseAgreeRule: String { localize("wishSetting.pleaseAgreeRule", comment: "未勾选合规规范") }
    static var wishSettingPleaseAddGift: String { localize("wishSetting.pleaseAddGift", comment: "未添加心愿礼物") }
    static var wishSettingPleasePickTemplate: String { localize("wishSetting.pleasePickTemplate", comment: "Common 未选模板") }
    static var wishSettingPleasePickPrivate: String { localize("wishSetting.pleasePickPrivate", comment: "Private 未选文案") }
    static var wishSettingSaved: String { localize("wishSetting.saved", comment: "保存成功 toast") }
    // v2 设计稿对齐补充
    static var wishSettingReviewStatus: String { localize("wishSetting.reviewStatus", comment: "Review status 卡标题") }
    static var wishSettingReviewStatusIntro: String { localize("wishSetting.reviewStatusIntro", comment: "Review status 副标题") }
    static var wishSettingTypeCommonSub: String { localize("wishSetting.type.commonSub", comment: "Common template chip 副标题") }
    static var wishSettingTypePrivateSub: String { localize("wishSetting.type.privateSub", comment: "Private template chip 副标题") }
    static var wishSettingTypeNoTextSub: String { localize("wishSetting.type.noTextSub", comment: "No text chip 副标题") }
    static var wishSettingRuleAgreeShort: String { localize("wishSetting.ruleAgreeShort", comment: "勾选行 I agree") }
    static var wishSettingRuleFooter: String { localize("wishSetting.ruleFooter", comment: "合规规范尾部承诺") }
    // 心愿承诺规范弹窗（对齐 H5 wishlist-rule-modal.vue）
    static var wishRuleModalTitle: String { localize("wishRuleModal.title", comment: "心愿承诺规范弹窗标题") }
    static var wishRuleModalCheck: String { localize("wishRuleModal.check", comment: "我已阅读并同意上述规范") }
    static var wishRuleModalAgree: String { localize("wishRuleModal.agree", comment: "同意并发布") }
    static var wishRuleModalContent: String { localize("wishRuleModal.content", comment: "心愿承诺规范正文（WishRuleModal 内 ScrollView 显示）") }

    // MARK: - 直播结果页（对齐 H5 views/liveEnds/index.vue + locales/*.json live.*）
    /// 顶部标题 "Live Ends"（H5 live.'live ends'）
    static var liveResultTitle: String { localize("liveResult.title", comment: "结果页顶部标题") }
    /// 时长 label "Duration"（H5 common.duration）
    static var liveResultDurationLabel: String { localize("liveResult.durationLabel", comment: "时长 label") }
    /// 弱网强制下播红字提示（H5 live.'Because your network too poor many times'）
    static var liveResultWeakNetworkNotice: String { localize("liveResult.weakNetworkNotice", comment: "弱网强制下播红字提示") }
    /// 卡 1 标题 "Live Data"（H5 live.'live data'）
    static var liveResultCardLiveData: String { localize("liveResult.card.liveData", comment: "卡 1 标题") }
    /// 卡 2 标题 "Top Gifters"
    static var liveResultCardTopGifters: String { localize("liveResult.card.topGifters", comment: "卡 2 标题") }
    /// 卡 3 标题 "Live to Private Calls"
    static var liveResultCardPrivateCalls: String { localize("liveResult.card.privateCalls", comment: "卡 3 标题") }
    /// 4 项数据 label
    static var liveResultViewers: String { localize("liveResult.viewers", comment: "观众数 label") }
    static var liveResultFollowers: String { localize("liveResult.followers", comment: "新增关注 label") }
    static var liveResultGifters: String { localize("liveResult.gifters", comment: "送礼人数 label") }
    static var liveResultDiamonds: String { localize("liveResult.diamonds", comment: "钻石收益 label") }
    /// "More" / 空态 "No Data" / 加载失败 / Retry / Back
    static var liveResultMore: String { localize("liveResult.more", comment: "More 按钮") }
    static var liveResultEmpty: String { localize("liveResult.empty", comment: "空态文本 No Data") }
    static var liveResultLoadFailed: String { localize("liveResult.loadFailed", comment: "加载失败 banner") }
    static var liveResultRetry: String { localize("liveResult.retry", comment: "重试按钮") }
    static var liveResultBack: String { localize("liveResult.back", comment: "顶部 back 按钮 a11y") }
    /// 关注 / Message / Coming soon
    static var liveResultFollow: String { localize("liveResult.follow", comment: "关注按钮") }
    static var liveResultMessage: String { localize("liveResult.message", comment: "私信按钮") }
    static var liveResultMessageComingSoon: String { localize("liveResult.messageComingSoon", comment: "私信入口占位 toast") }

    // MARK: - 首次开播规则页（严格对齐 H5 views/liveRule/component/firstLiveRule.vue + locales/*.json live.*）
    static var firstLiveRuleNavTitle: String { localize("firstLiveRule.navTitle", comment: "首次开播规则页 nav title") }
    static var firstLiveRuleBeforeStartTitle: String { localize("firstLiveRule.beforeStartTitle", comment: "H5 live.'before you start firstly'") }
    static var firstLiveRuleBeforeStartDesc: String { localize("firstLiveRule.beforeStartDesc", comment: "H5 live.'before you start firstly desc'") }
    static var firstLiveRuleGuidelinesTitle: String { localize("firstLiveRule.guidelinesTitle", comment: "H5 live.'live streaming guidelines'") }
    static var firstLiveRuleConfirm: String { localize("firstLiveRule.confirm", comment: "Confirm 按钮（H5 common.confirm）") }
    /// 7 条规则 title（H5 live.'live streaming guidelines desc <idx>'.title, idx = 1..7）
    static func firstLiveRuleGuidelineTitle(_ idx: Int) -> String {
        localize("firstLiveRule.guideline\(idx).title", comment: "Guideline \(idx) title")
    }
    /// 7 条规则 content（H5 live.'live streaming guidelines desc <idx>'.content）
    static func firstLiveRuleGuidelineContent(_ idx: Int) -> String {
        localize("firstLiveRule.guideline\(idx).content", comment: "Guideline \(idx) content")
    }

    // MARK: - LiveRoom 直播间
    static var liveRoomPermissionAlertTitle: String { localize("liveRoom.permissionAlertTitle", comment: "相机权限弹窗标题") }
    static var liveRoomPermissionAlertOK: String { localize("liveRoom.permissionAlertOK", comment: "相机权限弹窗确定按钮") }
    static var liveRoomPermissionAlertMessage: String { localize("liveRoom.permissionAlertMessage", comment: "相机权限弹窗内容") }
    static var liveRoomStatusLiveFormat: String { localize("liveRoom.statusLiveFormat", comment: "直播中状态（%@ 为时长）") }
    static var liveRoomStatusConnecting: String { localize("liveRoom.statusConnecting", comment: "连接中状态") }
    /// AgoraManager.State.label — 直播间 / Call POC 顶栏 RTC 状态文案
    static var liveRoomStatusIdle: String       { localize("liveRoom.status.idle", comment: "RTC 未加入") }
    static var liveRoomStatusJoined: String     { localize("liveRoom.status.joined", comment: "RTC 已加入频道") }
    static var liveRoomStatusFailed: String     { localize("liveRoom.status.failed", comment: "RTC 加入失败") }
    /// RTC 错误码格式（%d 为错误码）
    static var liveRoomStatusRtcErrorFormat: String { localize("liveRoom.status.rtcErrorFormat", comment: "RTC 错误码格式") }
    /// joinChannel 调用失败（%d 为返回码）
    static var liveRoomStatusJoinChannelFailedFormat: String { localize("liveRoom.status.joinChannelFailedFormat", comment: "joinChannel 调用失败") }
    static var liveRoomAnchorDefault: String { localize("liveRoom.anchorDefault", comment: "主播默认昵称") }
    static var liveRoomToolBeauty: String { localize("liveRoom.toolBeauty", comment: "底部美颜按钮") }
    static var liveRoomEndLive: String { localize("liveRoom.endLive", comment: "结束直播按钮") }
    static var liveRoomBeautyPanelTitle: String { localize("liveRoom.beautyPanelTitle", comment: "美颜面板标题") }

    // MARK: - LiveRoom 设计稿还原新增文案（顶部区域 / 公屏 / 底部工具 / a11y / coming soon）
    /// 顶部观众数徽章 a11y
    static var liveRoomViewerCountA11y: String { localize("liveRoom.viewerCount.a11y", comment: "顶部观众数徽章 a11y") }
    /// 顶部关闭按钮 a11y
    static var liveRoomCloseA11y: String { localize("liveRoom.close.a11y", comment: "顶部关闭按钮 a11y") }
    /// 顶部 Task 徽章 a11y
    static var liveRoomTaskA11y: String { localize("liveRoom.task.a11y", comment: "Task 徽章 a11y") }
    /// 顶部本场直播贡献值徽章 a11y
    static var liveRoomContributionA11y: String { localize("liveRoom.contribution.a11y", comment: "本场直播贡献值徽章 a11y") }
    /// 排行榜位次格式（%d 位次）
    static var liveRoomRankFormat: String { localize("liveRoom.rankFormat", comment: "排行榜位次格式 No.%d") }
    /// 未上榜时的文字（对齐 H5 未上榜态）
    static var liveRoomRankUnlisted: String { localize("liveRoom.rankUnlisted", comment: "排行榜未上榜文字") }
    /// 排行榜徽章 a11y
    static var liveRoomRankA11y: String { localize("liveRoom.rank.a11y", comment: "排行榜徽章 a11y") }
    /// Underway 徽章文字
    static var liveRoomUnderwayLabel: String { localize("liveRoom.underway.label", comment: "Underway 徽章文字") }
    /// Pavate Call 大按钮标签（H5 拼写 "Private Call"）
    static var liveRoomPrivateCallLabel: String { localize("liveRoom.privateCall.label", comment: "Private Call 大按钮标签") }
    /// 底部工具栏 PK 调试入口 a11y（仅 DEBUG）
    static var liveRoomToolPKDebug: String { localize("liveRoom.tool.pkDebug", comment: "底部 PK 调试按钮 a11y") }
    /// Say hi 输入框 placeholder
    static var liveRoomInputPlaceholder: String { localize("liveRoom.input.placeholder", comment: "Say hi 输入框 placeholder") }
    /// 发送按钮 a11y
    static var liveRoomInputSendA11y: String { localize("liveRoom.input.send.a11y", comment: "发送按钮 a11y") }
    /// Coming soon 提示（Task）
    static var liveRoomComingSoonTask: String { localize("liveRoom.comingSoon.task", comment: "点击 Task 徽章占位提示") }
    /// Coming soon 提示（贡献值明细）
    static var liveRoomComingSoonContribution: String { localize("liveRoom.comingSoon.contribution", comment: "点击贡献值徽章占位提示") }
    /// Coming soon 提示（排行榜）
    static var liveRoomComingSoonRank: String { localize("liveRoom.comingSoon.rank", comment: "点击排行榜徽章占位提示") }
    /// Coming soon 提示（Private Call 主动发起）
    static var liveRoomComingSoonPrivateCall: String { localize("liveRoom.comingSoon.privateCall", comment: "点击 Private Call 大按钮占位提示") }
    /// Coming soon 提示（快捷礼物）
    static var liveRoomComingSoonGift: String { localize("liveRoom.comingSoon.gift", comment: "点击底部快捷礼物占位提示") }
    /// Coming soon 提示（公屏发送）
    static var liveRoomComingSoonSend: String { localize("liveRoom.comingSoon.send", comment: "点击 Say hi 发送按钮占位提示") }

    // MARK: LiveRoom 顶部互动转盘（对齐 H5 liveRoomTop.vue rouletteOpen/Close.webp，2026-07-06 补入）
    static var liveRoomRouletteA11y: String { localize("liveRoom.roulette.a11y", comment: "顶部互动转盘按钮 a11y") }
    static var liveRoomComingSoonRoulette: String { localize("liveRoom.comingSoon.roulette", comment: "点击转盘按钮占位提示") }

    // MARK: - LiveRoom H5 交互对齐（2026-07-06 restore-design iteration 2）
    /// 底部工具栏 4 圆按钮（对齐 H5 msg/gift/setting 3 图标 + PKEntryBtn）
    static var liveRoomToolMessage:  String { localize("liveRoom.tool.message",  comment: "底部消息按钮 a11y") }
    static var liveRoomToolGift:     String { localize("liveRoom.tool.gift",     comment: "底部礼物按钮 a11y") }
    static var liveRoomToolSetting:  String { localize("liveRoom.tool.setting",  comment: "底部设置按钮 a11y（含美颜/结束直播）") }
    /// 消息按钮点击占位
    static var liveRoomComingSoonMessage: String { localize("liveRoom.comingSoon.message", comment: "消息按钮占位提示") }
    /// 设置菜单：美颜项
    static var liveRoomSettingBeauty:     String { localize("liveRoom.setting.beauty",     comment: "设置菜单：美颜") }
    /// 设置菜单：结束直播项
    static var liveRoomSettingEndLive:    String { localize("liveRoom.setting.endLive",    comment: "设置菜单：结束直播") }

    // MARK: PK 入口按钮 5 态 a11y + 中断/断开确认占位（对齐 H5 pkEntryBtn.vue）
    static var liveRoomPKA11yDefault:   String { localize("liveRoom.pk.a11y.default",   comment: "PK 按钮默认态 a11y") }
    static var liveRoomPKA11yMatching:  String { localize("liveRoom.pk.a11y.matching",  comment: "PK 按钮匹配中 a11y") }
    static var liveRoomPKA11yInvited:   String { localize("liveRoom.pk.a11y.invited",   comment: "PK 按钮被邀请中 a11y") }
    static var liveRoomPKA11yInPK:      String { localize("liveRoom.pk.a11y.inPK",      comment: "PK 按钮 PK 中 a11y") }
    static var liveRoomPKA11yPunishing: String { localize("liveRoom.pk.a11y.punishing", comment: "PK 按钮惩罚中 a11y") }
    /// PK 中断确认弹窗占位（B-2 未实现，先 toast）
    static var liveRoomComingSoonPKInterrupt:  String { localize("liveRoom.comingSoon.pkInterrupt",  comment: "PK 中点击占位") }
    /// PK 断开确认弹窗占位（B-3 未实现，先 toast）
    static var liveRoomComingSoonPKDisconnect: String { localize("liveRoom.comingSoon.pkDisconnect", comment: "惩罚中点击占位") }

    // MARK: Private Call 小开关（对齐 H5 van-switch）
    /// 开关下方文字
    static var liveRoomPrivateCallCaption:  String { localize("liveRoom.privateCall.caption", comment: "Private call 开关下方文字") }

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
    // CallStore.lastError（C 期 UI 接入前预留 i18n）：用户可感知的通话错误文案
    static var callErrorRtmTokenEmpty: String      { localize("call.error.rtmTokenEmpty", comment: "RTM token 为空") }
    static var callErrorInvalidRemoteUserId: String { localize("call.error.invalidRemoteUserId", comment: "对方 userId 非法") }
    static var callErrorCreateFailed: String       { localize("call.error.createFailed", comment: "通话发起失败") }
    static var callErrorSendFailed: String         { localize("call.error.sendFailed", comment: "呼叫信令发送失败") }
    static var callErrorAcceptFailed: String       { localize("call.error.acceptFailed", comment: "接听信令发送失败") }
    static var callErrorRtcTokenFailed: String     { localize("call.error.rtcTokenFailed", comment: "获取 RTC token 失败") }
    /// "rtcToken: %@" 错误格式（%@ 为底层错误消息）
    static var callErrorRtcTokenFormat: String     { localize("call.error.rtcTokenFormat", comment: "RTC token 错误格式") }
    static var callErrorRemoteRejected: String     { localize("call.error.remoteRejected", comment: "对方已拒绝") }
    /// 通用：会话已过期 / 未登录提示
    static var sessionExpiredError: String         { localize("auth.sessionExpired", comment: "未登录 / 会话已过期") }

    // MARK: - Call 1v1 真实通话视图（CallView.swift）
    static var callSubtitleCallingOut: String { localize("call.subtitle.callingOut", comment: "1v1：主叫副标题") }
    static var callSubtitleIncoming: String { localize("call.subtitle.incoming", comment: "1v1：被叫副标题") }
    static var callActionCancel: String { localize("call.action.cancel", comment: "1v1：取消按钮（主叫端）") }
    static var callActionReject: String { localize("call.action.reject", comment: "1v1：拒接按钮") }
    static var callActionAccept: String { localize("call.action.accept", comment: "1v1：接听按钮") }
    static var callActionHangupBackToLive: String { localize("call.action.hangupBackToLive", comment: "1v1：挂断回直播（直播私 call）") }
    static var callActionHangup: String { localize("call.action.hangup", comment: "1v1：挂断按钮") }
    static var callLiveBanner: String { localize("call.liveBanner", comment: "1v1：直播私 call 顶部 banner") }

    // MARK: - C 1v1 通话（HUD）
    enum Call {
        enum Hud {
            static var incomeFormat: String { localize("call.hud.incomeFormat", comment: "通话收入累加（%d 钻石）") }
            static var giftIncomeFormat: String { localize("call.hud.giftIncomeFormat", comment: "礼物收入累加（%d 钻石）") }
            static var waitBonusFormat: String { localize("call.hud.waitBonusFormat", comment: "充值奖励气泡（%d 钻石）") }
            static var remoteTextFormat: String { localize("call.hud.remoteTextFormat", comment: "远端文字气泡（%@ 为原文）") }
            static var waitStartPay: String { localize("call.hud.wait.startPay", comment: "用户发起支付（type=1）") }
            static var waitPaySuccess: String { localize("call.hud.wait.paySuccess", comment: "用户支付成功（type=2）") }
            static var waitCallTimeEnd: String { localize("call.hud.wait.callTimeEnd", comment: "通话计时已暂停（type=3）") }
            static var waitPayCancel: String { localize("call.hud.wait.payCancel", comment: "用户取消支付（type=4）") }
        }
    }

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

    // MARK: - H-0 用户详情页（对照 H5 userProfile/index.vue）
    static var userProfileUidPrefix: String         { localize("userProfile.uid.prefix", comment: "uid 前缀，含冒号空格") }
    static var userProfileLikeLabel: String         { localize("userProfile.like.label", comment: "卡片：点赞数标题") }
    static var userProfileFavoriteLabel: String     { localize("userProfile.favorite.label", comment: "卡片：收藏数标题") }
    static var userProfileFollow: String            { localize("userProfile.follow", comment: "FOLLOW 按钮") }
    static var userProfileFollowing: String         { localize("userProfile.following", comment: "FOLLOWING 按钮（已关注）") }
    static var userProfileMenuReport: String        { localize("userProfile.menu.report", comment: "菜单：举报") }
    static var userProfileMenuBlock: String         { localize("userProfile.menu.block", comment: "菜单：拉黑") }
    static var userProfileBlockConfirmTitle: String { localize("userProfile.blockConfirm.title", comment: "拉黑二次确认标题") }
    static var userProfileBlockConfirmMessage: String { localize("userProfile.blockConfirm.message", comment: "拉黑二次确认正文") }
    static var userProfileBlockConfirmAction: String { localize("userProfile.blockConfirm.action", comment: "拉黑确认按钮") }
    static var userProfileBlockConfirmCancel: String { localize("userProfile.blockConfirm.cancel", comment: "拉黑取消按钮") }
    static var userProfileBlockSuccess: String      { localize("userProfile.block.success", comment: "拉黑成功 toast") }
    static var userProfileBlockFail: String         { localize("userProfile.block.fail", comment: "拉黑失败 toast") }
    static var userProfileGiftWallTitle: String     { localize("userProfile.giftWall.title", comment: "礼物墙区块标题") }
    static var userProfileGiftWallPlaceholder: String { localize("userProfile.giftWall.placeholder", comment: "礼物墙占位 coming soon") }
    static var userProfileActionMessage: String     { localize("userProfile.action.message", comment: "底部 ActionBar：私聊") }
    static var userProfileActionCall: String        { localize("userProfile.action.call", comment: "底部 ActionBar：通话") }
    static var userProfileNetworkError: String      { localize("userProfile.networkError", comment: "网络错误兜底") }
    static var userProfileBadUserId: String         { localize("userProfile.badUserId", comment: "userId 非法") }
    static var userProfileLoadErrorRetry: String    { localize("userProfile.loadError.retry", comment: "加载失败 retry") }
    static var commonComingSoon: String             { localize("common.comingSoon", comment: "占位按钮 toast") }
    static var commonBack: String                   { localize("common.back", comment: "无障碍：返回按钮 label") }
    static var userProfileA11yAvatar: String        { localize("userProfile.a11y.avatar", comment: "无障碍：头像 label") }
    static var userProfileA11yMenu: String          { localize("userProfile.a11y.menu", comment: "无障碍：菜单按钮 label") }
    static var userProfileA11yGiftFallback: String  { localize("userProfile.a11y.giftFallback", comment: "无障碍：礼物 name 为 nil 时兜底") }

    // MARK: - K 里程碑 美颜设置页（对照 H5 beautySettings/index.vue；spec §4）
    enum BeautySettings {
        // 页面标题 + 底部按钮
        static var pageTitle: String        { localize("beautySettings.pageTitle", comment: "美颜设置页标题") }
        static var globalToggle: String     { localize("beautySettings.globalToggle", comment: "全局开关：美颜") }
        static var resetDefaults: String    { localize("beautySettings.resetDefaults", comment: "恢复默认") }
        static var done: String             { localize("beautySettings.done", comment: "完成/关闭") }

        // Tab
        static var tabSkin: String          { localize("beautySettings.tab.skin", comment: "美肤 tab") }
        static var tabShape: String         { localize("beautySettings.tab.shape", comment: "美型 tab") }
        static var tabFilter: String        { localize("beautySettings.tab.filter", comment: "滤镜 tab") }
        static var tabSticker: String       { localize("beautySettings.tab.sticker", comment: "贴纸 tab") }

        // 状态横幅
        static var bannerLoading: String    { localize("beautySettings.banner.loading", comment: "美颜引擎加载中") }
        static var bannerUnavailable: String { localize("beautySettings.banner.unavailable", comment: "美颜不可用") }
        static var bannerInterrupted: String { localize("beautySettings.banner.interrupted", comment: "预览已暂停") }

        // 美肤 10 项
        static var paramBlur: String        { localize("beautySettings.param.blur", comment: "磨皮") }
        static var paramWhiten: String      { localize("beautySettings.param.whiten", comment: "美白") }
        static var paramRed: String         { localize("beautySettings.param.red", comment: "红润") }
        static var paramClarity: String     { localize("beautySettings.param.clarity", comment: "清晰") }
        static var paramSharpen: String     { localize("beautySettings.param.sharpen", comment: "锐化") }
        static var paramFaceThreed: String  { localize("beautySettings.param.faceThreed", comment: "五官立体") }
        static var paramEyeBright: String   { localize("beautySettings.param.eyeBright", comment: "亮眼") }
        static var paramToothWhiten: String { localize("beautySettings.param.toothWhiten", comment: "美牙") }
        static var paramRemovePouch: String { localize("beautySettings.param.removePouch", comment: "去黑眼圈") }
        static var paramRemoveNasolabialFolds: String { localize("beautySettings.param.removeNasolabialFolds", comment: "去法令纹") }

        // 美型 15 项
        static var paramCheekV: String      { localize("beautySettings.param.cheekV", comment: "V脸") }
        static var paramCheekNarrow: String { localize("beautySettings.param.cheekNarrow", comment: "窄脸") }
        static var paramCheekShort: String  { localize("beautySettings.param.cheekShort", comment: "短脸") }
        static var paramCheekSmall: String  { localize("beautySettings.param.cheekSmall", comment: "小脸") }
        static var paramIntensityCheekbones: String { localize("beautySettings.param.intensityCheekbones", comment: "瘦颧骨") }
        static var paramIntensityLowerJaw: String { localize("beautySettings.param.intensityLowerJaw", comment: "瘦下颌骨") }
        static var paramEyeEnlarging: String { localize("beautySettings.param.eyeEnlarging", comment: "大眼") }
        static var paramIntensityEyeCircle: String { localize("beautySettings.param.intensityEyeCircle", comment: "圆眼") }
        static var paramIntensityChin: String { localize("beautySettings.param.intensityChin", comment: "下巴") }
        static var paramIntensityForehead: String { localize("beautySettings.param.intensityForehead", comment: "额头") }
        static var paramIntensityNose: String { localize("beautySettings.param.intensityNose", comment: "瘦鼻") }
        static var paramIntensityMouth: String { localize("beautySettings.param.intensityMouth", comment: "嘴型") }
        static var paramIntensityLipThick: String { localize("beautySettings.param.intensityLipThick", comment: "嘴唇厚度") }
        static var paramIntensityCanthus: String { localize("beautySettings.param.intensityCanthus", comment: "开眼角") }
        static var paramIntensityEyeSpace: String { localize("beautySettings.param.intensityEyeSpace", comment: "眼距") }

        // 11 滤镜
        static var filterOrigin: String     { localize("beautySettings.filter.origin", comment: "原图") }
        static var filterZiran: String      { localize("beautySettings.filter.ziran", comment: "自然") }
        static var filterZhiganhui: String  { localize("beautySettings.filter.zhiganhui", comment: "质感灰") }
        static var filterMitao: String      { localize("beautySettings.filter.mitao", comment: "蜜桃") }
        static var filterBailiang: String   { localize("beautySettings.filter.bailiang", comment: "白亮") }
        static var filterFennen: String     { localize("beautySettings.filter.fennen", comment: "粉嫩") }
        static var filterLengsediao: String { localize("beautySettings.filter.lengsediao", comment: "冷色调") }
        static var filterNuansediao: String { localize("beautySettings.filter.nuansediao", comment: "暖色调") }
        static var filterGexing: String     { localize("beautySettings.filter.gexing", comment: "个性") }
        static var filterXiaoqingxin: String { localize("beautySettings.filter.xiaoqingxin", comment: "小清新") }
        static var filterHeibai: String     { localize("beautySettings.filter.heibai", comment: "黑白") }
        static var filterLevelLabel: String { localize("beautySettings.filter.levelLabel", comment: "滤镜强度") }

        // 贴纸占位
        static var stickerComingSoon: String { localize("beautySettings.sticker.comingSoon", comment: "贴纸敬请期待") }

        // 错误文案（对齐 BeautyError.localizationKey）
        static var errorAuthExpired: String { localize("beauty.error.authExpired", comment: "authpack 过期请更新 App") }
        static var errorBundleMissing: String { localize("beauty.error.bundleMissing", comment: "美颜资源缺失") }
        static var errorGenericSetupFailed: String { localize("beauty.error.genericSetupFailed", comment: "美颜引擎初始化失败") }
        static var errorSetupTimeout: String { localize("beauty.error.setupTimeout", comment: "美颜引擎超时") }
        static var errorPersistenceDecodeFailed: String { localize("beauty.error.persistenceDecodeFailed", comment: "美颜设置读取失败") }
        static var errorPersistenceWriteFailed: String { localize("beauty.error.persistenceWriteFailed", comment: "美颜设置保存失败") }

        // 无障碍
        static var a11yPreview: String      { localize("beautySettings.a11y.preview", comment: "无障碍：预览区") }
        static var a11ySliderFormat: String { localize("beautySettings.a11y.sliderFormat", comment: "无障碍：滑块 %@ 值 %d") }

        // H5 对齐 2026-07-02：icon row 首位 Recover + 顶部 Save
        static var recover: String          { localize("beautySettings.recover", comment: "参数图标行第一位：恢复默认") }
        static var save: String             { localize("beautySettings.save", comment: "顶部保存按钮") }

        // Recover 确认弹窗（2026-07-02 需求 2）
        static var recoverConfirmTitle: String   { localize("beautySettings.recoverConfirm.title", comment: "Recover 确认弹窗标题") }
        static var recoverConfirmMessage: String { localize("beautySettings.recoverConfirm.message", comment: "Recover 确认弹窗正文") }
        static var recoverConfirmYes: String     { localize("beautySettings.recoverConfirm.yes", comment: "Recover 确认按钮") }
        static var recoverConfirmNo: String      { localize("beautySettings.recoverConfirm.no", comment: "Recover 取消按钮") }

        // X 按钮未保存丢弃弹窗（2026-07-03 对齐 H5 index.vue:199-210 goBack）
        static var exitConfirmTitle: String    { localize("beautySettings.exitConfirm.title", comment: "退出未保存弹窗标题") }
        static var exitConfirmMessage: String  { localize("beautySettings.exitConfirm.message", comment: "退出未保存弹窗正文") }
        static var exitConfirmDiscard: String  { localize("beautySettings.exitConfirm.discard", comment: "退出未保存 - 丢弃按钮") }
        static var exitConfirmContinue: String { localize("beautySettings.exitConfirm.continue", comment: "退出未保存 - 继续编辑按钮") }

        // Save 成功 toast（2026-07-03 对齐 H5 index.vue:155 showToast('save success!')）
        static var saveSuccessToast: String    { localize("beautySettings.saveSuccess.toast", comment: "Save 成功后顶部 toast") }
    }

    // MARK: - H-2 私密媒体解锁（Gift Message，对齐 H5 secretMessage）
    enum GiftMessage {
        static var navTitle: String            { localize("giftMessage.navTitle", comment: "导航栏标题") }
        static var photoTitle: String          { localize("giftMessage.photoTitle", comment: "图片区标题") }
        static var videoTitle: String          { localize("giftMessage.videoTitle", comment: "视频区标题") }
        static var setGiftIntro: String        { localize("giftMessage.setGiftIntro", comment: "卡片副标题") }
        static var submit: String              { localize("giftMessage.submit", comment: "提交按钮") }
        static var giftPickerTitle: String     { localize("giftMessage.giftPicker.title", comment: "礼物选择标题") }
        static var giftPickerLoadFail: String  { localize("giftMessage.giftPicker.loadFail", comment: "礼物列表加载失败") }
        static var reachedLimit: String        { localize("giftMessage.reachedLimit", comment: "达到上限") }
        static var selectGiftRequired: String  { localize("giftMessage.selectGiftRequired", comment: "所有项必须绑礼物") }
        static var addMedia: String            { localize("giftMessage.addMedia", comment: "+ a11y") }
        static var deleteItem: String          { localize("giftMessage.deleteItem", comment: "删除 a11y") }
        static var networkErrorFallback: String { localize("giftMessage.networkErrorFallback", comment: "网络错误兜底") }
        static var unsupportedFile: String     { localize("giftMessage.unsupportedFile", comment: "文件不支持") }
        static var uploading: String           { localize("giftMessage.uploading", comment: "上传中 loading 文案") }
        static var submitSucceed: String       { localize("giftMessage.submitSucceed", comment: "提交成功 toast，对齐 H5 showToast('submit succeed')") }
        static func photoCountFormat(_ current: Int, _ max: Int) -> String {
            String(format: localize("giftMessage.photoCountFormat", comment: "(%d/%d)"), current, max)
        }
        static func videoCountFormat(_ current: Int, _ max: Int) -> String {
            String(format: localize("giftMessage.videoCountFormat", comment: "(%d/%d)"), current, max)
        }
    }

    // MARK: - Match tab（L 里程碑）
    /// 跑马灯"Video Call Started."
    static var matchMarqueeCallStarted: String {
        localize("match.marquee.callStarted", comment: "跑马灯 Video Call Started.")
    }
    /// 跑马灯空态占位（H5 主播端跑马灯一直显示，iOS 侧对齐；空 callList 时兜底文案）
    static var matchMarqueeEmpty: String {
        localize("match.marquee.empty", comment: "跑马灯空态占位")
    }
    /// "N Matches Found!"
    static func matchTitleMatchesFound(count: Int) -> String {
        String(format: localize("match.title.matchesFound", comment: "N Matches Found!"), count)
    }
    /// 主视觉下方描述
    static var matchSubtitleDescription: String {
        localize("match.subtitle.description",
                 comment: "Your recent matches are above. Tap to chat and charm them into calling you.")
    }
    /// 用户列表空态
    static var matchUserListEmpty: String {
        localize("match.userList.empty", comment: "暂无匹配用户")
    }
    /// 用户卡片 sheet：价格
    static func matchUserCardVideoPrice(price: Int) -> String {
        String(format: localize("match.userCard.videoPrice", comment: "%d/min"), price)
    }
    /// 用户卡片 sheet：关闭按钮
    static var matchUserCardClose: String {
        localize("match.userCard.close", comment: "关闭")
    }
    /// 匹配按钮 a11y：开启匹配
    static var matchButtonA11yTurnOn: String {
        localize("match.button.a11y.turnOn", comment: "开启匹配 a11y")
    }
    /// 匹配按钮 a11y：关闭匹配
    static var matchButtonA11yTurnOff: String {
        localize("match.button.a11y.turnOff", comment: "关闭匹配 a11y")
    }

    // MARK: - Match toast（L 里程碑 · MatchStore 状态迁移 toast 文案）
    static var matchToastNetworkError: String {
        localize("match.toast.networkError", comment: "网络失败 toast")
    }
    static var matchToastNoFaceDetected: String {
        localize("match.toast.noFaceDetected", comment: "人脸识别失败被封禁 toast")
    }
    static var matchToastExceedCount: String {
        localize("match.toast.exceedCount", comment: "超过匹配次数上限 toast")
    }
    static var matchToastTurnOnFailed: String {
        localize("match.toast.turnOnFailed", comment: "开启匹配失败 toast")
    }
    static var matchToastTurnOnSucceed: String {
        localize("match.toast.turnOnSucceed", comment: "开启匹配成功 toast")
    }
    static var matchToastTurnOffSucceed: String {
        localize("match.toast.turnOffSucceed", comment: "关闭匹配成功 toast")
    }
    static var matchToastCameraStartFailed: String {
        localize("match.toast.cameraStartFailed", comment: "摄像头开启失败 toast")
    }
    static var matchToastCameraUnavailable: String {
        localize("match.toast.cameraUnavailable", comment: "摄像头长时间中断未恢复 toast")
    }
    /// 跑马灯 VoiceOver 语义化文案（避免用 "→" 箭头符号，RTL 无歧义）。
    /// %@ = caller nickname / %@ = receiver nickname
    static func matchMarqueeA11yCallFormat(caller: String, receiver: String) -> String {
        String(format: localize("match.marquee.a11y.callFormat",
                                comment: "跑马灯 VoiceOver: %@ called %@"),
               caller, receiver)
    }

    // MARK: - Match rule 弹窗（#3b 首次每日开启匹配的规则同意；对齐 H5 c-goMatch.vue showRulePopup）
    static var matchRuleTitle: String {
        localize("match.rule.title", comment: "匹配规则弹窗标题")
    }
    static var matchRuleDetail1: String {
        localize("match.rule.detail1", comment: "匹配规则条款 1")
    }
    static var matchRuleDetail2: String {
        localize("match.rule.detail2", comment: "匹配规则条款 2")
    }
    static var matchRuleDetail3: String {
        localize("match.rule.detail3", comment: "匹配规则条款 3")
    }
    static var matchRuleDetail4: String {
        localize("match.rule.detail4", comment: "匹配规则条款 4")
    }
    static var matchRuleAgree: String {
        localize("match.rule.agree", comment: "匹配规则同意按钮")
    }

    // MARK: - Match tip 弹窗（#3c 10 分钟未开启匹配提示）
    static var matchTipTitle: String {
        localize("match.tip.title", comment: "匹配提示弹窗标题（Turn on matching to receive calls faster）")
    }
    static var matchTipGoMatch: String {
        localize("match.tip.goMatch", comment: "匹配提示确认按钮")
    }
    static var matchTipNoReminder: String {
        localize("match.tip.noReminder", comment: "今日不再提醒 checkbox 文案")
    }

    // MARK: - #3d 未露脸弹窗 + 移除匹配弹窗
    static var matchFaceNotDetectedTitle: String {
        localize("match.face.notDetected.title", comment: "未检测到人脸标题")
    }
    static var matchFaceNotDetectedContent: String {
        localize("match.face.notDetected.content", comment: "未检测到人脸提示内容")
    }
    static var matchExitTitle: String {
        localize("match.exit.title", comment: "移除匹配弹窗标题")
    }
    static var matchExitContent: String {
        localize("match.exit.content", comment: "移除匹配弹窗内容")
    }
}
