import Foundation

/// 本地化查表入口。
///
/// - `AppLocaleStore.shared.current != .system` 时：从对应 `.lproj` sub-bundle 直接查表 ——
///   用户在 Settings → Language 切换语言时立即生效无需重启（配合 AppLocaleEnvironmentModifier `.id()` 触发子树重建）。
/// - `.system` 或 sub-bundle 未命中时：fallback 到标准 `NSLocalizedString`，按系统语言解析。
///
/// 所有 L10n 字段是 computed property（每次访问重新查表），切语言后 View 重绘时自动取到新文案。
fileprivate func localize(_ key: String, comment: String = "") -> String {
    if let sub = AppLocaleStore.shared.subBundle {
        let value = sub.localizedString(forKey: key, value: "__MISSING__", table: nil)
        if value != "__MISSING__" { return value }
    }
    // A newly added feature can reach an existing locale bundle before its final
    // translation is available. Fall back to the English resource instead of
    // exposing the raw localization key to a financial flow.
    if let englishPath = Bundle.main.path(forResource: "en", ofType: "lproj"),
       let englishBundle = Bundle(path: englishPath) {
        let value = englishBundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
        if value != "__MISSING__" { return value }
    }
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

    // 媒体权限门禁
    static var mediaPermissionCameraRequired: String {
        localize("mediaPermission.cameraRequired", comment: "美颜等相机功能需要相机权限")
    }
    static var mediaPermissionMicrophoneRequired: String {
        localize("mediaPermission.microphoneRequired", comment: "语音功能需要麦克风权限")
    }
    static var mediaPermissionLiveRequired: String {
        localize("mediaPermission.liveRequired", comment: "直播需要相机和麦克风权限")
    }
    static var mediaPermissionAlertTitle: String {
        localize("mediaPermission.alertTitle", comment: "媒体权限弹窗标题")
    }

    // 全局空态占位（EmptyStateView 默认文案；所有列表/网格/tab 无数据统一使用）
    static var commonNoContent: String { localize("common.emptyState.noContent", comment: "全局空态：暂无内容") }

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
        /// PK 邀请 sheet 主标题（对齐 H5 `pk.Initiate PK`）
        static var initiateTitle: String { localize("pk.initiate.title", comment: "邀请 sheet 主标题 Initiate PK") }
        /// PKMatchingCard idle 提示文案（对齐 H5 `pk.RANDOM PK NOTICE` 系列）
        static var matchingCardHint: String { localize("pk.matchingCard.hint", comment: "随机匹配 idle 提示") }
        /// PKMatchingCard matched 视觉短文（对齐 H5 `pk.Opponent matched successfully`）
        static var matchingCardMatched: String { localize("pk.matchingCard.matched", comment: "对手匹配成功") }
        /// PKMatchingCard matching 状态左上 chip（对齐 H5 `pk.Searching for an opponent`）
        static var matchingCardSearching: String { localize("pk.matchingCard.searching", comment: "匹配中状态 chip") }
        /// Duration picker sheet 标题（对齐 H5 `pk.Set the PK duration`）
        static var durationPickerTitle: String { localize("pk.durationPicker.title", comment: "PK 时长选择器标题") }

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
        static var inviteToastMatching: String { localize("pk.invite.toast.matching", comment: "对方在随机匹配中，请稍后再试（对齐 H5 语义：对方 in matching，非自己）") }
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
        /// PK 贡献榜 sheet 标题（H5 pkRankListPopup.vue "guardian fans list"）
        static var rankSheetTitle: String { localize("pk.rank.sheet.title", comment: "PK 贡献榜 sheet 标题 Guardian Fans List") }
        /// PK 贡献榜 sheet 空态文案
        static var rankSheetEmpty: String { localize("pk.rank.sheet.empty", comment: "PK 贡献榜 sheet 空态 No Data") }
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
        static var giftEffectSendsTo: String { localize("party.giftEffect.sendsTo", comment: "派对房礼物飘屏 Sends to") }
        static var giftEffectPeopleFormat: String { localize("party.giftEffect.peopleFormat", comment: "派对房礼物飘屏接收人数 %d people") }
        static var cancel: String { localize("party.cancel", comment: "取消") }
        static var retry: String { localize("party.retry", comment: "重试") }
        static var loading: String { localize("party.loading", comment: "加载中…") }
        static var ok: String { localize("party.ok", comment: "好的") }
        static var alertTitle: String { localize("party.alert.title", comment: "提示") }
        static var onlineCountFormat: String { localize("party.onlineCount.format", comment: "在线 %d") }
        static var shareInviteTitle: String { localize("party.shareInvite.title", comment: "分享邀请面板标题") }
        static var shareInviteSent: String { localize("party.shareInvite.sent", comment: "房间邀请发送成功") }

        // 房列表（PartyRoomListView）
        static var listNavTitle: String { localize("party.list.navTitle", comment: "派对房列表标题") }
        static var listLoadMore: String { localize("party.list.loadMore", comment: "上拉加载更多") }
        static var listUnnamed: String { localize("party.list.unnamed", comment: "未命名房间") }
        static var listErrorLoadFailedFormat: String { localize("party.list.error.loadFailedFormat", comment: "加载失败：%@") }
        static var listErrorDecodeFormat: String { localize("party.list.error.decodeFormat", comment: "解码失败：%@") }

        // 大厅新版（1b 设计稿还原）
        static var listCreateRoom: String { localize("party.list.createRoom", comment: "Create Room 按钮文案") }
        static var listEmpty: String { localize("party.list.empty", comment: "空态引导文案") }
        static var listErrorRetry: String { localize("party.list.error.retry", comment: "错误态 retry") }
        static var listWelcomeFallback: String { localize("party.list.welcomeFallback", comment: "房间欢迎语 fallback") }
        static var listPillLiveVoice: String { localize("party.list.pill.liveVoice", comment: "视觉占位 pill 1：Live+Voice") }
        static var listPillVoice: String { localize("party.list.pill.voice", comment: "视觉占位 pill 2：Voice") }
        static var listPillLanguageFallback: String { localize("party.list.pill.languageFallback", comment: "语言 pill fallback：English") }
        static func listWeeklyTop(_ rank: Int) -> String {
            String(format: localize("party.list.weeklyTop", comment: "房间卡周榜标签：Weekly Top %d"), rank)
        }

        // 大厅增强（E-plan 2026-07-10 对齐 livechat-h5 用户端 /party/index.vue）
        static var tabParty: String { localize("party.tab.party", comment: "顶部 tab Party") }
        static var tabFollow: String { localize("party.tab.follow", comment: "顶部 tab Follow") }
        static var tabRecent: String { localize("party.tab.recent", comment: "顶部 tab Recent") }
        static var languageAll: String { localize("party.language.all", comment: "语言 pill All 选项") }
        static var rankPartyRich: String { localize("party.rank.partyRich", comment: "PartyRich 榜卡文案") }
        static var rankRoom: String { localize("party.rank.room", comment: "Room 榜卡文案") }
        static var rankRulesTitle: String { localize("party.rank.rules.title", comment: "Party 榜单规则标题") }
        static var rankPartyRichRule1: String { localize("party.rank.partyRich.rule1", comment: "PartyRich 榜规则 1") }
        static var rankPartyRichRule2: String { localize("party.rank.partyRich.rule2", comment: "PartyRich 榜规则 2") }
        static var rankPartyRichRule3: String { localize("party.rank.partyRich.rule3", comment: "PartyRich 榜规则 3") }
        static var rankRoomRule1: String { localize("party.rank.room.rule1", comment: "Room 榜规则 1") }
        static var rankRoomRule2: String { localize("party.rank.room.rule2", comment: "Room 榜规则 2") }
        static var rankRoomRule3: String { localize("party.rank.room.rule3", comment: "Room 榜规则 3") }
        static var rankPeriodThisWeek: String { localize("party.rank.period.thisWeek", comment: "Party 榜当前周") }
        static var rankPeriodLastWeek: String { localize("party.rank.period.lastWeek", comment: "Party 榜上一周") }
        static var rankPeriodThisMonth: String { localize("party.rank.period.thisMonth", comment: "Party 榜当前月") }
        static var rankPeriodLastMonth: String { localize("party.rank.period.lastMonth", comment: "Party 榜上一月") }
        static var searchPlaceholder: String { localize("party.search.placeholder", comment: "搜索输入框占位") }
        static var searchHint: String { localize("party.search.hint", comment: "空 query 提示") }
        static var searchNoResults: String { localize("party.search.noResults", comment: "无搜索结果") }
        static var comingSoon: String { localize("party.comingSoon", comment: "占位 toast 文案 Coming soon") }
        static var myRoom: String { localize("party.myRoom", comment: "浮动按钮 My Room（已创房时展示）") }

        // 密码房前置弹窗（对齐 H5 index.vue L178-182 语义；主播端无充值/升级弹窗）
        static var passwordAlertTitle: String { localize("party.password.alert.title", comment: "密码框标题") }
        static var passwordAlertMessage: String { localize("party.password.alert.message", comment: "密码框说明") }
        static var passwordPlaceholder: String { localize("party.password.placeholder", comment: "密码输入 placeholder") }
        static var passwordConfirm: String { localize("party.password.confirm", comment: "密码框确认按钮") }
        static var passwordCancel: String { localize("party.password.cancel", comment: "密码框取消按钮") }
        // 进房 loading（对齐 H5 clickRoomItem 全屏 isSearchLoading）
        static var enteringRoom: String { localize("party.enteringRoom", comment: "进房过程 loading 文案") }

        // 创建房（PartyCreateRoomView v5 对齐 livechat-h5 用户端，2026-07-10）
        static var createNavTitle: String { localize("party.create.navTitle", comment: "Create My Room") }
        static var createSubmit: String { localize("party.create.submit", comment: "Create") }
        static var createConfirm: String { localize("party.create.confirm", comment: "Confirm（sheet 底部）") }
        static var createSectionName: String { localize("party.create.section.name", comment: "Room name") }
        static var createNamePlaceholder: String { localize("party.create.name.placeholder", comment: "房名 placeholder") }
        // v7.2：创房 disable Create 按钮时提示用户缺什么必填项
        static var createHintNeedName: String { localize("party.create.hint.needName", comment: "hint: enter room name") }
        static var createHintNeedTagline: String { localize("party.create.hint.needTagline", comment: "hint: enter tagline") }
        static var createHintNeedLanguage: String { localize("party.create.hint.needLanguage", comment: "hint: select language") }
        static var createHintNeedTemplate: String { localize("party.create.hint.needTemplate", comment: "hint: select template") }
        static var createHintNeedBackground: String { localize("party.create.hint.needBackground", comment: "hint: select background") }
        static var createSectionTagline: String { localize("party.create.section.tagline", comment: "Room Tagline") }
        static var createTaglinePlaceholder: String { localize("party.create.tagline.placeholder", comment: "tagline placeholder") }
        static var createSectionLanguage: String { localize("party.create.section.language", comment: "Room language") }
        static var createSectionMode: String { localize("party.create.section.mode", comment: "Room Mode") }
        static var createModeVoice: String { localize("party.create.mode.voice", comment: "Voice") }
        static var createModeLiveVoice: String { localize("party.create.mode.liveVoice", comment: "Live + Voice") }
        static var createModeLockFormat: String { localize("party.create.mode.lockFormat", comment: "Lv.%d Lock Mode") }
        static var createModeUnlockFormat: String { localize("party.create.mode.unlockFormat", comment: "Lv.%d Unlock Mode") }
        static var createModeLockedToastFormat: String { localize("party.create.mode.lockedToastFormat", comment: "Lv.%d required") }
        static var createSectionTemplate: String { localize("party.create.section.template", comment: "旧版 section 标题（保留兼容）") }
        // v7 对齐安卓 5 项 gap（2026-07-11）
        static var createSectionBackground: String { localize("party.create.section.background", comment: "Room Background section 标题") }
        static var createBgPermanent: String { localize("party.create.bg.permanent", comment: "永久背景标签") }
        static var createBgEmpty: String { localize("party.create.bg.empty", comment: "背景列表空态") }
        static var createPermissionDenied: String { localize("party.create.permissionDenied", comment: "创房权限被拒 toast") }
        // F 期 Live↔Party 互斥（对齐安卓 isLiveing||isPartying toast，2026-07-17）
        static var mutexBlockedByLive: String { localize("party.mutex.blockedByLive", comment: "直播中拦截进派对房") }
        static var mutexBlockedByParty: String { localize("party.mutex.blockedByParty", comment: "派对房中拦截开播") }
        // v8 设置功能（房主派对房设置 + 房管管理，2026-07-13）
        static var settingsNavTitle: String { localize("party.settings.navTitle", comment: "Room Settings") }
        static var settingsChangeAvatar: String { localize("party.settings.changeAvatar", comment: "更换头像 a11y") }
        static var settingsSectionAdmin: String { localize("party.settings.section.admin", comment: "Admin section 标题") }
        static var settingsManageAdmins: String { localize("party.settings.manageAdmins", comment: "Manage Admins entry") }
        static var settingsAdminEmpty: String { localize("party.settings.admin.empty", comment: "无房管空态") }
        static var settingsAdminAdd: String { localize("party.settings.admin.add", comment: "Add") }
        static var settingsAdminRemove: String { localize("party.settings.admin.remove", comment: "撤销房管 a11y") }
        static var settingsAdminAddTitle: String { localize("party.settings.admin.addTitle", comment: "Add Admin sheet 标题") }
        static var settingsAdminAddHint: String { localize("party.settings.admin.addHint", comment: "Add Admin 提示") }
        static var settingsAdminUserIdPlaceholder: String { localize("party.settings.admin.userIdPlaceholder", comment: "User ID input placeholder") }
        // v8.1 Room Tools sheet（对齐 H5 room-mana-popup.vue，2026-07-13）
        static var settingsToolsTitle: String { localize("party.tools.title", comment: "Room Tools sheet 标题") }
        static var toolLockRoom: String { localize("party.tool.lockRoom", comment: "Lock Room") }
        static var toolMusic: String { localize("party.tool.music", comment: "Music") }
        static var musicTitle: String { localize("party.music.title", comment: "Music management") }
        static var musicPlaylist: String { localize("party.music.playlist", comment: "System music playlist") }
        static var musicLocal: String { localize("party.music.local", comment: "Local music") }
        static var musicLiked: String { localize("party.music.liked", comment: "Liked music") }
        static var musicEmpty: String { localize("party.music.empty", comment: "No music available") }
        static var musicEdit: String { localize("party.music.edit", comment: "Edit local music") }
        static var musicUpload: String { localize("party.music.upload", comment: "Upload local music") }
        static var musicDelete: String { localize("party.music.delete", comment: "Delete local music") }
        static var musicSelectAll: String { localize("party.music.selectAll", comment: "Select all local music") }
        static var musicInvalidFormat: String { localize("party.music.invalidFormat", comment: "Invalid audio format") }
        static var musicFileTooLarge: String { localize("party.music.fileTooLarge", comment: "Audio file exceeds 10MB") }
        static var musicUploadSucceeded: String { localize("party.music.uploadSucceeded", comment: "Music upload succeeded") }
        static var musicUploadFailed: String { localize("party.music.uploadFailed", comment: "Music upload failed") }
        static var musicDeleteSucceeded: String { localize("party.music.deleteSucceeded", comment: "Music delete succeeded") }
        static var musicDeleteFailed: String { localize("party.music.deleteFailed", comment: "Music delete failed") }
        static var toolSettings: String { localize("party.tool.settings", comment: "Settings") }
        static var toolMicApplication: String { localize("party.tool.micApplication", comment: "Mic Application") }
        static var toolRoomMode: String { localize("party.tool.roomMode", comment: "Room Mode") }
        static var toolBlocklist: String { localize("party.tool.blocklist", comment: "Blocklist") }
        static var toolMCSeat: String { localize("party.tool.mcSeat", comment: "MC Seat") }
        static var toolPrivateCall: String { localize("party.tool.privateCall", comment: "Private Call") }
        static var toolCurrencyExchange: String { localize("party.tool.currencyExchange", comment: "Room currency exchange") }
        static var currencyExchangeTitle: String { localize("party.currency.exchangeTitle", comment: "Room currency exchange page title") }
        static var currencyBalanceTitle: String { localize("party.currency.balanceTitle", comment: "Currency balance section title") }
        static var currencyGems: String { localize("party.currency.gems", comment: "Gems currency name") }
        static var currencyDiamonds: String { localize("party.currency.diamonds", comment: "Diamonds currency name") }
        static var currencyCoins: String { localize("party.currency.coins", comment: "Coins currency name") }
        static var currencyTarget: String { localize("party.currency.target", comment: "Exchange target label") }
        static var currencyAvailable: String { localize("party.currency.available", comment: "Available balance label") }
        static var currencyAmountPlaceholder: String { localize("party.currency.amountPlaceholder", comment: "Exchange amount placeholder") }
        static var currencyAll: String { localize("party.currency.all", comment: "Fill all button") }
        static var currencyDiamondRate: String { localize("party.currency.diamondRate", comment: "Gem to diamond exchange rate") }
        static var currencyCoinRateHint: String { localize("party.currency.coinRateHint", comment: "Coin exchange settlement hint") }
        static var currencyExchangeAction: String { localize("party.currency.exchangeAction", comment: "Exchange action") }
        static var currencyRefresh: String { localize("party.currency.refresh", comment: "Refresh currency balance") }
        static var currencyBalanceLoadFailed: String { localize("party.currency.balanceLoadFailed", comment: "Currency balance failed state") }
        static var currencyInvalidAmount: String { localize("party.currency.invalidAmount", comment: "Invalid exchange amount") }
        static var currencyInsufficientBalance: String { localize("party.currency.insufficientBalance", comment: "Insufficient gems") }
        static var currencyDiamondExchangeSuccessFormat: String { localize("party.currency.diamondExchangeSuccessFormat", comment: "Gem to diamond exchange success, parameter: amount") }
        static var currencyCoinExchangeSuccess: String { localize("party.currency.coinExchangeSuccess", comment: "Gem to coin exchange success") }
        static var currencyExchangeFailed: String { localize("party.currency.exchangeFailed", comment: "Currency exchange failed") }
        static var currencyRecord: String { localize("party.currency.record", comment: "Currency change records") }
        static var currencyLoadMore: String { localize("party.currency.loadMore", comment: "Load more currency records") }
        static var currencyRecordEmpty: String { localize("party.currency.recordEmpty", comment: "No currency records") }
        static var currencyRecordLoadFailed: String { localize("party.currency.recordLoadFailed", comment: "Currency records failed to load") }
        static var currencyExplainTitle: String { localize("party.currency.explainTitle", comment: "Gems explanation heading") }
        static var currencyGemHowToGet: String { localize("party.currency.gemHowToGet", comment: "How to get Gems heading") }
        static var currencyGemHowToGetDetail: String { localize("party.currency.gemHowToGetDetail", comment: "How to get Gems detail") }
        static var currencyGemUse: String { localize("party.currency.gemUse", comment: "Gems use heading") }
        static var currencyGemUseCoinDetail: String { localize("party.currency.gemUseCoinDetail", comment: "Gems exchange to coins note") }
        static var currencyGemUseDiamondDetail: String { localize("party.currency.gemUseDiamondDetail", comment: "Gems exchange to diamonds note") }
        /// F-spec 关闭态弹 gift panel 时的 confirm 按钮标签："Open private call"
        static var privateCallOpenConfirmLabel: String { localize("party.privateCall.openConfirmLabel", comment: "关闭态选礼物 confirm 按钮：Open private call") }
        static var toolComingSoon: String { localize("party.tool.comingSoon", comment: "stub 项 toast") }
        // F-spec §5.1 PartyPrivateCallSettingSheet
        static var privateCallSettingTitle: String { localize("party.privateCall.settingTitle", comment: "私 call 设置 sheet 标题") }
        static var privateCallEnableToggleTitle: String { localize("party.privateCall.enableToggleTitle", comment: "允许接受私 call 开关标签") }
        static var privateCallGiftSectionTitle: String { localize("party.privateCall.giftSectionTitle", comment: "选择通话礼物区标题") }
        static var privateCallGiftEmpty: String { localize("party.privateCall.giftEmpty", comment: "礼物列表空态") }
        static var privateCallLoadError: String { localize("party.privateCall.loadError", comment: "礼物列表加载失败错态") }
        static var privateCallSaveSuccess: String { localize("party.privateCall.saveSuccess", comment: "设置保存成功 toast") }
        static var privateCallSaveFailed: String { localize("party.privateCall.saveFailed", comment: "设置保存失败 banner") }
        static var privateCallSeatBubble: String { localize("party.privateCall.seatBubble", comment: "麦位 Party Call 中提示") }
        static var moreMenuMinimize: String { localize("party.moreMenu.minimize", comment: "Party 房间最小化菜单") }
        static var bannerScoreDouble: String { localize("party.banner.scoreDouble", comment: "Party 活动翻倍火苗文案") }
        // 派对房 Blocklist（E spec 2026-07-14；房主/管理员查看+解除房间维度黑名单）
        static var blocklistNavTitle: String { localize("party.blocklist.navTitle", comment: "Blocklist 页面标题") }
        static var blocklistEmpty: String { localize("party.blocklist.empty", comment: "无黑名单空态") }
        static var blocklistLoadError: String { localize("party.blocklist.loadError", comment: "加载失败错态 banner") }
        static var blocklistLoadErrorFormat: String { localize("party.blocklist.loadErrorFormat", comment: "加载失败错态 banner 带 message，参数：message") }
        static var blocklistRemoveConfirmTitle: String { localize("party.blocklist.removeConfirmTitle", comment: "移除二次确认弹窗标题") }
        static var blocklistRemoveConfirmMessage: String { localize("party.blocklist.removeConfirmMessage", comment: "移除二次确认弹窗正文") }
        static var blocklistRemoveSuccess: String { localize("party.blocklist.removeSuccess", comment: "移除成功 toast") }
        static var blocklistRemoveFailed: String { localize("party.blocklist.removeFailed", comment: "移除失败 toast（与 H5 差异化，H5 无差别提示成功）") }
        static var blocklistBanTypePermanent: String { localize("party.blocklist.banTypePermanent", comment: "永久封禁标签") }
        static var blocklistAutoUnbanFormat: String { localize("party.blocklist.autoUnbanFormat", comment: "限时封禁倒计时前缀，参数：剩余时间字符串（如 12:34）") }
        // 派对房加锁/解锁（E spec 2026-07-14；4 位数字密码，加锁弹 sheet；解锁直接调 API 不弹）
        static var lockRoomSheetTitle: String { localize("party.lockRoom.sheetTitle", comment: "加锁 sheet 标题 Lock Room") }
        static var lockRoomSheetDescription: String { localize("party.lockRoom.sheetDescription", comment: "加锁 sheet 副标题：设置 4 位数字密码") }
        static var lockRoomPasswordPlaceholder: String { localize("party.lockRoom.passwordPlaceholder", comment: "SecureField placeholder：输 4 位数字密码") }
        static var lockRoomLockAction: String { localize("party.lockRoom.lockAction", comment: "sheet 底部主按钮 Lock") }
        static var lockRoomPasswordInvalid: String { localize("party.lockRoom.passwordInvalid", comment: "前端校验错误：密码需为 4 位数字（disable 按钮的错误状态；本次实现按钮 disable 兜底不显示）") }
        static var lockRoomLockSuccess: String { localize("party.lockRoom.lockSuccess", comment: "加锁成功 toast · Room locked") }
        static var lockRoomUnlockSuccess: String { localize("party.lockRoom.unlockSuccess", comment: "解锁成功 toast · Room unlocked") }
        static var lockRoomOperationFailed: String { localize("party.lockRoom.operationFailed", comment: "加解锁 API 失败通用兜底 toast") }
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
        static var inviteExpiresFormat: String { localize("party.invite.expiresFormat", comment: "视频位邀请剩余秒数") }
        static var seatInviteTitle: String { localize("party.seatInvite.title", comment: "空麦位邀请面板标题") }
        static var seatInviteEmpty: String { localize("party.seatInvite.empty", comment: "空麦位邀请面板空态") }
        static var seatInviteJoined: String { localize("party.seatInvite.joined", comment: "推荐用户已在麦状态") }
        static var seatInviteInviting: String { localize("party.seatInvite.inviting", comment: "视频位邀请中状态") }
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
        static var seatMuted: String { localize("party.seat.muted", comment: "被禁麦/自身关麦 a11y") }

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

        // MARK: - E spec §3 Room Mode（模板切换）
        static var roomModeSheetTitle: String { localize("party.roomMode.sheetTitle", comment: "Room Mode sheet 标题") }
        static var roomModeLiveAndVoiceTab: String { localize("party.roomMode.liveAndVoiceTab", comment: "Room Mode Live+Voice tab") }
        static var roomModeVoiceOnlyTab: String { localize("party.roomMode.voiceOnlyTab", comment: "Room Mode Voice-only tab") }
        static var roomModeConfirmTitle: String { localize("party.roomMode.confirmTitle", comment: "Room Mode 切换二次确认标题") }
        static var roomModeConfirmBody: String { localize("party.roomMode.confirmBody", comment: "Room Mode 切换二次确认正文（所有用户会下麦）") }
        static var roomModeConfirmSwitch: String { localize("party.roomMode.confirmSwitch", comment: "Room Mode 确认切换按钮") }
        static var roomModeConfirmCancel: String { localize("party.roomMode.confirmCancel", comment: "Room Mode 取消切换按钮") }
        /// %d = 需要达到的等级
        static var roomModeUpgradeGuideFormat: String { localize("party.roomMode.upgradeGuide", comment: "Room Mode 等级不足引导文案") }
        static var roomModeSystemMsg: String { localize("party.roomMode.systemMsg", comment: "Room Mode 切换后公屏系统消息") }
        static var roomModeEmptyState: String { localize("party.roomMode.emptyState", comment: "Room Mode 空态") }
        static var roomModeLoadError: String { localize("party.roomMode.loadError", comment: "Room Mode 模板加载失败") }

        // MARK: - E spec §3 Mic Application（申请上麦）
        static var micApplicationSheetTitle: String { localize("party.micApplication.sheetTitle", comment: "申请上麦列表 sheet 标题") }
        /// %d = 服务端权威申请人数；对齐 H5 `people apply`
        static var micApplicationPeopleApplyFormat: String { localize("party.micApplication.peopleApplyFormat", comment: "申请人数，%d people apply") }
        static var micApplicationEmptyState: String { localize("party.micApplication.emptyState", comment: "申请上麦列表空态") }
        static var micApplicationApprove: String { localize("party.micApplication.approve", comment: "申请上麦-同意按钮") }
        static var micApplicationReject: String { localize("party.micApplication.reject", comment: "申请上麦-拒绝按钮") }
        static var micApplicationNoSeatAvailable: String { localize("party.micApplication.noSeatAvailable", comment: "同意时无空位 toast") }
        static var micApplicationRejectedCooldown: String { localize("party.micApplication.rejectedCooldown", comment: "被拒后冷却期再申请 toast") }
        static var micApplicationRejectedByHost: String { localize("party.micApplication.rejectedByHost", comment: "申请人被房主拒绝 toast") }
        static var micApplicationTimeoutAutoGiveUp: String { localize("party.micApplication.timeoutAutoGiveUp", comment: "申请超时自动放弃 toast") }
        static var micApplicationSwitchOnTitle: String { localize("party.micApplication.switchOnTitle", comment: "开启 Mic Application 确认标题") }
        static var micApplicationSwitchOffTitle: String { localize("party.micApplication.switchOffTitle", comment: "关闭 Mic Application 确认标题") }
        static var micApplicationSwitchOnBody: String { localize("party.micApplication.switchOnBody", comment: "开启 Mic Application 确认正文") }
        static var micApplicationSwitchOffBody: String { localize("party.micApplication.switchOffBody", comment: "关闭 Mic Application 确认正文") }
        static var micApplicationSwitchOnSystemMsg: String { localize("party.micApplication.switchOnSystemMsg", comment: "开启 Mic Application 公屏系统消息") }
        static var micApplicationSwitchOffSystemMsg: String { localize("party.micApplication.switchOffSystemMsg", comment: "关闭 Mic Application 公屏系统消息") }
        /// 观众视角底部 CTA：排队中 → 放弃申请（对齐安卓 tvConfirm "放弃申请"）
        static var micApplicationCancel: String { localize("party.micApplication.cancel", comment: "观众放弃申请 CTA") }
        /// 观众视角底部 CTA 未排队提示：请先点击空麦位提交申请
        static var micApplicationTapEmptySeatHint: String { localize("party.micApplication.tapEmptySeatHint", comment: "观众视角未排队 CTA 提示") }
        /// 观众视角底部 CTA：tap 空位打开 Sheet 后手动点击提交申请（对齐安卓 tvConfirm "申请上麦"）
        static var micApplicationSubmit: String { localize("party.micApplication.submit", comment: "观众提交申请 CTA") }
        static var deleteMessage: String { localize("party.deleteMessage", comment: "删除 Party 公屏消息操作") }
        static var deleteMessageConfirm: String { localize("party.deleteMessageConfirm", comment: "删除 Party 公屏消息确认") }
        static var messageDeleted: String { localize("party.messageDeleted", comment: "Party 公屏消息删除成功") }
        static var deleteMessageFailed: String { localize("party.deleteMessageFailed", comment: "Party 公屏消息删除失败") }
        /// 批准申请-选座 sheet 标题（对齐安卓 SeatRosterDialog(isAgreeOnSeatMode=true)）
        static var approveSeatPickerTitle: String { localize("party.approveSeatPicker.title", comment: "批准申请-选座 sheet 标题") }
        /// 批准申请-选座 sheet 副标题格式（%@ = 申请人昵称）
        static var approveSeatPickerSubtitleFormat: String { localize("party.approveSeatPicker.subtitleFormat", comment: "批准申请-选座 sheet 副标题") }
        /// 选座 row 座位号格式（%d = seatIndex）
        static var approveSeatPickerSeatNumberFormat: String { localize("party.approveSeatPicker.seatNumberFormat", comment: "选座 row 座位号") }
        /// 语音座标签
        static var approveSeatPickerVoiceSeat: String { localize("party.approveSeatPicker.voiceSeat", comment: "语音座标签") }
        /// 视频座标签
        static var approveSeatPickerVideoSeat: String { localize("party.approveSeatPicker.videoSeat", comment: "视频座标签") }

        // MARK: - E spec §3 MC Seat（接待位 · 2026-07-14）
        static var mcSeatSheetTitle: String { localize("party.mcSeat.sheetTitle", comment: "MC Seat 选择 sheet 标题") }
        static var mcSeatSubmit: String { localize("party.mcSeat.submit", comment: "MC Seat 底部 CTA · Set MC Seat") }
        static var mcSeatTips: String { localize("party.mcSeat.tips", comment: "MC Seat 提示：仅房主/管理员可占接待位") }
        static var mcSeatBadge: String { localize("party.mcSeat.badge", comment: "麦位 cell MC 徽章文案") }
        static var mcSeatCannotTake: String { localize("party.mcSeat.cannotTake", comment: "普通用户点击 MC 位时的提示") }
        static var mcSeatChange: String { localize("party.mcSeat.change", comment: "空 MC 位管理菜单入口") }
        static var mcSeatConfirmEmpty: String { localize("party.mcSeat.confirmEmpty", comment: "二次确认 · 空位") }
        /// %@ = 用户昵称
        static var mcSeatConfirmPrivilegedFormat: String { localize("party.mcSeat.confirmPrivilegedFormat", comment: "二次确认 · 特权用户（OWNER/ADMIN）") }
        /// %@ = 用户昵称
        static var mcSeatConfirmNormalFormat: String { localize("party.mcSeat.confirmNormalFormat", comment: "二次确认 · 普通用户（会被赶下麦）") }
        static var mcSeatSetSuccess: String { localize("party.mcSeat.setSuccess", comment: "设置成功 toast") }
        static var mcSeatCloseSuccess: String { localize("party.mcSeat.closeSuccess", comment: "取消 MC 成功 toast") }
        static var mcSeatOperationFailed: String { localize("party.mcSeat.operationFailed", comment: "API 失败通用兜底 toast") }

        // MARK: - v3（2026-07-15）Step 2 通知公屏系统消息 · 对齐 H5 chat-list.vue 系统消息文案
        /// 1047 视频位邀请被接受公屏文案（%@ = 被邀请者昵称）
        static var videoSeatInviteAcceptedFormat: String { localize("party.videoSeat.inviteAcceptedFormat", comment: "1047 视频位邀请接受公屏（%@ 昵称）") }
        static var videoSeatInviteRejected: String { localize("party.videoSeat.feedbackReject", comment: "1042 视频位邀请被拒绝") }
        static var videoSeatInviteTimeout: String { localize("party.videoSeat.feedbackTimeout", comment: "1043 视频位邀请超时") }
        static var videoSeatInviteLeave: String { localize("party.videoSeat.feedbackLeave", comment: "1044 被邀请用户离房") }
        static var videoSeatInviteOccupied: String { localize("party.videoSeat.feedbackOccupied", comment: "1045 视频位已被占用") }
        static var videoSeatInviteAlreadyOn: String { localize("party.videoSeat.feedbackAlreadyOn", comment: "1046 用户已经在麦位") }
        static var videoSeatInviteJoinFailed: String { localize("party.videoSeat.feedbackJoinFailed", comment: "1048 接受邀请后上麦失败") }
        /// 1019 本人被设为房管提示
        static var authUpdateSetAdmin: String { localize("party.authUpdate.setAdmin", comment: "1019 本人被设为房管公屏") }
        /// 1019 本人被取消房管提示
        static var authUpdateRemoveAdmin: String { localize("party.authUpdate.removeAdmin", comment: "1019 本人被取消房管公屏") }
        /// 1019 设置房管公屏（%@ = 被操作用户昵称）
        static var authUpdateSetAdminFormat: String { localize("party.authUpdate.setAdminFormat", comment: "1019 设置房管公屏（%@ 昵称）") }
        /// 1019 取消房管公屏（%@ = 被操作用户昵称）
        static var authUpdateRemoveAdminFormat: String { localize("party.authUpdate.removeAdminFormat", comment: "1019 取消房管公屏（%@ 昵称）") }
        /// 1049 房间通告公屏（%@ = 公告文本）
        static var roomAnnouncementFormat: String { localize("party.roomAnnouncement.format", comment: "1049 房间通告公屏（%@）") }
        /// 1050 幸运数字抽数公屏（%1$@ = 昵称 · %2$d = 数字）
        static var luckyNumberDrawFormat: String { localize("party.luckyNumber.drawFormat", comment: "1050 幸运数字抽数（%1$@ 昵称 · %2$d 数字）") }
        /// 1051 幸运数字中奖公屏（%1$@ = 昵称 · %2$d = 数字）
        static var luckyNumberWinFormat: String { localize("party.luckyNumber.winFormat", comment: "1051 幸运数字中奖（%1$@ 昵称 · %2$d 数字）") }
        /// 1051 公屏第二行文案
        static var luckyNumberMatched: String { localize("party.luckyNumber.matched", comment: "1051 幸运数字匹配成功") }
        /// 1052 中奖个人弹窗兜底文案（%d = 幸运数字）
        static var luckyNumberPersonalWinFormat: String { localize("party.luckyNumber.personalWinFormat", comment: "1052 幸运数字中奖个人弹窗") }

        // MARK: - Battle Team（对齐 H5 party.battle）
        enum Battle {
            static var team: String { localize("party.battle.team", comment: "Battle Team") }
            static var countdown: String { localize("party.battle.countdown", comment: "Countdown") }
            static var start: String { localize("party.battle.start", comment: "START") }
            static var none: String { localize("party.battle.none", comment: "None") }
            static var live: String { localize("party.battle.live", comment: "Live") }
            static var redTeam: String { localize("party.battle.redTeam", comment: "Red Team") }
            static var blueTeam: String { localize("party.battle.blueTeam", comment: "Blue Team") }
            static var redTeamWin: String { localize("party.battle.redTeamWin", comment: "Red Team Win") }
            static var blueTeamWin: String { localize("party.battle.blueTeamWin", comment: "Blue Team Win") }
            static var tie: String { localize("party.battle.tie", comment: "Tie") }
            static var leading: String { localize("party.battle.leading", comment: "Leading") }
            static var iKnow: String { localize("party.battle.iKnow", comment: "I Know") }
            static var cancel: String { localize("party.battle.cancel", comment: "Cancel") }
            static var confirm: String { localize("party.battle.confirm", comment: "Confirm") }
            static var rulesTitle: String { localize("party.battle.rulesTitle", comment: "Battle Team Rules") }
            static var rule1: String { localize("party.battle.rule1", comment: "Battle rule 1") }
            static var rule2: String { localize("party.battle.rule2", comment: "Battle rule 2") }
            static var rule3: String { localize("party.battle.rule3", comment: "Battle rule 3") }
            static var rule4: String { localize("party.battle.rule4", comment: "Battle rule 4") }
            static var forceEndTitle: String { localize("party.battle.forceEndTitle", comment: "Force end title") }
            static var forceEndDesc: String { localize("party.battle.forceEndDesc", comment: "Force end description") }
            static func forceEndWill(_ team: String) -> String { String(format: localize("party.battle.forceEndWillFormat", comment: "%@ = team"), team) }
            static var forceEndTied: String { localize("party.battle.forceEndTied", comment: "Force end tied") }
            static var cooldownDesc: String { localize("party.battle.cooldownDesc", comment: "Cooldown description") }
            static var cooldownAction: String { localize("party.battle.cooldownAction", comment: "Cooldown action") }
            static var giftTabRed: String { localize("party.battle.giftTabRed", comment: "Red") }
            static var giftTabBlue: String { localize("party.battle.giftTabBlue", comment: "Blue") }
            static var initiateTitle: String { localize("party.battle.initiateTitle", comment: "Initiate Battle Team") }
            static var modeLabel: String { localize("party.battle.modeLabel", comment: "Mode") }
            static var modeTeamBattle: String { localize("party.battle.modeTeamBattle", comment: "Team Battle (Red vs. Blue)") }
            static var timeLabel: String { localize("party.battle.timeLabel", comment: "Time") }
            static func minutes(_ value: Int) -> String { String(format: localize("party.battle.minutesFormat", comment: "%d = minutes"), value) }
            static var chooseSideLabel: String { localize("party.battle.chooseSideLabel", comment: "Choosing my side") }
            static var joinSideOn: String { localize("party.battle.joinSideOn", comment: "Join") }
            static var joinSideOff: String { localize("party.battle.joinSideOff", comment: "Neutral") }
            static var joinRed: String { localize("party.battle.joinRed", comment: "Join Red") }
            static var joinBlue: String { localize("party.battle.joinBlue", comment: "Join Blue") }
            static func initiateHint(players: Int, cooldown: Int) -> String { String(format: localize("party.battle.initiateHintFormat", comment: "%1$d = players, %2$d = cooldown"), players, cooldown) }
            static func initiateHint2(selecting: Int) -> String { String(format: localize("party.battle.initiateHint2Format", comment: "%d = selecting seconds"), selecting) }
            static var selectingHostTitle: String { localize("party.battle.selectingHostTitle", comment: "60s countdown or click START") }
            static var battleTime: String { localize("party.battle.battleTime", comment: "Battle Time") }
            static func lead(_ value: Int) -> String { String(format: localize("party.battle.leadFormat", comment: "%d = score delta"), value) }
            static var lose: String { localize("party.battle.lose", comment: "Lose") }
            static var giftGivingMvp: String { localize("party.battle.giftGivingMvp", comment: "Gift-Giving MVP") }
            static var giftReceiveMvp: String { localize("party.battle.giftReceiveMvp", comment: "Gift-Receive MVP") }
            static func totalGivenOut(_ value: String) -> String { String(format: localize("party.battle.totalGivenOutFormat", comment: "%@ = value"), value) }
            static func personalGiftReceiving(_ value: String) -> String { String(format: localize("party.battle.personalGiftReceivingFormat", comment: "%@ = value"), value) }
            static var roomIdInvalid: String { localize("party.battle.roomIdInvalid", comment: "Room ID invalid") }
            static var noTemplate: String { localize("party.battle.noTemplate", comment: "No template available") }
            static var alreadyEnded: String { localize("party.battle.alreadyEnded", comment: "PK already ended") }
            static var startNowFailed: String { localize("party.battle.startNowFailed", comment: "Failed to start") }
            static func chatSelectingStart(_ minutes: Int) -> String { String(format: localize("party.battle.chatSelectingStartFormat", comment: "%d = minutes"), minutes) }
            static func chatTeamWin(_ team: String) -> String { String(format: localize("party.battle.chatTeamWinFormat", comment: "%@ = team"), team) }
            static var chatTie: String { localize("party.battle.chatTie", comment: "This is a draw!") }
            static var chatForceEnd: String { localize("party.battle.chatForceEnd", comment: "The room ended this PK early") }
            static func chatMvp(name: String, team: String) -> String { String(format: localize("party.battle.chatMvpFormat", comment: "%1$@ = name, %2$@ = team"), name, team) }
        }
    }

    // MARK: - PartyRoom 房间内 UI（AnchorBar / ChatTabStrip / InputBar 使用）
    enum PartyRoom {
        // 顶部房主条（PartyRoomAnchorBar）
        static var idFormat: String { localize("partyRoom.idFormat", comment: "房间 ID 显示格式 ID:%@") }
        static var welcomeFallback: String { localize("partyRoom.welcomeFallback", comment: "欢迎语 fallback") }
        static var a11yFollow: String { localize("partyRoom.a11y.follow", comment: "关注按钮 a11y") }
        static var a11yFollowing: String { localize("partyRoom.a11y.following", comment: "已关注按钮 a11y") }
        static var a11yAnnouncement: String { localize("partyRoom.a11y.announcement", comment: "公告图标 a11y") }
        static var a11yShare: String { localize("partyRoom.a11y.share", comment: "分享图标 a11y") }
        static var a11yManagement: String { localize("partyRoom.a11y.management", comment: "管理图标 a11y") }
        static var a11yMore: String { localize("partyRoom.a11y.more", comment: "更多图标 a11y") }
        static var a11yHeat: String { localize("partyRoom.a11y.heat", comment: "热度 a11y") }
        static var a11yViewers: String { localize("partyRoom.a11y.viewers", comment: "观众 a11y") }
        // v11：顶部统计条榜单入口（对齐 H5 header-wrap.vue wealthRank/honorRank 分档）
        static var a11yWealthRank: String { localize("partyRoom.a11y.wealthRank", comment: "财富榜入口 a11y") }
        static var a11yHonorRank: String { localize("partyRoom.a11y.honorRank", comment: "荣耀榜入口 a11y") }
        // v12：PK 入口 a11y
        static var a11yPk: String { localize("partyRoom.a11y.pk", comment: "PK 入口 a11y") }

        // 顶栏 Rank / Viewers sheet（对齐 H5 room-rank.vue）
        static var rankTabContribution: String { localize("partyRoom.rank.tab.contribution", comment: "榜单主 tab · 贡献") }
        static var rankTabHonor: String { localize("partyRoom.rank.tab.honor", comment: "榜单主 tab · 荣誉") }
        static var rankTabGameTask: String { localize("partyRoom.rank.tab.gameTask", comment: "榜单主 tab · 游戏任务激励") }
        static var rankTabDaily: String { localize("partyRoom.rank.tab.daily", comment: "榜单周期 tab · 日榜") }
        static var rankPeriodToday: String { localize("partyRoom.rank.period.today", comment: "日榜当前周期") }
        static var rankPeriodYesterday: String { localize("partyRoom.rank.period.yesterday", comment: "日榜上一周期") }
        static var rankViewersTitle: String { localize("partyRoom.rank.viewersTitle", comment: "观众列表 sheet 标题") }
        static var rankEmptyRank: String { localize("partyRoom.rank.emptyRank", comment: "榜单空态") }
        static var rankEmptyViewers: String { localize("partyRoom.rank.emptyViewers", comment: "观众列表空态") }
        static var weeklyTaskTitle: String { localize("partyRoom.weeklyTask.title", comment: "派对房主播周任务标题") }
        static var weeklyTaskLiveTime: String { localize("partyRoom.weeklyTask.liveTime", comment: "累计上麦时长标签") }
        static var weeklyTaskEmpty: String { localize("partyRoom.weeklyTask.empty", comment: "周任务空态") }
        static var weeklyTaskLoadMore: String { localize("partyRoom.weeklyTask.loadMore", comment: "周任务加载更多") }
        static var weeklyTaskRewardTitle: String { localize("partyRoom.weeklyTask.reward.title", comment: "周任务奖励弹窗标题") }
        static var weeklyTaskRewardConfirm: String { localize("partyRoom.weeklyTask.reward.confirm", comment: "周任务奖励确认按钮") }
        static var weeklyTaskRewardFallback: String { localize("partyRoom.weeklyTask.reward.fallback", comment: "周任务未知奖励名称兜底") }
        static var weeklyTaskGiftHistory: String { localize("partyRoom.weeklyTask.giftHistory", comment: "周任务礼物流水标题") }
        static var weeklyTaskReward: String { localize("partyRoom.weeklyTask.reward", comment: "周任务奖励标签") }
        static var a11yWeeklyTask: String { localize("partyRoom.a11y.weeklyTask", comment: "主播周任务入口 a11y") }
        static var hotTaskTitle: String { localize("partyRoom.hotTask.title", comment: "热门房任务标题") }
        static var hotTaskMissionRules: String { localize("partyRoom.hotTask.missionRules", comment: "热门任务规则弹窗标题") }
        static var hotTaskHowToReward: String { localize("partyRoom.hotTask.howToReward", comment: "热门任务获取奖励标题") }
        static var hotTaskHowToRewardDetail: String { localize("partyRoom.hotTask.howToRewardDetail", comment: "热门任务获取奖励说明") }
        static var hotTaskHowToRewardDetailFormat: String { localize("partyRoom.hotTask.howToRewardDetailFormat", comment: "热门任务获取奖励说明，含 TopX") }
        static var hotTaskMicTime: String { localize("partyRoom.hotTask.micTime", comment: "热门任务累计麦时标题") }
        static var hotTaskMicTimeDetail: String { localize("partyRoom.hotTask.micTimeDetail", comment: "热门任务累计麦时说明") }
        static var hotTaskGiftsOnMic: String { localize("partyRoom.hotTask.giftsOnMic", comment: "热门任务麦上收礼标题") }
        static var hotTaskGiftsOnMicDetail: String { localize("partyRoom.hotTask.giftsOnMicDetail", comment: "热门任务麦上收礼说明") }
        static var hotTaskGems: String { localize("partyRoom.hotTask.gems", comment: "热门任务宝石奖励名称") }
        static var hotTaskFrame: String { localize("partyRoom.hotTask.frame", comment: "热门任务头像框奖励名称") }
        static var hotTaskNotes: String { localize("partyRoom.hotTask.notes", comment: "热门任务说明标题") }
        static var hotTaskNotesDetail: String { localize("partyRoom.hotTask.notesDetail", comment: "热门任务说明") }
        static var hotTaskOutOfTop: String { localize("partyRoom.hotTask.outOfTop", comment: "热门房掉榜提示") }
        static var hotTaskOutOfTopFormat: String { localize("partyRoom.hotTask.outOfTopFormat", comment: "热门房掉榜提示，含 TopX") }
        static var hotTaskRewardTitle: String { localize("partyRoom.hotTask.rewardTitle", comment: "热门任务达标奖励标题") }
        static var hotTaskClaim: String { localize("partyRoom.hotTask.claim", comment: "热门任务领奖按钮") }
        static var hotTaskValidHours: String { localize("partyRoom.hotTask.validHours", comment: "热门任务头像框有效时长") }
        static var hotTaskFaceWarning: String { localize("partyRoom.hotTask.faceWarning", comment: "热门任务露脸检测失败提示") }
        static var hotTaskFaceLimitWarning: String { localize("partyRoom.hotTask.faceLimitWarning", comment: "热门任务露脸检测达到上限提示") }
        static var hotRoomGuideTitle: String { localize("partyRoom.hotRoomGuide.title", comment: "热门房引导标题") }
        static var hotRoomGuideAction: String { localize("partyRoom.hotRoomGuide.action", comment: "热门房引导确认按钮") }
        static var hotRoomGuideMessage: String { localize("partyRoom.hotRoomGuide.message", comment: "热门房引导说明") }
        static var hotRoomGuideStay: String { localize("partyRoom.hotRoomGuide.stay", comment: "热门房引导留下按钮") }
        static var hotRoomGuideJumpTop: String { localize("partyRoom.hotRoomGuide.jumpTop", comment: "热门房引导跳转按钮") }
        static var topRoomBonusEnterTitle: String { localize("partyRoom.topRoomBonus.enter.title", comment: "热门房奖励列表引导标题") }
        static var topRoomBonusEnterSubtitleFormat: String { localize("partyRoom.topRoomBonus.enter.subtitleFormat", comment: "热门房奖励列表引导副标题，含 TopX") }
        static var topRoomBonusEnterFormat: String { localize("partyRoom.topRoomBonus.enter.format", comment: "热门房奖励列表进入按钮，含 TopX") }
        static var topRoomBonusOutTitleFormat: String { localize("partyRoom.topRoomBonus.out.titleFormat", comment: "热门房掉榜弹窗标题，含 TopX") }
        static var topRoomBonusOutMessage: String { localize("partyRoom.topRoomBonus.out.message", comment: "热门房掉榜弹窗副标题") }
        static var topRoomBonusJumpFormat: String { localize("partyRoom.topRoomBonus.out.jumpFormat", comment: "热门房掉榜跳转按钮，含 TopX") }
        static var superWheelTitle: String { localize("partyRoom.superWheel.title", comment: "Super Winner 标题") }
        static var superWheelUnavailable: String { localize("partyRoom.superWheel.unavailable", comment: "Super Winner 不可用提示") }
        static var superWheelOpen: String { localize("partyRoom.superWheel.open", comment: "Super Winner 开局按钮") }
        static var superWheelJoin: String { localize("partyRoom.superWheel.join", comment: "Super Winner 加入按钮") }
        static var superWheelBet: String { localize("partyRoom.superWheel.bet", comment: "Super Winner 下注按钮") }
        static var superWheelClose: String { localize("partyRoom.superWheel.close", comment: "Super Winner 关闭按钮") }
        static var superWheelPool: String { localize("partyRoom.superWheel.pool", comment: "Super Winner 奖池标签") }
        static var superWheelPlayer: String { localize("partyRoom.superWheel.player", comment: "Super Winner 默认玩家名") }
        static var superWheelWaiting: String { localize("partyRoom.superWheel.waiting", comment: "Super Winner 等待阶段") }
        static var superWheelSignup: String { localize("partyRoom.superWheel.signup", comment: "Super Winner 报名阶段") }
        static var superWheelPreparing: String { localize("partyRoom.superWheel.preparing", comment: "Super Winner 准备阶段") }
        static var superWheelBetting: String { localize("partyRoom.superWheel.betting", comment: "Super Winner 下注阶段") }
        static var superWheelSpinning: String { localize("partyRoom.superWheel.spinning", comment: "Super Winner 转盘阶段") }
        static var superWheelRoundResult: String { localize("partyRoom.superWheel.roundResult", comment: "Super Winner 单轮结果阶段") }
        static var superWheelFinalResult: String { localize("partyRoom.superWheel.finalResult", comment: "Super Winner 终局阶段") }
        static var superWheelOutFormat: String { localize("partyRoom.superWheel.outFormat", comment: "Super Winner 淘汰提示，%@ = 昵称") }
        static var superWheelWinnerFormat: String { localize("partyRoom.superWheel.winnerFormat", comment: "Super Winner 获胜提示，%@ = 昵称，%lld = 奖励") }
        static var superWheelActionFailed: String { localize("partyRoom.superWheel.actionFailed", comment: "Super Winner 操作失败提示") }
        static var superWheelGetReady: String { localize("partyRoom.superWheel.getReady", comment: "Super Winner 准备阶段提示") }
        static var superWheelJoined: String { localize("partyRoom.superWheel.joined", comment: "Super Winner 已报名") }
        static var superWheelSpectating: String { localize("partyRoom.superWheel.spectating", comment: "Super Winner 观战提示") }
        static var superWheelWinningRatio: String { localize("partyRoom.superWheel.winningRatio", comment: "Super Winner 胜率标签") }
        static var superWheelNextRound: String { localize("partyRoom.superWheel.nextRound", comment: "Super Winner 淘汰后下一轮提示") }
        static var superWheelRewardHint: String { localize("partyRoom.superWheel.rewardHint", comment: "Super Winner 开局奖励说明") }

        // 公屏 tab strip（PartyRoomChatTabStrip）
        static var tabAll: String { localize("partyRoom.tab.all", comment: "公屏 tab All") }
        static var tabChat: String { localize("partyRoom.tab.chat", comment: "公屏 tab Chat") }
        static var tabGift: String { localize("partyRoom.tab.gift", comment: "公屏 tab Gift") }

        // 底部输入栏（PartyRoomInputBar）
        static var inputPlaceholder: String { localize("partyRoom.input.placeholder", comment: "聊天输入 placeholder") }
        static var a11yEmoji: String { localize("partyRoom.a11y.emoji", comment: "表情按钮 a11y") }

        // F 里程碑（2026-07-17）表情面板
        static var emojiLoadFailed: String { localize("partyRoom.emoji.loadFailed", comment: "表情面板加载失败") }
        static var emojiRetry: String { localize("partyRoom.emoji.retry", comment: "表情面板加载失败 retry 按钮") }
        static var emojiPlayError: String { localize("partyRoom.emoji.playError", comment: "玩法表情 resultImages 空时 toast") }
        static var emojiOnSeatRequired: String { localize("partyRoom.emoji.onSeatRequired", comment: "未上麦时 tap 玩法表情 toast") }
        static var a11ySpeakerOn: String { localize("partyRoom.a11y.speaker.on", comment: "扬声器已开 a11y") }
        static var a11ySpeakerOff: String { localize("partyRoom.a11y.speaker.off", comment: "扬声器已关 a11y") }
        static var a11yMicOn: String { localize("partyRoom.a11y.mic.on", comment: "麦克风已开 a11y") }
        static var a11yMicOff: String { localize("partyRoom.a11y.mic.off", comment: "麦克风已关 a11y") }
        static var a11yGame: String { localize("partyRoom.a11y.game", comment: "游戏按钮 a11y") }
        static var a11yGift: String { localize("partyRoom.a11y.gift", comment: "礼物按钮 a11y") }

        // v9：业务逻辑补齐相关文案
        static var announcementTitle: String { localize("partyRoom.announcement.title", comment: "公告 sheet 标题") }
        static var announcementEmpty: String { localize("partyRoom.announcement.empty", comment: "公告空态文案") }
        static var announcementClose: String { localize("partyRoom.announcement.close", comment: "公告 sheet 关闭按钮") }
        // F 期房主管理批（2026-07-17）房主编辑通告
        static var announcementEdit: String { localize("partyRoom.announcement.edit", comment: "公告 sheet 房主编辑入口") }
        static var announcementSave: String { localize("partyRoom.announcement.save", comment: "公告编辑保存按钮") }
        static var announcementCancel: String { localize("partyRoom.announcement.cancel", comment: "公告编辑取消按钮") }
        static var announcementPlaceholder: String { localize("partyRoom.announcement.placeholder", comment: "公告编辑输入 placeholder") }
        static var announcementSaveSuccess: String { localize("partyRoom.announcement.saveSuccess", comment: "公告保存成功 toast") }
        static var announcementSaveFailed: String { localize("partyRoom.announcement.saveFailed", comment: "公告保存失败 toast") }
        static var moreMenuTitle: String { localize("partyRoom.more.title", comment: "更多菜单标题") }
        static var moreMenuLeave: String { localize("partyRoom.more.leave", comment: "更多菜单：退出房间") }

        // v12 底部工具栏（对齐 H5 用户端 footer-wrap.vue 新增 apply/message/toolMenu）
        static var a11yApply: String { localize("partyRoom.a11y.apply", comment: "排麦按钮 a11y") }
        static var a11yMessage: String { localize("partyRoom.a11y.message", comment: "消息按钮 a11y") }
        static var a11yToolMenu: String { localize("partyRoom.a11y.toolMenu", comment: "更多工具菜单 a11y") }
        static var applyDialogTitle: String { localize("partyRoom.apply.dialog.title", comment: "排麦 dialog 标题") }
        static var applyConfirm: String { localize("partyRoom.apply.confirm", comment: "排麦 dialog 确认按钮") }
        static var toolMenuTitle: String { localize("partyRoom.toolMenu.title", comment: "更多工具菜单标题") }
        static var toolMenuStartPk: String { localize("partyRoom.toolMenu.startPk", comment: "工具菜单：发起 PK") }
        static var toolMenuLuckyNumber: String { localize("partyRoom.toolMenu.luckyNumber", comment: "工具菜单：幸运数字") }
        static var toolMenuRoomMute: String { localize("partyRoom.toolMenu.roomMute", comment: "工具菜单：房间静音（未静音态显示 Mute Room）") }
        // F 期便利功能（2026-07-17）Room Mute toggle 状态化文案
        static var toolMenuRoomMuteOn: String { localize("partyRoom.toolMenu.roomMute.on", comment: "开启静音 button label（当前未静音）") }
        static var toolMenuRoomMuteOff: String { localize("partyRoom.toolMenu.roomMute.off", comment: "关闭静音 button label（当前已静音）") }
        // H5 party-tool-menu.vue / lucky-number-panel.vue
        static var toolMenuInteractiveGames: String { localize("partyRoom.toolMenu.interactiveGames", comment: "Tools：互动玩法标题") }
        static var toolMenuBasicTools: String { localize("partyRoom.toolMenu.basicTools", comment: "Tools：基础工具标题") }
        static var toolMenuPk: String { localize("partyRoom.toolMenu.pk", comment: "Tools：PK") }
        static var toolMenuFree: String { localize("partyRoom.toolMenu.free", comment: "Tools：免费") }
        static var toolMenuSettings: String { localize("partyRoom.toolMenu.settings", comment: "幸运数字设置入口") }
        static var toolMenuLuckyNumberSent: String { localize("partyRoom.toolMenu.luckyNumberSent", comment: "幸运数字已发送 toast") }
        static var toolMenuRange: String { localize("partyRoom.toolMenu.range", comment: "幸运数字范围") }
        static var toolMenuSetLuckyNumber: String { localize("partyRoom.toolMenu.setLuckyNumber", comment: "设置幸运数字开关") }
        static var toolMenuAllowAdmins: String { localize("partyRoom.toolMenu.allowAdmins", comment: "允许房管设置幸运数字") }
        static var toolMenuSave: String { localize("partyRoom.toolMenu.save", comment: "保存") }
        static var toolMenuInvalidLuckyNumber: String { localize("partyRoom.toolMenu.invalidLuckyNumber", comment: "幸运数字输入校验") }
        static var toolMenuLuckyNumberSaved: String { localize("partyRoom.toolMenu.luckyNumberSaved", comment: "幸运数字保存成功 toast") }
        static var toolMenuHistory: String { localize("partyRoom.toolMenu.history", comment: "幸运数字历史") }
        static var toolMenuHistoryHint: String { localize("partyRoom.toolMenu.historyHint", comment: "幸运数字历史说明") }
        static var toolMenuNoHistory: String { localize("partyRoom.toolMenu.noHistory", comment: "幸运数字无历史") }
        static var toolMenuLoadMore: String { localize("partyRoom.toolMenu.loadMore", comment: "加载更多") }
        // F 期便利功能（2026-07-17）ShareLink 深链分享文案
        static var shareMessageFormat: String { localize("partyRoom.share.messageFormat", comment: "站外分享文案 %@ = 房间深链 URL") }

        // v15：麦位点击分流（对齐 H5 joinOrOutMic 4 分支）
        static var seatLockedToast: String { localize("partyRoom.seat.locked", comment: "锁麦位 toast：The seat is locked") }
        static var videoSeatNeedsInviteToast: String { localize("partyRoom.seat.videoNeedsInvite", comment: "视频位需邀请 toast") }
        static var switchSeatTitle: String { localize("partyRoom.switchSeat.title", comment: "切麦确认弹窗标题") }
        static var switchSeatConfirm: String { localize("partyRoom.switchSeat.confirm", comment: "切麦确认按钮") }

        // v15：房主/房管空位管理动作（对齐 H5 my-mic-tool.vue 简化版）
        static var adminSeatActionsTitle: String { localize("partyRoom.adminSeat.title", comment: "空位管理动作标题") }
        static var adminActionTake: String { localize("partyRoom.adminSeat.take", comment: "上麦按钮") }
        static var adminActionSwitchHere: String { localize("partyRoom.adminSeat.switchHere", comment: "切到此麦位") }
        static var adminActionLock: String { localize("partyRoom.adminSeat.lock", comment: "锁麦位按钮") }
        static var adminActionUnlock: String { localize("partyRoom.adminSeat.unlock", comment: "解锁麦位按钮") }
    }

    // MARK: - Work 工作台（设计稿还原）
    static var workWeeklyLevel: String { localize("work.weeklyLevel", comment: "周等级") }
    static var workDetail: String { localize("work.detail", comment: "详情") }
    static var workScorePrefix: String { localize("work.scorePrefix", comment: "分数前缀") }
    static var workNeedMoreFormat: String { localize("work.needMoreFormat", comment: "升级还需 %d 分") }

    // MARK: - Data Statistics（Work 顶部 Detail，对齐 H5 views/dataStatistics）
    static var dataStatisticsNavTitle: String { localize("dataStatistics.navTitle", comment: "数据统计页标题") }
    static var dataStatisticsBannerSubtitle: String { localize("dataStatistics.bannerSubtitle", comment: "数据统计页横幅副标题") }
    static var dataStatisticsTotalDislikeRate: String { localize("dataStatistics.totalDislikeRate", comment: "总差评率") }
    static var dataStatisticsOffsetDislike: String { localize("dataStatistics.offsetDislike", comment: "抵扣差评入口") }
    static var dataStatisticsRemoveDislike: String { localize("dataStatistics.removeDislike", comment: "移除差评弹窗标题") }
    static var dataStatisticsRemoveDislikeDescription: String { localize("dataStatistics.removeDislikeDescription", comment: "移除差评说明") }
    static var dataStatisticsDislikeRate: String { localize("dataStatistics.dislikeRate", comment: "差评率") }
    static var dataStatisticsDislikeRateDescription: String { localize("dataStatistics.dislikeRateDescription", comment: "差评率说明") }
    static var dataStatisticsLikes: String { localize("dataStatistics.likes", comment: "好评") }
    static var dataStatisticsDislikes: String { localize("dataStatistics.dislikes", comment: "差评") }
    static var dataStatisticsPrivateAndLiveOnly: String { localize("dataStatistics.privateAndLiveOnly", comment: "仅计算私聊和直播通话") }
    static var dataStatisticsCategory: String { localize("dataStatistics.category", comment: "类别") }
    static var dataStatisticsWeek: String { localize("dataStatistics.week", comment: "本周") }
    static var dataStatisticsLevelAnswerRate: String { localize("dataStatistics.levelAnswerRate", comment: "等级接通率") }
    static var dataStatisticsLevelAvgDuration: String { localize("dataStatistics.levelAvgDuration", comment: "等级平均时长") }
    static var dataStatisticsLevelCalls: String { localize("dataStatistics.levelCalls", comment: "等级通话数") }
    static var dataStatisticsLevelUpdateTime: String { localize("dataStatistics.levelUpdateTime", comment: "等级更新时间") }
    static var dataStatisticsCurrentLevelBenefits: String { localize("dataStatistics.currentLevelBenefits", comment: "当前等级权益") }
    static var dataStatisticsCurrentPoints: String { localize("dataStatistics.currentPoints", comment: "当前积分") }
    static var dataStatisticsRemainingChancesFormat: String { localize("dataStatistics.remainingChancesFormat", comment: "剩余抵扣次数 %@") }
    static var dataStatisticsOffset: String { localize("dataStatistics.offset", comment: "抵扣按钮") }
    static var dataStatisticsDeductionSucceeded: String { localize("dataStatistics.deductionSucceeded", comment: "抵扣成功 toast") }
    static var dataStatisticsDeductionUnavailable: String { localize("dataStatistics.deductionUnavailable", comment: "无法抵扣 toast") }

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

    static var workCallsToday: String { localize("work.callsToday", comment: "今日通话数") }
    static var workCoins: String { localize("work.coins", comment: "Coins") }
    static var workDiamonds: String { localize("work.diamonds", comment: "钻石") }
    static var workGems: String { localize("work.gems", comment: "Gems") }

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
    static var toolGoLive: String { localize("work.tool.goLive", comment: "开播") }
    static var toolMatch: String { localize("work.tool.match", comment: "匹配") }
    static var toolTask: String { localize("work.tool.task", comment: "任务") }
    static var toolBeauty: String { localize("work.tool.beauty", comment: "美颜") }
    static var toolPoints: String { localize("work.tool.points", comment: "积分") }
    static var toolGiftMessage: String { localize("work.tool.giftMessage", comment: "礼物消息") }
    static var toolProfileUpdate: String { localize("work.tool.profileUpdate", comment: "资料更新") }
    static var toolInvite: String { localize("work.tool.invite", comment: "邀请") }
    static var toolWorkingGuide: String { localize("work.tool.workingGuide", comment: "工作指南") }
    static var toolProps: String { localize("work.tool.props", comment: "道具（H · Props 虚拟道具入口）") }
    static var toolLiveData: String { localize("work.tool.liveData", comment: "直播数据") }
    static var toolPartyData: String { localize("work.tool.partyData", comment: "派对数据") }
    static var toolMyGuardian: String { localize("work.tool.myGuardian", comment: "我的守护") }
    static var toolStarUser: String { localize("work.tool.starUser", comment: "Star User") }

    // MARK: - Task Center 页(Phase C · 对齐 H5 views/task/index.vue)
    static var taskCenterNavTitle: String { localize("task.center.navTitle", comment: "任务中心标题") }
    static var taskRankProgress: String { localize("task.section.rankProgress", comment: "排位进度小节标题") }
    static var taskProgress: String { localize("task.section.taskProgress", comment: "任务进度小节标题") }
    static var taskCycleDaily: String { localize("task.cycle.daily", comment: "Daily tab") }
    static var taskCycleWeekly: String { localize("task.cycle.weekly", comment: "Weekly tab") }
    static var taskCountdownPrefix: String { localize("task.countdown.prefix", comment: "重置倒计时前缀 (Reset in)") }
    static var taskWeeklyTotalPointsLabel: String { localize("task.weekly.totalPoints", comment: "Weekly Total Points 标签") }
    static var taskLegacyLimitedTime: String { localize("task.legacy.limitedTime", comment: "旧版日任务限时分组标题") }
    static var taskLegacyAllDay: String { localize("task.legacy.allDay", comment: "旧版日任务全天分组标题") }
    static var taskLegacyMatchTipTitle: String { localize("task.legacy.matchTip.title", comment: "旧版匹配任务提示标题") }
    static var taskLegacyMatchTipMessage: String { localize("task.legacy.matchTip.message", comment: "旧版匹配任务提示内容") }
    static var taskMyIncome: String { localize("task.myIncome", comment: "我方收入") }
    static var taskMyIntegral: String { localize("task.myIntegral", comment: "我方积分") }
    static var taskViewRank: String { localize("task.viewRank", comment: "查看榜单") }
    static var taskGlobalIncome: String { localize("task.rankLabel.globalIncome", comment: "Rank 卡左奖杯 label") }
    static var taskPoints: String { localize("task.rankLabel.points", comment: "Rank 卡右勋章 label") }
    static var taskResetPrefix: String { localize("task.reset.prefix", comment: "Task Reset:") }
    static var taskDaysFormat: String { localize("task.daysFormat", comment: "%d days") }
    static var taskGo: String { localize("task.go", comment: "Go 按钮(引导去完成)") }
    static var taskTierClaim: String { localize("task.tier.claim", comment: "领取按钮") }
    static var taskTierClaimed: String { localize("task.tier.claimed", comment: "已领取按钮") }
    static var taskClaimAll: String { localize("task.claimAll", comment: "一键领取按钮") }
    static var taskClaimSuccess: String { localize("task.claim.success", comment: "领取成功") }
    static var taskClaimGrantPending: String { localize("task.claim.grantPending", comment: "领奖发放中") }
    static var taskClaimAllMultiTypeFormat: String { localize("task.claim.allMultiTypeFormat", comment: "领取成功 x%d 档(多类型混合)") }
    static var taskRewardGotIt: String { localize("task.reward.gotIt", comment: "领奖弹窗知道了") }
    static var taskRewardMergedPrefix: String { localize("task.reward.mergedPrefix", comment: "合计前缀(合并同类奖励)") }
    static var taskActiveTycoonTask: String { localize("task.active.tycoonTask", comment: "大R任务折叠区标题") }
    static var taskIntegralTask: String { localize("task.integralTask", comment: "积分任务折叠区标题") }

    // Task 领奖弹窗 rewardType 描述(对齐 H5 REWARD_DESC_KEY 1-6)
    static var taskRewardDiamond: String { localize("task.reward.diamond", comment: "1=钻石") }
    static var taskRewardGem: String { localize("task.reward.gem", comment: "2=宝石") }
    static var taskRewardProp: String { localize("task.reward.prop", comment: "3=道具") }
    static var taskRewardMount: String { localize("task.reward.mount", comment: "4=座驾") }
    static var taskRewardFrame: String { localize("task.reward.frame", comment: "5=头像框") }
    static var taskRewardPoints: String { localize("task.reward.points", comment: "6=积分") }
    static var taskModuleNoTasks: String { localize("task.module.noTasks", comment: "Module 空态") }
    static var commonOK: String { localize("common.OK", comment: "OK 按钮通用文案") }

    // Points Rank(Phase E · 对齐 H5 views/pointsRank/index.vue)
    static var pointsRankNavTitle: String { localize("points.rank.navTitle", comment: "积分榜标题") }
    static var pointsMyPoints: String { localize("points.myPoints", comment: "我方积分 label") }
    static var pointsRankSubtitle: String { localize("points.rank.subtitle", comment: "榜单说明") }
    static var pointsRankRulesTitle: String { localize("points.rank.rules.title", comment: "规则标题") }
    static var pointsRankRulesContent1: String { localize("points.rank.rules.content1", comment: "规则条目 1") }
    static var pointsRankRulesContent2: String { localize("points.rank.rules.content2", comment: "规则条目 2") }
    static var pointsRankRulesContent3: String { localize("points.rank.rules.content3", comment: "规则条目 3") }
    static var pointsRankRulesContent4: String { localize("points.rank.rules.content4", comment: "规则条目 4") }

    // LiveData 规则 sheet(对齐 H5 liveRule/index.vue 默认分支)
    static var liveDataRuleNavTitle: String { localize("liveData.rule.navTitle", comment: "规则标题") }
    static var liveDataRuleSection1: String { localize("liveData.rule.section1", comment: "I. 基本信息") }
    static var liveDataRuleSection2: String { localize("liveData.rule.section2", comment: "II. 数据更新与统计周期") }
    static var liveDataRuleSection3: String { localize("liveData.rule.section3", comment: "III. 收益计算规则") }
    static var liveDataRuleSection4: String { localize("liveData.rule.section4", comment: "IV. 异常处理") }
    static var liveDataRuleCalcMethod: String { localize("liveData.rule.calcMethod", comment: "计算方式") }
    static var liveDataRuleTitle1: String { localize("liveData.rule.title1", comment: "规则子标题 1") }
    static var liveDataRuleTitle2: String { localize("liveData.rule.title2", comment: "规则子标题 2") }
    static var liveDataRuleTitle3: String { localize("liveData.rule.title3", comment: "规则子标题 3") }
    static var liveDataRuleTitle4: String { localize("liveData.rule.title4", comment: "规则子标题 4") }
    static var liveDataRuleTitle7: String { localize("liveData.rule.title7", comment: "规则子标题 7") }
    static var liveDataRuleTitle8: String { localize("liveData.rule.title8", comment: "规则子标题 8") }
    static var liveDataRuleContent1: String { localize("liveData.rule.content1", comment: "规则内容 1") }
    static var liveDataRuleContent2: String { localize("liveData.rule.content2", comment: "规则内容 2") }
    static var liveDataRuleContent3: String { localize("liveData.rule.content3", comment: "规则内容 3") }
    static var liveDataRuleContent4: String { localize("liveData.rule.content4", comment: "规则内容 4") }
    static var liveDataRuleContent5: String { localize("liveData.rule.content5", comment: "规则内容 5") }
    static var liveDataRuleContent7: String { localize("liveData.rule.content7", comment: "规则内容 7") }
    static var liveDataRuleContent8: String { localize("liveData.rule.content8", comment: "规则内容 8") }

    // Work 底部 sysInfo 组件(对齐 H5 work/sysInfo.vue)
    static var systemServerTime: String { localize("system.serverTime", comment: "服务器时间") }
    static var contactOfficialWhatsapp: String { localize("contact.officialWhatsapp", comment: "官方 WhatsApp: %@") }
    static var commonCopySuccess: String { localize("common.copySuccess", comment: "复制成功") }
    static var toolNewbie: String { localize("work.tool.newbie", comment: "新手") }

    // Invite 角标（H5 style: 金红渐变 "Earn Money"）
    static var inviteEarnMoney: String { localize("work.invite.earnMoney", comment: "邀请赚钱角标") }

    // 下线确认弹窗（对齐 H5 onlineStatus.*）
    static var offlineConfirmMessage: String { localize("work.offline.confirmMessage", comment: "确认下线？") }
    static var offlineConfirmYes: String { localize("work.offline.confirmYes", comment: "确认下线") }
    static var offlineConfirmNo: String { localize("work.offline.confirmNo", comment: "取消下线") }

    // 底部 tab 标签
    static var tabHome: String { localize("tab.home", comment: "首页") }
    static var tabMessages: String { localize("tab.messages", comment: "消息") }
    static var tabParty: String { localize("tab.party", comment: "派对") }
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

    // MARK: - 首页全站榜（对齐 H5 /rank）
    static var homeRankTitle: String { localize("home.rank.title", comment: "首页榜单标题") }
    static var homeRankCharm: String { localize("home.rank.charm", comment: "魅力榜") }
    static var homeRankWealth: String { localize("home.rank.wealth", comment: "财富榜") }
    static var homeRankCouple: String { localize("home.rank.couple", comment: "CP 榜") }
    static var homeRankDay: String { localize("home.rank.day", comment: "日榜") }
    static var homeRankWeek: String { localize("home.rank.week", comment: "周榜") }
    static var homeRankMonth: String { localize("home.rank.month", comment: "月榜") }
    static var homeRankRules: String { localize("home.rank.rules", comment: "榜单规则") }
    static var homeRankRulesText: String { localize("home.rank.rules.text", comment: "榜单规则说明") }
    static var homeRankCharmRulesText: String { localize("home.rank.rules.charm", comment: "魅力财富榜规则") }
    static var homeRankCoupleRulesText: String { localize("home.rank.rules.couple", comment: "CP 榜规则") }
    static var homeRankMyRanking: String { localize("home.rank.myRanking", comment: "我的排名") }
    static var homeRankNotRanked: String { localize("home.rank.notRanked", comment: "未上榜排名") }
    static var homeRankNoData: String { localize("home.rank.noData", comment: "榜单空态") }
    static var homeRankHostPlaceholder: String { localize("home.rank.hostPlaceholder", comment: "CP 榜主播占位名") }
    static var homeRankUserPlaceholder: String { localize("home.rank.userPlaceholder", comment: "CP 榜用户占位名") }
    static var homeRankMystery: String { localize("home.rank.mystery", comment: "CP 榜神秘用户") }
    static var homeRankNotOnListYet: String { localize("home.rank.notOnListYet", comment: "CP 榜未上榜提示") }
    static var homeRankKeepSendingGifts: String { localize("home.rank.keepSendingGifts", comment: "CP 榜未上榜副标题") }
    static func homeRankCpWeeklyRewardFormat(_ rank: Int) -> String {
        String(format: localize("home.rank.cpWeeklyRewardFormat", comment: "CP 周榜奖励标题"), rank)
    }

    // MARK: - Live 广场（H5 liveList.vue 对齐）
    /// 广场空态提示（当前没有主播在直播）
    static var liveStreamEmpty: String { localize("liveStream.empty", comment: "Live 广场空数据提示") }
    /// PK 中角标 a11y
    static var liveStreamInPK: String { localize("liveStream.inPK", comment: "PK 中角标 a11y") }
    /// Banner 通用 a11y（本次不接跳转，仅描述）
    static var liveBannerA11y: String { localize("live.banner.a11y", comment: "首页 banner a11y") }
    /// 跑马灯"sends out a super rocket"文案（H5 i18n key `gift.sends out a super rocket`）
    static var giftSendSuperRocket: String { localize("gift.sendSuperRocket", comment: "跑马灯：发送超级火箭") }
    /// 首礼浮层首行，保留 {name} / {streamer} / {gift} 标记供富样式渲染。
    static var liveGiftFirstGiftHeadline: String { localize("liveGift.firstGiftHeadline", comment: "首礼浮层首行") }
    static var liveGiftFirstGiftStreamer: String { localize("liveGift.firstGiftStreamer", comment: "首礼浮层主播占位") }
    static var liveGiftFirstGiftKick: String { localize("liveGift.firstGiftKick", comment: "首礼浮层第二行") }

    // MARK: - List 子页（设计稿还原）
    /// 顶部 Online/Prime 分段
    static var liveListSegmentOnline: String { localize("liveList.segment.online", comment: "Online 分段") }
    static var liveListSegmentPrime: String { localize("liveList.segment.prime", comment: "Prime 分段") }
    /// 卡片右侧动作按钮 a11y
    static var liveListActionChat: String { localize("liveList.action.chat", comment: "聊天按钮 a11y") }
    static var liveListActionLive: String { localize("liveList.action.live", comment: "直播按钮 a11y") }
    static var liveListActionMatch: String { localize("liveList.action.match", comment: "匹配按钮 a11y") }
    static var liveListActionOffline: String { localize("liveList.action.offline", comment: "下线开关 a11y") }
    static var liveListActionVideoCall: String { localize("liveList.action.videoCall", comment: "视频通话按钮 a11y") }
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
    /// 资料未填写简介时的 H5 完成度提示
    static var profileCompletionHint: String { localize("profile.completionHint", comment: "资料完成度提示") }
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
    /// 媒体预览图片加载失败文案（视频侧已有系统占位；图片新增）
    static var mediaPreviewImageLoadFailed: String { localize("mediaPreview.image.loadFailed", comment: "图片加载失败") }
    /// 媒体预览图片加载失败重试按钮
    static var mediaPreviewImageRetry: String { localize("mediaPreview.image.retry", comment: "图片加载重试按钮") }

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
    static var settingsConfirm: String         { localize("settings.confirm", comment: "确认") }
    static var settingsAnchorPolicy: String    { localize("settings.anchorPolicy", comment: "主播规范条目") }
    static var settingsClearCache: String      { localize("settings.clearCache", comment: "清除缓存条目") }
    static var settingsClearCacheConfirm: String { localize("settings.clearCacheConfirm", comment: "清除缓存二次确认") }
    static var settingsClearCacheDone: String  { localize("settings.clearCacheDone", comment: "清除缓存完成 toast") }
    static var settingsSelectLanguage: String  { localize("settings.selectLanguage", comment: "语言选择页标题") }
    static var settingsFeedbackComingSoon: String { localize("settings.feedbackComingSoon", comment: "反馈占位 toast（保留兼容，本轮已启用真反馈页）") }

    // MARK: - Feedback 反馈表单页
    static var feedbackTypeAppError: String     { localize("feedback.type.appError", comment: "App Error 类型") }
    static var feedbackTypeAccountError: String { localize("feedback.type.accountError", comment: "Account Error 类型") }
    static var feedbackTypeSuggestion: String   { localize("feedback.type.suggestion", comment: "Suggestion 类型") }
    static var feedbackTypeOther: String        { localize("feedback.type.other", comment: "Other 类型") }
    static var feedbackMessagePlaceholder: String { localize("feedback.messagePlaceholder", comment: "message textarea placeholder") }
    static var feedbackEmailPlaceholder: String { localize("feedback.emailPlaceholder", comment: "email 输入框 placeholder") }
    static var feedbackWrongEmail: String       { localize("feedback.wrongEmail", comment: "邮箱格式错误 toast") }
    static var feedbackSubmitSuccess: String    { localize("feedback.submitSuccess", comment: "提交成功 toast") }
    static var feedbackSubmitFailed: String     { localize("feedback.submitFailed", comment: "提交失败 toast") }

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
    static var messageNewsTitle: String         { localize("message.news.title", comment: "消息列表顶部大标题 News") }
    /// 顶部右 icon 清空当前 tab 会话确认对话框标题（对齐 H5 news/index.vue:showEmpty clearDialogTitle）
    static var messageClearTabTitle: String     { localize("message.clear.tabTitle", comment: "清空当前 tab 会话列表确认标题") }
    static var messageClearTabConfirm: String   { localize("message.clear.tabConfirm", comment: "清空当前 tab 确认按钮") }
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
    static var massTextingTitle: String         { localize("massTexting.title", comment: "群发弹窗标题") }
    static var massTextingContentTitle: String  { localize("massTexting.contentTitle", comment: "群发内容标题") }
    static var massTextingSendOneTap: String    { localize("massTexting.sendOneTap", comment: "一键群发按钮") }
    static var massTextingLoading: String       { localize("massTexting.loading", comment: "群发文案加载中") }
    static var massTextingRetry: String         { localize("massTexting.retry", comment: "群发加载失败重试") }
    static var massTextingSendSuccess: String   { localize("massTexting.sendSuccess", comment: "群发成功 toast") }
    static var massTextingDailyLimitReached: String { localize("massTexting.dailyLimitReached", comment: "今日群发次数已用完") }
    static var massTextingRefreshUnavailable: String { localize("massTexting.refreshUnavailable", comment: "群发文案库不可用") }
    static var massTextingSendFailed: String    { localize("massTexting.sendFailed", comment: "群发发送失败") }
    static var massTextingLoadFailed: String    { localize("massTexting.loadFailed", comment: "群发加载失败") }
    static var massTextingNoCopywriting: String { localize("massTexting.noCopywriting", comment: "群发暂无文案") }
    static var massTextingRefreshCopy: String   { localize("massTexting.refreshCopy", comment: "刷新群发文案") }
    static var massTextingHint: String          { localize("massTexting.hint", comment: "群发入口引导气泡") }
    static func massTextingRemainingFormat(_ count: Int) -> String {
        String(format: localize("massTexting.remainingFormat", comment: "今日剩余群发次数,%d=次数"), count)
    }

    // MARK: - Message 顶部系统消息 3 入口（H-1c v4）
    static var messageSystemInboxStation: String       { localize("message.systemInbox.station", comment: "Flame 顶部 Station 入口标题") }
    static var messageSystemInboxNotification: String  { localize("message.systemInbox.notification", comment: "Flame 顶部 Notification 入口标题") }
    static var messageSystemInboxAdmin: String         { localize("message.systemInbox.admin", comment: "Flame 顶部 Admin 客服入口标题") }
    static var messageSystemInboxComingSoon: String    { localize("message.systemInbox.comingSoon", comment: "3 入口详情页留 H-2 未开放 toast") }
    static var stationPopupRead: String                { localize("stationPopup.read", comment: "启动站内信已读状态") }
    static var stationPopupUnread: String              { localize("stationPopup.unread", comment: "启动站内信未读状态") }
    static var stationPopupAlreadyRead: String         { localize("stationPopup.alreadyRead", comment: "重复标记启动站内信已读 toast") }
    static var stationPopupExpirationDate: String      { localize("stationPopup.expirationDate", comment: "启动站内信到期日期标签") }

    // MARK: - Call Records（通话历史记录页，对齐 H5 views/communication/records/list.vue）
    static var callRecordListTitle: String     { localize("callRecord.list.title", comment: "通话历史页顶部标题") }
    static var callRecordEmpty: String         { localize("callRecord.empty", comment: "通话历史空态文案") }
    static var callRecordLoadingMore: String   { localize("callRecord.loadingMore", comment: "触底加载更多文案") }
    static var callRecordNoMoreData: String    { localize("callRecord.noMoreData", comment: "已加载完全部记录") }
    /// 来源标签：匹配 / 直播 / 私聊（对齐 H5 source() 三档 text）
    static var callRecordSourceMatch: String   { localize("callRecord.source.match", comment: "来源 · Match") }
    static var callRecordSourceLive: String    { localize("callRecord.source.live", comment: "来源 · Live") }
    static var callRecordSourcePrivate: String { localize("callRecord.source.private", comment: "来源 · Private") }
    /// 未接原因：Rejected / Timeout / Canceled（对齐 H5 missedReason() 三档）
    static var callRecordReasonRejected: String { localize("callRecord.reason.rejected", comment: "未接原因 · Rejected") }
    static var callRecordReasonTimeout: String  { localize("callRecord.reason.timeout", comment: "未接原因 · Timeout") }
    static var callRecordReasonCanceled: String { localize("callRecord.reason.canceled", comment: "未接原因 · Canceled") }
    /// a11y：未接来电语义标签
    static var callRecordA11yMissed: String     { localize("callRecord.a11y.missed", comment: "a11y 未接来电语义") }

    // MARK: - Batch 6.1 回复积分 4 tip 文案（H5 蓝本 en.json:820-821 + chat/index.vue:43-44 硬编码）
    static var chatGuideTip: String        { localize("chat.guideTip",       comment: "初次进入付费聊天页引导") }
    static var chatStimulateTip: String    { localize("chat.stimulateTip",   comment: "用户连发 ≥10 条付费消息激励主播") }
    static var chatReplyFastTip: String    { localize("chat.replyFastTip",   comment: "回复积分快速回复引导") }
    static var chatReplyRemindTip: String  { localize("chat.replyRemindTip", comment: "主播 15 分钟未回复提醒") }

    // 首次进入私聊页 2 步引导（H5 guidance.vue，对齐 chat.New feature/Learn more details）
    static var chatIntroStep1: String      { localize("chat.intro.step1",    comment: "第 1 步：宝箱条介绍") }
    static var chatIntroStep2: String      { localize("chat.intro.step2",    comment: "第 2 步：奖励记录按钮") }

    // 云端历史拉空后过期提示（对齐 H5 new.chat history expired）
    static var chatHistoryExpired: String  { localize("chat.historyExpired", comment: "云端历史拉空时的一次性 toast") }
    static var chatPrivatePermissionDisabled: String { localize("chat.private.permissionDisabled", comment: "私密消息权限关闭提示") }
    static var chatPrivateAuditing: String { localize("chat.private.auditing", comment: "私密媒体审核中提示") }
    static var chatPrivateRejected: String { localize("chat.private.rejected", comment: "私密媒体审核拒绝提示") }
    static var chatPrivateCreate: String { localize("chat.private.create", comment: "私密媒体创建入口") }
    static var chatPrivateGuide: String { localize("chat.private.guide", comment: "私密媒体首次引导") }

    // 对方消息气泡内可见"翻译"按钮（对齐 H5 msgItem.vue CTranslate label="Translate"）
    static var chatTranslate: String       { localize("chat.translate", comment: "文字气泡内翻译按钮 label") }

    // MARK: - Chat a11y accessibility labels（S-7,icon-only Button 补齐 VoiceOver 语义）
    static func chatA11yAudioPlay(sec: Int) -> String {
        String(format: localize("chat.a11y.audioPlay", comment: "语音气泡 a11y 播放 (%d 秒)"), sec)
    }
    static func chatA11yAudioPause(sec: Int) -> String {
        String(format: localize("chat.a11y.audioPause", comment: "语音气泡 a11y 暂停 (%d 秒)"), sec)
    }
    static var chatA11yResend: String    { localize("chat.a11y.resend", comment: "发送失败重发按钮 a11y") }
    static var chatA11yMediaImage: String { localize("chat.a11y.mediaImage", comment: "相册图片 cell a11y") }
    static var chatA11yMediaVideo: String { localize("chat.a11y.mediaVideo", comment: "相册视频 cell a11y") }

    // MARK: - ChatInputBar 输入栏文案（M-5,对齐 H5 chat/index.vue placeholder + 按钮）
    static var chatInputTypeMessage: String { localize("chat.input.typeMessage", comment: "输入框 placeholder") }
    static var chatInputHoldToTalk: String  { localize("chat.input.holdToTalk", comment: "语音按住说话按钮") }
    static var chatInputSend: String        { localize("chat.input.send", comment: "发送按钮") }

    // MARK: - DiaReceivePopup 钻石到账弹窗（M-6,对齐 H5 diamondGift 弹窗文案）
    static var diaReceiveCongratulations: String    { localize("dia.receive.congratulations", comment: "钻石弹窗标题") }
    static var diaReceiveUnlockedAchievement: String { localize("dia.receive.unlockedAchievement", comment: "钻石弹窗副标题") }
    static var diaReceiveGet: String                 { localize("dia.receive.get", comment: "领取按钮") }
    static var diaReceiveA11yGet: String             { localize("dia.receive.a11y.get", comment: "a11y 领钻石按钮") }
    /// 完整句子由 3 语言 strings 各自维护,%d 位置可在 ar/tr 里灵活调整对齐 RTL/复数语序
    static func diaReceiveReceivedDiamondsFormat(count: Int) -> String {
        String(format: localize("dia.receive.receivedDiamondsFormat", comment: "钻石到账文案,%d=数量"), count)
    }

    // MARK: - 系统通知会话文案（对齐 H5 systemMsg.vue + cpRankRewardMsg.vue）
    static var chatSystemComingSoon: String     { localize("chat.system.comingSoon", comment: "CP 榜 / View Now / click here 降级 toast") }
    static var chatSystemViewNow: String        { localize("chat.system.viewNow", comment: "虚拟道具 GET 通知里 View Now CTA") }
    static var chatSystemCheckCpRanking: String { localize("chat.system.checkCpRanking", comment: "CP 榜奖励卡片底部 Check Cp ranking CTA") }
    static var chatSystemAppealClickHere: String { localize("chat.system.appealClickHere", comment: "惩罚申诉气泡里可点击的 click here") }
    static var chatSystemAppealSuccess: String  { localize("chat.system.appealSuccess", comment: "申诉成功 toast") }
    static var chatSystemDurationPerm: String   { localize("chat.system.durationPerm", comment: "虚拟道具永久时长") }
    static var chatSystemItemTypeVehicle: String   { localize("chat.system.itemType.vehicle", comment: "") }
    static var chatSystemItemTypeFrame: String     { localize("chat.system.itemType.frame", comment: "") }
    static var chatSystemItemTypeEntrance: String  { localize("chat.system.itemType.entrance", comment: "") }
    static var chatSystemItemTypeChatSkin: String  { localize("chat.system.itemType.chatSkin", comment: "") }
    static var chatSystemItemTypeCardFrame: String { localize("chat.system.itemType.cardFrame", comment: "") }
    static func chatSystemItemGet(itemName: String, itemType: String, duration: String) -> String {
        String(format: localize("chat.system.itemGetFormat", comment: "虚拟道具收到通知,3 参数:名字/类型/时长"), itemName, itemType, duration)
    }
    static func chatSystemItemExpired(itemName: String, itemType: String) -> String {
        String(format: localize("chat.system.itemExpiredFormat", comment: "虚拟道具过期通知,2 参数:名字/类型"), itemName, itemType)
    }
    static func chatSystemDurationHourMinute(hour: Int, minute: Int) -> String {
        String(format: localize("chat.system.durationHourMinuteFormat", comment: "X hours Y minutes"), hour, minute)
    }
    static func chatSystemDurationHour(hour: Int) -> String {
        String(format: localize("chat.system.durationHourFormat", comment: "X hours"), hour)
    }
    static func chatSystemDurationMinute(minute: Int) -> String {
        String(format: localize("chat.system.durationMinuteFormat", comment: "X minutes"), minute)
    }
    static func chatSystemRewardDiamond(count: String) -> String {
        String(format: localize("chat.system.rewardDiamondFormat", comment: "钻石到账,1 参数:数量"), count)
    }
    static func chatSystemCpRankRewardMsg(rank: Int) -> String {
        String(format: localize("chat.system.cpRankRewardMsgFormat", comment: "CP 榜奖励主文案,1 参数:排名"), rank)
    }

    // 语音录制 <1s 提示（对齐 H5 recording.vue "Recording time is too short"）
    static var chatVoiceTooShort: String   { localize("chat.voice.tooShort", comment: "语音录制过短提示") }

    // 发送失败网络提示（对齐 H5 chat/index.vue "Oops, connection failed!"）
    static var chatSendNetworkError: String { localize("chat.sendNetworkError", comment: "发送消息网络失败提示") }

    // MARK: - Message 消息 preview 归一化（v5 F-3 i18n）
    static var messagePreviewImage: String          { localize("message.preview.image", comment: "会话预览：图片") }
    static var messagePreviewVoice: String          { localize("message.preview.voice", comment: "会话预览：语音") }
    static var messagePreviewVideo: String          { localize("message.preview.video", comment: "会话预览：视频") }
    static var messagePreviewLocation: String       { localize("message.preview.location", comment: "会话预览：位置") }
    static var messagePreviewGift: String           { localize("message.preview.gift", comment: "会话预览：礼物") }
    static var messagePreviewUnknown: String        { localize("message.preview.unknown", comment: "会话预览：未知消息") }
    // H-3 新增（私密媒体展示）
    static var messagePreviewPrivatePhoto: String   { localize("message.preview.privatePhoto", comment: "会话预览：私密图片") }
    static var messagePreviewPrivateVideo: String   { localize("message.preview.privateVideo", comment: "会话预览：私密视频") }

    // H-3 新增（私聊页 UI 文案，spec §6.5；ar/tr 走 en 兜底待产品补 Q9）
    static var chatRefusedTip: String               { localize("chat.refusedTip", comment: "被拒消息灰底整行 tip 文案") }

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
    /// 删除动态二次确认标题
    static var momentDeleteConfirmTitle: String    { localize("moment.delete.confirm.title", comment: "删除动态确认标题") }
    /// 删除动态确认按钮（destructive）
    static var momentDeleteConfirmAction: String   { localize("moment.delete.confirm.action", comment: "删除动态确认按钮") }
    /// 删除动态取消按钮
    static var momentDeleteConfirmCancel: String   { localize("moment.delete.confirm.cancel", comment: "删除动态取消按钮") }

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
    static var authForgetPassword: String { localize("auth.forgetPassword", comment: "Forget Password? 链接") }
    static var authTogglePasswordA11y: String { localize("auth.togglePasswordA11y", comment: "密码可见性切换按钮 a11y label") }

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
    /// H-4 公共礼物面板：Send 主按钮（派对房送礼场景；本轮 factory 声明未 wire）
    static var giftPickerSend: String { localize("giftPicker.send", comment: "派对房送礼 Send 按钮") }
    /// H-4 公共礼物面板：All 全选按钮（派对房受者头像行）
    static var giftPickerAll: String { localize("giftPicker.all", comment: "All 全选按钮") }
    /// H-5 派对房送礼：phase = insufficientBalance 时 "Recharge" 按钮
    static var giftPickerRecharge: String { localize("giftPicker.recharge", comment: "H-5 余额不足 Recharge 按钮 label") }
    /// H-5 派对房送礼：phase = insufficientBalance 时 tap Recharge 弹 toast（本轮无真充值页）
    static var giftPickerRechargeToast: String { localize("giftPicker.recharge.toast", comment: "H-5 Recharge tap toast · 充值功能开发中") }
    /// H-5 派对房送礼：sendGift 成功后 PartyRoomView 顶部 toast 反馈（对齐 H5 party-gift-popup.vue showNotify）
    static var giftPickerSentToast: String { localize("giftPicker.sent.toast", comment: "H-5 sendGift 成功 toast · Gift sent") }
    /// H-5 派对房送礼：麦上无收礼人时的空态占位（items 为空时 receiver row 显示）
    static var giftPickerRecipientsEmpty: String { localize("giftPicker.recipients.empty", comment: "H-5 麦上无收礼人空态占位") }

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
    static var wishSettingSubmitSuccessTitle: String { localize("wishSetting.submitSuccess.title", comment: "自由承诺审核成功标题") }
    static var wishSettingSubmitSuccessSubtitle: String { localize("wishSetting.submitSuccess.subtitle", comment: "自由承诺审核成功说明") }
    static var wishSettingSubmitSuccessReviewStatus: String { localize("wishSetting.submitSuccess.reviewStatus", comment: "自由承诺审核状态标签") }
    static var wishSettingSubmitSuccessPendingReview: String { localize("wishSetting.submitSuccess.pendingReview", comment: "自由承诺审核中状态") }
    static var wishSettingSubmitSuccessReviewTime: String { localize("wishSetting.submitSuccess.reviewTime", comment: "自由承诺审核时间标签") }
    static var wishSettingSubmitSuccessReviewTimeValue: String { localize("wishSetting.submitSuccess.reviewTimeValue", comment: "自由承诺审核时间") }
    static var wishSettingSubmitSuccessNotify: String { localize("wishSetting.submitSuccess.notify", comment: "自由承诺结果通知标签") }
    static var wishSettingSubmitSuccessNotifyValue: String { localize("wishSetting.submitSuccess.notifyValue", comment: "自由承诺结果通知方式") }
    static var wishSettingSubmitSuccessTip: String { localize("wishSetting.submitSuccess.tip", comment: "自由承诺审核成功提示") }
    static var wishSettingSubmitSuccessGoToWishlist: String { localize("wishSetting.submitSuccess.goToWishlist", comment: "自由承诺审核记录入口") }
    // P0-1 分层校验 toast + P1-2 保存成功 toast（对齐 H5 index.vue:351-397）
    static var wishSettingPleaseAgreeRule: String { localize("wishSetting.pleaseAgreeRule", comment: "未勾选合规规范") }
    static var wishSettingPleaseAddGift: String { localize("wishSetting.pleaseAddGift", comment: "未添加心愿礼物") }
    static var wishSettingPleasePickTemplate: String { localize("wishSetting.pleasePickTemplate", comment: "Common 未选模板") }
    static var wishSettingPleasePickPrivate: String { localize("wishSetting.pleasePickPrivate", comment: "Private 未选文案") }
    static var wishSettingSaved: String { localize("wishSetting.saved", comment: "保存成功 toast") }
    // v2 设计稿对齐补充
    static var wishSettingReviewStatus: String { localize("wishSetting.reviewStatus", comment: "Review status 卡标题") }
    static var wishSettingReviewStatusIntro: String { localize("wishSetting.reviewStatusIntro", comment: "Review status 副标题") }
    static var wishSettingAuditRecords: String { localize("wishSetting.auditRecords", comment: "承诺审核记录标题") }
    static var wishSettingAuditAll: String { localize("wishSetting.audit.all", comment: "审核记录全部筛选") }
    static var wishSettingAuditPending: String { localize("wishSetting.audit.pending", comment: "审核中筛选与状态") }
    static var wishSettingAuditApproved: String { localize("wishSetting.audit.approved", comment: "审核通过筛选与状态") }
    static var wishSettingAuditRejected: String { localize("wishSetting.audit.rejected", comment: "审核拒绝筛选与状态") }
    static var wishSettingAuditEmpty: String { localize("wishSetting.audit.empty", comment: "审核记录空态") }
    static var wishSettingAuditRejectReason: String { localize("wishSetting.audit.rejectReason", comment: "审核拒绝原因") }
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
    /// 关注成功 toast（对齐 H5 CFollowButton 关注后弹 vant showToast）
    static var liveResultFollowSuccess: String { localize("liveResult.followSuccess", comment: "关注成功 toast") }

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

    // MARK: LiveRoom 顶部互动转盘（对齐 H5 liveRoomTop.vue rouletteOpen/Close.webp，2026-07-06 补入）
    static var liveRoomRouletteA11y: String { localize("liveRoom.roulette.a11y", comment: "顶部互动转盘按钮 a11y") }
    static var liveRoomComingSoonRoulette: String { localize("liveRoom.comingSoon.roulette", comment: "点击转盘按钮占位提示") }
    static var liveRoomRouletteTip: String { localize("liveRoom.roulette.tip", comment: "未开启转盘时的顶部引导气泡") }

    // MARK: v7 LiveRoom Rank sheet + Contribution sheet + Roulette intro/setting（linter 曾清空，v10 补回）
    static var liveRoomRankSheetTitle: String { localize("liveRoom.rank.sheet.title", comment: "Rank sheet 标题") }
    static var liveRoomRankTabThisWeek: String { localize("liveRoom.rank.tab.thisWeek", comment: "本周 Tab") }
    static var liveRoomRankTabLastWeek: String { localize("liveRoom.rank.tab.lastWeek", comment: "上周 Tab") }
    /// v13 顶层 Tab：观众列表
    static var liveRoomRankTabViewers: String { localize("liveRoom.rank.tab.viewers", comment: "顶层 Viewers Tab") }
    /// v13 顶层 Tab：送礼周榜
    static var liveRoomRankTabTopGifter: String { localize("liveRoom.rank.tab.topGifter", comment: "顶层 Top Gifter Tab") }
    /// v13 Viewers Tab 空态提示（H 期接 apiViewers 前的占位）
    static var liveRoomRankViewersEmpty: String { localize("liveRoom.rank.viewers.empty", comment: "Viewers 空态") }
    /// v14 Top Gifter 内层 Now/Today/Week 3 子 Tab（对齐 H5 apiSendRank 3 时间维度）
    static var liveRoomRankTabNow: String { localize("liveRoom.rank.tab.now", comment: "Top Gifter Now Tab") }
    static var liveRoomRankTabToday: String { localize("liveRoom.rank.tab.today", comment: "Top Gifter Today Tab") }
    static var liveRoomRankTabWeek: String { localize("liveRoom.rank.tab.week", comment: "Top Gifter Week Tab") }
    /// v16 girlWeeklyRank banner 标题（对齐 H5 liveGirlRankEn.webp / liveGirlRankAr.png 主播周榜文字）
    static var liveRoomGirlRankBanner: String { localize("liveRoom.rank.girlBanner", comment: "girlWeeklyRank banner 装饰文字") }
    static var liveRoomRankEmpty: String { localize("liveRoom.rank.empty", comment: "Rank 空态") }
    static var liveRoomRankErrorRetry: String { localize("liveRoom.rank.errorRetry", comment: "加载失败重试") }
    static var liveRoomRankOwnMe: String { localize("liveRoom.rank.ownMe", comment: "自己 fallback 昵称") }
    static var liveRoomRankDiffFormat: String { localize("liveRoom.rank.diffFormat", comment: "距上一名格式") }
    static var liveRoomRankToNext: String { localize("liveRoom.rank.toNext", comment: "距下一名标签") }
    static var liveRoomContributionSheetTitle: String { localize("liveRoom.contribution.sheet.title", comment: "钻石收益 sheet 标题") }
    static var liveRoomContributionTabRanking: String { localize("liveRoom.contribution.tab.ranking", comment: "贡献榜 Tab") }
    static var liveRoomContributionTabRecord: String { localize("liveRoom.contribution.tab.record", comment: "礼物记录 Tab") }
    static var liveRoomContributionCurrentLiveIncome: String { localize("liveRoom.contribution.currentLiveIncome", comment: "本场收入") }
    static var liveRoomContributionEmptyRanking: String { localize("liveRoom.contribution.empty.ranking", comment: "贡献榜空态") }
    static var liveRoomContributionEmptyRecord: String { localize("liveRoom.contribution.empty.record", comment: "礼物记录空态") }
    static var liveRoomContributionErrorRetry: String { localize("liveRoom.contribution.errorRetry", comment: "加载失败重试") }
    static var liveRoomContribution90dFormat: String { localize("liveRoom.contribution.last90dFormat", comment: "90天格式") }
    static var liveRoomContributionLast90d: String { localize("liveRoom.contribution.last90d", comment: "近90天贡献标签") }
    static var liveRoomContributionSentAction: String { localize("liveRoom.contribution.sentAction", comment: "送出动作") }
    // v11 引导 2 卡（Wheel + RPS）：card1 复用为 Wheel 卡；card2/card3 + Start 已废弃
    static var liveRoomRouletteIntroCard1Title: String { localize("liveRoom.roulette.intro.card1.title", comment: "引导卡 1 (Wheel) 标题") }
    static var liveRoomRouletteIntroCard1Body: String { localize("liveRoom.roulette.intro.card1.body", comment: "引导卡 1 (Wheel) 正文") }
    static var liveRoomRouletteIntroNext: String { localize("liveRoom.roulette.intro.next", comment: "Next 按钮") }
    static var liveRoomRouletteSettingTitle: String { localize("liveRoom.roulette.setting.title", comment: "转盘设置标题") }
    static var liveRoomRouletteEnable: String { localize("liveRoom.roulette.enable", comment: "启用转盘") }
    static var liveRoomRoulettePrice: String { localize("liveRoom.roulette.price", comment: "转盘价格") }
    static var liveRoomRouletteSectors: String { localize("liveRoom.roulette.sectors", comment: "奖项列表") }
    static var liveRoomRouletteSectorsEmpty: String { localize("liveRoom.roulette.sectors.empty", comment: "奖项空态") }
    static var liveRoomRouletteEdit: String { localize("liveRoom.roulette.edit", comment: "编辑") }
    static var liveRoomRouletteRules: String { localize("liveRoom.roulette.rules", comment: "规则") }
    static var liveRoomRouletteErrorRetry: String { localize("liveRoom.roulette.errorRetry", comment: "加载失败重试") }
    // MARK: v11 转盘功能对齐 H5（新增 UI + 编辑子 sheet + Toast）
    static var liveRoomRouletteIntroHeader: String { localize("liveRoom.roulette.intro.header", comment: "引导 popup 顶部标题") }
    static var liveRoomRouletteIntroRpsTitle: String { localize("liveRoom.roulette.intro.rps.title", comment: "引导卡 RPS 标题") }
    static var liveRoomRouletteIntroRpsBody: String { localize("liveRoom.roulette.intro.rps.body", comment: "引导卡 RPS 正文") }
    static var liveRoomRouletteCloseWheel: String { localize("liveRoom.roulette.closeWheel", comment: "关闭转盘按钮") }
    static var liveRoomRouletteFinishEditing: String { localize("liveRoom.roulette.finishEditing", comment: "完成编辑按钮") }
    static var liveRoomRouletteEditTitle: String { localize("liveRoom.roulette.edit.title", comment: "编辑子 sheet 标题") }
    static var liveRoomRouletteEditConfirm: String { localize("liveRoom.roulette.edit.confirm", comment: "编辑子 sheet Confirm 按钮") }
    static var liveRoomRouletteEditEnterItems: String { localize("liveRoom.roulette.edit.enterItems", comment: "编辑子 sheet 输入 placeholder") }
    static var liveRoomRouletteToastStarted: String { localize("liveRoom.roulette.toast.started", comment: "启用成功 toast") }
    static var liveRoomRouletteToastStopped: String { localize("liveRoom.roulette.toast.stopped", comment: "关闭成功 toast") }
    static var liveRoomRouletteToastEnterPrice: String { localize("liveRoom.roulette.toast.enterPrice", comment: "价格为空 toast") }
    static var liveRoomRetry: String { localize("liveRoom.retry", comment: "通用重试") }

    // MARK: v6-v9 keys (linter 曾清空，v10 补回)
    static var liveRoomAudienceA11y: String { localize("liveRoom.audience.a11y", comment: "观众 popup 标题") }
    static var liveRoomComingSoonAudience: String { localize("liveRoom.comingSoon.audience", comment: "观众列表占位") }
    static var publicScreenTranslate: String { localize("publicScreen.translate", comment: "翻译按钮 a11y") }
    static var publicScreenTranslating: String { localize("publicScreen.translating", comment: "翻译中提示") }
    static var publicScreenSentAction: String { localize("publicScreen.sentAction", comment: "送礼动作词") }
    static var publicScreenEnteredRoom: String { localize("publicScreen.enteredRoom", comment: "进入房间") }
    static var guardianBroadcastBecame: String { localize("guardian.broadcast.became", comment: "守护开通广播，含 {anchor}/{level} 占位") }
    static var guardianLevelBronze: String { localize("guardian.level.bronze", comment: "铜守护等级") }
    static var guardianLevelSilver: String { localize("guardian.level.silver", comment: "银守护等级") }
    static var guardianLevelGold: String { localize("guardian.level.gold", comment: "金守护等级") }
    // MARK: - Guardian 主播只读面板（对齐 H5 guardian-detail / guardian-list）
    static var guardianTitle: String { localize("guardian.title", comment: "守护标题") }
    static var guardianMyGuardians: String { localize("guardian.myGuardians", comment: "我的守护者列表标题") }
    static var guardianHisGuardiansFormat: String { localize("guardian.hisGuardians.format", comment: "用户资料守护主播标题，%d") }
    static var guardianRulesTitle: String { localize("guardian.rules.title", comment: "守护规则标题") }
    static var guardianTopGuardian: String { localize("guardian.topGuardian", comment: "榜一守护者") }
    static var guardianListFormat: String { localize("guardian.list.format", comment: "守护者列表人数，%d") }
    static var guardianBeFirst: String { localize("guardian.beFirst", comment: "首位守护者空态") }
    static var guardianWaitForYour: String { localize("guardian.waitForYour", comment: "守护者列表空态") }
    static var guardianNoMore: String { localize("guardian.noMore", comment: "列表无更多数据") }
    static var guardianTabGold: String { localize("guardian.tab.gold", comment: "金守护 tab") }
    static var guardianTabSilver: String { localize("guardian.tab.silver", comment: "银守护 tab") }
    static var guardianTabBronze: String { localize("guardian.tab.bronze", comment: "铜守护 tab") }
    static var guardianPrivilegeBadge: String { localize("guardian.privilege.badge", comment: "守护勋章权益") }
    static var guardianPrivilegeFrame: String { localize("guardian.privilege.frame", comment: "守护头像框权益") }
    static var guardianPrivilegeChat: String { localize("guardian.privilege.chat", comment: "守护聊天气泡权益") }
    static var guardianPrivilegeHighlight: String { localize("guardian.privilege.highlight", comment: "守护房间广播权益") }
    static var guardianPrivilegeNotice: String { localize("guardian.privilege.notice", comment: "守护进场通知权益") }
    static var guardianPrivilegeMount: String { localize("guardian.privilege.mount", comment: "守护座驾权益") }
    static var guardianPrivilegeGift: String { localize("guardian.privilege.gift", comment: "守护礼物权益") }
    static var guardianDay7: String { localize("guardian.day.7", comment: "守护 7 天时长") }
    static var guardianDay30: String { localize("guardian.day.30", comment: "守护 30 天时长") }
    static var guardianDay365: String { localize("guardian.day.365", comment: "守护 365 天时长") }
    static var guardianSaveFormat: String { localize("guardian.save.format", comment: "守护折扣，%d") }
    static var guardianPrivilegePreviewSubtitleFormat: String { localize("guardian.preview.subtitle", comment: "权益预览副标题，%@") }
    static var guardianPrivilegePreview: String { localize("guardian.preview", comment: "权益预览按钮") }
    static var guardianDaysLeftFormat: String { localize("guardian.daysLeft.format", comment: "守护剩余天数，%d") }
    static var guardianRulesQuestion1: String { localize("guardian.rules.q1", comment: "守护规则问题 1") }
    static var guardianRulesAnswer1: String { localize("guardian.rules.a1", comment: "守护规则答案 1") }
    static var guardianRulesQuestion2: String { localize("guardian.rules.q2", comment: "守护规则问题 2") }
    static var guardianRulesAnswer2: String { localize("guardian.rules.a2", comment: "守护规则答案 2") }
    static var guardianRulesQuestion3: String { localize("guardian.rules.q3", comment: "守护规则问题 3") }
    static var guardianRulesAnswer3: String { localize("guardian.rules.a3", comment: "守护规则答案 3") }
    static var guardianRulesQuestion4: String { localize("guardian.rules.q4", comment: "守护规则问题 4") }
    static var guardianRulesAnswer4: String { localize("guardian.rules.a4", comment: "守护规则答案 4") }
    static var guardianRulesQuestion5: String { localize("guardian.rules.q5", comment: "守护规则问题 5") }
    static var guardianRulesAnswer5: String { localize("guardian.rules.a5", comment: "守护规则答案 5") }
    static var guardianRulesQuestion6: String { localize("guardian.rules.q6", comment: "守护规则问题 6") }
    static var guardianRulesAnswer6: String { localize("guardian.rules.a6", comment: "守护规则答案 6") }
    static var guardianRulesLevelExtra: String { localize("guardian.rules.levelExtra", comment: "守护等级消耗说明") }
    static var guardianRulesPrivilegesExtra: String { localize("guardian.rules.privilegesExtra", comment: "守护权益说明") }
    static var guardianRulesDuration7: String { localize("guardian.rules.duration.7", comment: "守护 7 天规则") }
    static var guardianRulesDuration30: String { localize("guardian.rules.duration.30", comment: "守护 30 天规则") }
    static var guardianRulesDuration365: String { localize("guardian.rules.duration.365", comment: "守护 365 天规则") }
    static var guardianRulesDurationExtra: String { localize("guardian.rules.durationExtra", comment: "守护有效期补充说明") }
    static var guardianRulesRank1: String { localize("guardian.rules.rank.1", comment: "守护排序规则 1") }
    static var guardianRulesRank2: String { localize("guardian.rules.rank.2", comment: "守护排序规则 2") }
    static var guardianRulesRank3: String { localize("guardian.rules.rank.3", comment: "守护排序规则 3") }
    static var guardianRulesRankExtra: String { localize("guardian.rules.rankExtra", comment: "守护排序补充说明") }
    /// v18 幸运礼物 / 转盘 / 猜拳 / 心愿单 / 钻石盲盒 公屏文案
    static var publicScreenLuckyWin: String { localize("publicScreen.luckyWin", comment: "幸运礼物 wins") }
    static var publicScreenLuckyBySending: String { localize("publicScreen.luckyBySending", comment: "幸运礼物 by sending lucky") }
    static var publicScreenWheelHit: String { localize("publicScreen.wheelHit", comment: "转盘 hit") }
    static var publicScreenWheelOnTheWheel: String { localize("publicScreen.wheelOnTheWheel", comment: "转盘 on the wheel") }
    static var publicScreenRpsWin: String { localize("publicScreen.rpsWin", comment: "猜拳 wins RPS") }
    static var publicScreenLuckyDiceWin: String { localize("publicScreen.luckyDiceWin", comment: "幸运骰子获胜") }
    static var publicScreenRpsGet: String { localize("publicScreen.rpsGet", comment: "猜拳 get medal") }
    static var publicScreenWishlistTop1: String { localize("publicScreen.wishlistTop1", comment: "心愿单登顶") }
    static var publicScreenPKTopContributors: String { localize("publicScreen.pkTopContributors", comment: "PK 贡献榜标题") }
    static var publicScreenPKTop1: String { localize("publicScreen.pkTop1", comment: "PK 贡献榜第一名") }
    static var publicScreenPKTop2: String { localize("publicScreen.pkTop2", comment: "PK 贡献榜第二名") }
    static var publicScreenPKTop3: String { localize("publicScreen.pkTop3", comment: "PK 贡献榜第三名") }
    static var publicScreenDiamondBoxSend: String { localize("publicScreen.diamondBoxSend", comment: "钻石盲盒发包") }
    static var publicScreenDiamondBoxClaim: String { localize("publicScreen.diamondBoxClaim", comment: "钻石盲盒瓜分") }
    static var publicScreenDiamondBoxSettled: String { localize("publicScreen.diamondBoxSettled", comment: "钻石盲盒结算") }
    static var publicScreenDiamondBoxExpired: String { localize("publicScreen.diamondBoxExpired", comment: "钻石盲盒过期退回") }
    static var diamondGiftGrab: String { localize("diamondGift.grab", comment: "钻石福袋开抢状态") }
    static var diamondGiftSendAction: String { localize("diamondGift.sendAction", comment: "钻石福袋发包动作") }
    static func diamondGiftClaim(user: String, diamonds: Int64) -> String {
        String(format: localize("diamondGift.claimFormat", comment: "钻石福袋瓜分文案"), user, diamonds)
    }
    static func diamondGiftExpired(user: String) -> String {
        String(format: localize("diamondGift.expiredFormat", comment: "钻石福袋退款文案"), user)
    }
    static func diamondGiftUser(_ id: String) -> String {
        String(format: localize("diamondGift.userFormat", comment: "钻石福袋用户兜底昵称"), id)
    }
    static var diamondGiftSettledTitle: String { localize("diamondGift.settledTitle", comment: "钻石福袋结算卡标题") }
    static var diamondGiftViewDetails: String { localize("diamondGift.viewDetails", comment: "钻石福袋查看详情") }
    static var diamondGiftRulesTitle: String { localize("diamondGift.rulesTitle", comment: "钻石福袋规则标题") }
    static var diamondGiftRulesSectionA: String { localize("diamondGift.rulesSectionA", comment: "钻石福袋规则第一节") }
    static var diamondGiftRulesSectionB: String { localize("diamondGift.rulesSectionB", comment: "钻石福袋规则第二节") }
    static var diamondGiftRulesSectionC: String { localize("diamondGift.rulesSectionC", comment: "钻石福袋规则第三节") }
    static var diamondGiftRulesATitle: String { localize("diamondGift.rulesATitle", comment: "钻石福袋规则第一节标题") }
    static var diamondGiftRulesA1: String { localize("diamondGift.rulesA1", comment: "钻石福袋规则第一节内容") }
    static var diamondGiftRulesBTitle: String { localize("diamondGift.rulesBTitle", comment: "钻石福袋规则第二节标题") }
    static var diamondGiftRulesB1: String { localize("diamondGift.rulesB1", comment: "钻石福袋规则第二节第一条") }
    static var diamondGiftRulesB2: String { localize("diamondGift.rulesB2", comment: "钻石福袋规则第二节第二条") }
    static var diamondGiftRulesCTitle: String { localize("diamondGift.rulesCTitle", comment: "钻石福袋规则第三节标题") }
    static var diamondGiftRulesC1: String { localize("diamondGift.rulesC1", comment: "钻石福袋规则第三节第一条") }
    static var diamondGiftRulesC2: String { localize("diamondGift.rulesC2", comment: "钻石福袋规则第三节第二条") }
    static var diamondGiftRulesC3: String { localize("diamondGift.rulesC3", comment: "钻石福袋规则第三节第三条") }
    static var diamondGiftRulesC4: String { localize("diamondGift.rulesC4", comment: "钻石福袋规则第三节第四条") }
    static var diamondGiftWinnersTitle: String { localize("diamondGift.winnersTitle", comment: "钻石福袋获奖名单标题") }
    static var diamondGiftTopShare: String { localize("diamondGift.topShare", comment: "钻石福袋最高分享标识") }
    static var diamondGiftNoWinners: String { localize("diamondGift.noWinners", comment: "钻石福袋无获奖者") }
    /// v24 活跃大 R 进房 Toast（B1 · 对齐 H5 §9.6 handleActiveTycoonEnterToast）
    static var liveActiveTycoonEnterToast: String { localize("live.activeTycoon.enterToast", comment: "大 R 进房顶部 toast") }
    /// v24 猜拳规则浮层（B2 · 对齐 H5 §9.2.2 rpsRulesSheet.vue）
    static var liveRoomRpsRulesTitle: String { localize("liveRoom.rpsRules.title", comment: "猜拳规则标题") }
    /// %d bestOf 局数
    static var liveRoomRpsRulesBestOfFormat: String { localize("liveRoom.rpsRules.bestOf", comment: "%d Best of N 局") }
    /// %d 每局价格钻石
    static var liveRoomRpsRulesPerChallengeFormat: String { localize("liveRoom.rpsRules.perChallenge", comment: "%d 每局价格钻石") }
    static var liveRoomRpsRulesTies: String { localize("liveRoom.rpsRules.ties", comment: "平局重赛") }
    /// %d 勋章基础小时 %d 累计上限小时
    static var liveRoomRpsRulesMedalFormat: String { localize("liveRoom.rpsRules.medal", comment: "%d 勋章基础小时 %d 累计上限") }
    static var liveRoomRpsRulesRefund: String { localize("liveRoom.rpsRules.refund", comment: "异常退出退款") }
    static var liveRoomRpsRulesGotIt: String { localize("liveRoom.rpsRules.gotIt", comment: "知道了") }
    /// v24 主播被禁言双字段状态机（B3 · 对齐 H5 §9.16 gagMember/ungagMember）
    static var liveRoomMutePlaceholderSystem: String { localize("liveRoom.mute.placeholder.system", comment: "被系统禁言输入框 placeholder") }
    static var liveRoomMutePlaceholderHost: String { localize("liveRoom.mute.placeholder.host", comment: "被房主禁言输入框 placeholder") }
    static var liveRoomMuteToastSystem: String { localize("liveRoom.mute.toast.system", comment: "被系统禁言 tap toast") }
    static var liveRoomMuteToastHost: String { localize("liveRoom.mute.toast.host", comment: "被房主禁言 tap toast") }
    /// v24 公屏 hi 气泡 Screen / MSG 双入口（B4 · 对齐 H5 §9.12.4）
    static var publicScreenHiActionA11y: String { localize("publicScreen.hi.actionA11y", comment: "公屏 hi 图标 a11y label") }
    static var publicScreenHiScreen: String { localize("publicScreen.hi.screen", comment: "公屏 @回复") }
    static var publicScreenHiMsg: String { localize("publicScreen.hi.msg", comment: "半屏私聊") }
    static var publicScreenHiMsgUnavailable: String { localize("publicScreen.hi.msgUnavailable", comment: "半屏私聊入口 fallback toast：对方账号不可用") }
    /// %@ = 对方昵称
    static var publicScreenHiReplyPillFormat: String { localize("publicScreen.hi.replyPill", comment: "@回复 pending pill") }
    /// 通用取消（多处 confirmationDialog / cancel role 复用）
    static var commonCancel: String { localize("common.cancel", comment: "通用取消") }
    static var virtualPropsEffectSwitchTitle: String { localize("virtualProps.effectSwitch.title", comment: "虚拟道具开关标题") }
    static var virtualPropsEffectSwitchDescription: String { localize("virtualProps.effectSwitch.description", comment: "虚拟道具开关说明") }
    static var virtualPropsEffectSwitchTip: String { localize("virtualProps.effectSwitch.tip", comment: "虚拟道具开关入口提示") }
    static var virtualPropsEffectEnable: String { localize("virtualProps.effectEnable", comment: "启用效果") }
    static var announcementPopupTitle: String { localize("announcement.popup.title", comment: "公告标题") }
    static var announcementPlaceholder: String { localize("announcement.popup.placeholder", comment: "公告输入提示") }
    static var announcementSave: String { localize("announcement.popup.save", comment: "保存") }
    static var announcementSaveSuccess: String { localize("announcement.popup.saveSuccess", comment: "保存成功") }
    static var announcementSensitiveWord: String { localize("announcement.popup.sensitiveWord", comment: "敏感词 %@") }
    /// v20 保存中文案（3 语已补齐）
    static var announcementSaving: String { localize("announcement.popup.saving", comment: "保存中") }
    static var userCardTitle: String { localize("userCard.title", comment: "名片卡标题") }
    static var userCardFollow: String { localize("userCard.follow", comment: "关注") }
    static var userCardUnfollow: String { localize("userCard.unfollow", comment: "取关(已关注 pill 态)") }
    static var userCardBlock: String { localize("userCard.block", comment: "拉黑(未拉黑 pill 态)") }
    static var userCardUnblock: String { localize("userCard.unblock", comment: "已拉黑 pill 态文案") }
    static var userCardFollowers: String { localize("userCard.followers", comment: "粉丝") }
    static var userCardFollowing: String { localize("userCard.following", comment: "关注数") }
    /// 礼物墙 title:主播端看用户 → "Sent gifts"(该用户送出的礼物列表)
    /// H5 template `isAnchor ? 'Received gifts' : 'Send gifts'`,iOS 主播端定位永远走 !isAnchor 分支
    static var userCardGiftWall: String { localize("userCard.giftWall", comment: "礼物墙 title:用户送出过的礼物") }
    static var userCardErrorRetry: String { localize("userCard.errorRetry", comment: "名片卡加载失败") }
    /// UID 复制成功 toast(比通用 commonCopySuccess 更具体)
    static var userCardUidCopiedToast: String { localize("userCard.uidCopiedToast", comment: "UID 已复制到剪贴板 toast") }
    /// UID 复制按钮 accessibility label(VoiceOver 读作动词"复制 UID")
    static var userCardUidCopyA11y: String { localize("userCard.uidCopyA11y", comment: "复制 UID 按钮无障碍描述") }
    /// 派对房 admin action row 按钮文案(对齐 H5 party-user-card.vue L644-666)
    static var userCardPartyMute: String { localize("userCard.party.mute", comment: "禁麦按钮") }
    static var userCardPartyUnmute: String { localize("userCard.party.unmute", comment: "解禁麦按钮") }
    static var userCardPartyTake: String { localize("userCard.party.take", comment: "抱上麦按钮(对齐 H5 party.Take)") }
    static var userCardPartyKickFromMic: String { localize("userCard.party.kickFromMic", comment: "抱下麦按钮") }
    static var userCardPartySetAdmin: String { localize("userCard.party.setAdmin", comment: "设为房管按钮") }
    static var userCardPartyRemoveAdmin: String { localize("userCard.party.removeAdmin", comment: "移除房管按钮") }
    static var userCardPartyKick: String { localize("userCard.party.kick", comment: "踢出房间按钮") }
    /// 踢房时长 sheet 文案(H5 blockTime + Permanent 双选)
    static func userCardPartyKickHoursFormat(hours: Int) -> String {
        String(format: localize("userCard.party.kickHoursFormat", comment: "%d hours"), hours)
    }
    static var userCardPartyKickPermanent: String { localize("userCard.party.kickPermanent", comment: "永久") }
    /// 踢房 confirm dialog 文案
    static func userCardPartyKickConfirmMessage(nickname: String) -> String {
        String(format: localize("userCard.party.kickConfirmMessage", comment: "Are you sure to kick %@ out of the room?"), nickname)
    }
    static var userCardPartyKickConfirmButton: String { localize("userCard.party.kickConfirmButton", comment: "踢出确认按钮") }
    /// 操作成功/失败 toast(H5 对齐)
    static var userCardPartyKickSuccess: String { localize("userCard.party.kickSuccess", comment: "踢出成功 toast") }
    static var userCardPartySetAdminSuccess: String { localize("userCard.party.setAdminSuccess", comment: "设为房管成功") }
    static var userCardPartyRemoveAdminSuccess: String { localize("userCard.party.removeAdminSuccess", comment: "移除房管成功") }
    /// Block/Unblock 4 类 toast(H5 line 254/256/276 显式 showToast)
    static var userCardBlockSuccess: String { localize("userCard.blockSuccess", comment: "拉黑成功 toast") }
    static var userCardBlockFail: String { localize("userCard.blockFail", comment: "拉黑失败 toast") }
    static var userCardUnblockSuccess: String { localize("userCard.unblockSuccess", comment: "移除黑名单成功 toast") }
    static var userCardUnblockFail: String { localize("userCard.unblockFail", comment: "移除黑名单失败 toast") }
    /// H5 对齐:私聊按钮
    static var userCardMessage: String { localize("userCard.message", comment: "私聊按钮") }
    /// H5 对齐:送礼按钮(替换原 Follow 按钮位置;关注 icon 移到昵称行)
    static var userCardSendGift: String { localize("userCard.sendGift", comment: "送礼按钮") }
    /// H5 对齐:礼物墙空态文案 "No gifts sent yet!"
    static var userCardEmptyGifts: String { localize("userCard.emptyGifts", comment: "礼物墙空态") }
    /// H5 对齐:UID 前缀 "UID: xxx"(冒号后跟 userId,数字不 i18n)
    static var userCardUidPrefix: String { localize("userCard.uidPrefix", comment: "UID 展示前缀") }
    /// unblock 二次确认 dialog(H5 "Are you sure to remove the user from the blacklist?")
    static var userCardUnblockConfirmTitle: String { localize("userCard.unblockConfirm.title", comment: "移除黑名单二次确认标题") }
    static var userCardUnblockConfirmMessage: String { localize("userCard.unblockConfirm.message", comment: "移除黑名单二次确认正文") }
    static var userCardUnblockConfirmButton: String { localize("userCard.unblockConfirm.confirm", comment: "移除黑名单二次确认按钮") }
    static var userCardUnblockConfirmCancel: String { localize("userCard.unblockConfirm.cancel", comment: "移除黑名单二次确认取消") }
    static var paidBulletDislike: String { localize("paidBullet.dislike", comment: "不喜欢") }
    static var paidBulletDislikeFailed: String { localize("paidBullet.dislikeFailed", comment: "付费跑马灯点踩失败 toast") }
    static var paidBulletEarningsToast: String { localize("paidBullet.earningsToast", comment: "主播每日首条付费跑马灯收益 toast；%lld = coins") }

    // MARK: - LiveRoom H5 交互对齐（2026-07-06 restore-design iteration 2）
    /// 底部工具栏 4 圆按钮（对齐 H5 msg/gift/setting 3 图标 + PKEntryBtn）
    static var liveRoomToolMessage:  String { localize("liveRoom.tool.message",  comment: "底部消息按钮 a11y") }
    static var liveRoomToolGift:     String { localize("liveRoom.tool.gift",     comment: "底部礼物按钮 a11y") }
    static var liveRoomToolSetting:  String { localize("liveRoom.tool.setting",  comment: "底部设置按钮 a11y（含美颜/结束直播）") }
    /// 消息按钮点击占位（v18 前使用；v18 起消息按钮真接入 ConversationSheetContent 半屏列表 sheet，此 key 保留用作兜底 toast）
    static var liveRoomComingSoonMessage: String { localize("liveRoom.comingSoon.message", comment: "消息按钮占位提示") }
    /// 半屏消息列表标题（对齐 H5 messagePopup 顶部 "Messages"）
    static var liveRoomSheetMessagesTitle: String { localize("liveRoom.sheet.messagesTitle", comment: "半屏消息列表标题") }
    /// 设置菜单：美颜项
    static var liveRoomSettingBeauty:     String { localize("liveRoom.setting.beauty",     comment: "设置菜单：美颜") }
    /// 设置菜单：结束直播项
    static var liveRoomSettingEndLive:    String { localize("liveRoom.setting.endLive",    comment: "设置菜单：结束直播") }
    /// v17 设置菜单：虚拟道具特效（对齐 H5 liveSettingPopup effect-toggle）
    static var liveRoomSettingEffect:     String { localize("liveRoom.setting.effect",     comment: "设置菜单：虚拟道具特效") }
    /// v17 设置菜单：公告管理（对齐 H5 liveSettingPopup 📢 announcement）
    static var liveRoomSettingAnnouncement: String { localize("liveRoom.setting.announcement", comment: "设置菜单：公告管理") }
    /// v17 设置弹窗标题
    static var liveRoomSettingSheetTitle: String { localize("liveRoom.setting.sheet.title", comment: "设置弹窗标题") }

    // MARK: 关闭直播二次确认（对齐 H5 endLivePopup.vue）
    static var liveRoomEndConfirmTitle:   String { localize("liveRoom.endConfirm.title",   comment: "关闭直播确认弹窗标题") }
    static var liveRoomEndConfirmMessage: String { localize("liveRoom.endConfirm.message", comment: "关闭直播确认弹窗内容") }
    static var liveRoomEndConfirmConfirm: String { localize("liveRoom.endConfirm.confirm", comment: "关闭直播确认弹窗 Confirm 按钮") }

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
    static var callErrorRemoteNoAnswer: String     { localize("call.error.remoteNoAnswer", comment: "对方无应答（30s 主叫超时）") }
    static var callErrorRemoteBusy: String         { localize("call.error.remoteBusy", comment: "对方正忙（rejectReason=busy）") }
    static var callErrorLocalBusy: String          { localize("call.error.localBusy", comment: "本端已有进行中的通话") }
    /// 黑屏空房间检测倒计时弹窗文案（DM-20260616-003；对齐 H5 emptyRoomCountdownPop.vue）
    static var callEmptyRoomHangupTip: String      { localize("call.emptyRoom.hangupTip", comment: "通话异常将自动挂断（10s 倒计时）") }
    /// 通用：会话已过期 / 未登录提示
    static var sessionExpiredError: String         { localize("auth.sessionExpired", comment: "未登录 / 会话已过期") }

    // MARK: - Call 1v1 真实通话视图（CallView.swift）
    static var callWaitingForAnswer: String { localize("call.waiting.answer", comment: "1v1：待接听页状态文案") }
    static var callSubtitleCallingOut: String { localize("call.subtitle.callingOut", comment: "1v1：主叫副标题") }
    static var callSubtitleIncoming: String { localize("call.subtitle.incoming", comment: "1v1：被叫副标题") }
    static var callActionCancel: String { localize("call.action.cancel", comment: "1v1：取消按钮（主叫端）") }
    static var callActionReject: String { localize("call.action.reject", comment: "1v1：拒接按钮") }
    static var callActionAccept: String { localize("call.action.accept", comment: "1v1：接听按钮") }
    static var callActionHangupBackToLive: String { localize("call.action.hangupBackToLive", comment: "1v1：挂断回直播（直播私 call）") }
    static var callActionHangup: String { localize("call.action.hangup", comment: "1v1：挂断按钮") }
    // C-1 通话中控制按钮 UI（Wave 1）
    static var callActionMicMute: String { localize("call.action.micMute", comment: "C-1：静音麦克风按钮 label") }
    static var callActionMicUnmute: String { localize("call.action.micUnmute", comment: "C-1：取消静音按钮 label") }
    static var callActionSwitchCamera: String { localize("call.action.switchCamera", comment: "C-1：切换前后置摄像头按钮 label") }
    static var callNetworkQualityWeak: String { localize("call.networkQuality.weak", comment: "C-1：弱网 toast（连续 30 次质量差触发）") }
    // C-3 通话异常自检 alert（tenSecondsCB + secondsToZero）
    static var callAbnormalUserOfflineTitle: String { localize("call.abnormal.userOffline.title", comment: "C-3：对方离线 alert 标题") }
    static var callAbnormalUserOfflineMessage: String { localize("call.abnormal.userOffline.message", comment: "C-3：对方离线 alert 副标题") }
    static var callAbnormalNetworkUnstableTitle: String { localize("call.abnormal.networkUnstable.title", comment: "C-3：网络不稳定 alert 标题") }
    static var callAbnormalNetworkUnstableMessage: String { localize("call.abnormal.networkUnstable.message", comment: "C-3：网络不稳定 alert 副标题（不计费）") }
    static var callAbnormalIncomeZeroTitle: String { localize("call.abnormal.incomeZero.title", comment: "C-3：收入异常 alert 标题") }
    static var callAbnormalIncomeZeroMessage: String { localize("call.abnormal.incomeZero.message", comment: "C-3：收入异常 alert 副标题（>120s 无收入）") }
    static var callAbnormalEndCall: String { localize("call.abnormal.endCall", comment: "C-3：异常 alert End Call 按钮（destructive）") }
    static var callAbnormalContinue: String { localize("call.abnormal.continue", comment: "C-3：异常 alert Continue 按钮（继续通话）") }
    // C-4 Wave1 UI 补齐（gap-009 直播私 call 300s 收益横幅 + gap-018 挂断二次确认）
    static var callLiveBannerCountdownFormat: String { localize("call.liveBanner.countdownFormat", comment: "C-4 gap-009：直播私 call 300s 收益横幅（%d 秒）") }
    static var callHangupConfirmTitle: String { localize("call.hangupConfirm.title", comment: "C-4 gap-018：顶部 X 按钮挂断二次确认标题") }
    static var callHangupConfirmCancel: String { localize("call.hangupConfirm.cancel", comment: "C-4 gap-018：挂断二次确认取消按钮") }
    // C-5 充值锁定流程（gap-011/012）
    static var callWaitRechargeBonusFormat: String { localize("call.waitRecharge.bonusFormat", comment: "C-5 gap-011：充值锁定顶部提示 bonus 胶囊（%d 钻石）") }
    static var callWaitRechargeCountdownFormat: String { localize("call.waitRecharge.countdownFormat", comment: "C-5 gap-011：充值锁定倒计时（%d 秒）") }
    static var callCongratsTitle: String { localize("call.congrats.title", comment: "C-5 gap-012：充值成功 Congrats 弹窗标题") }
    static var callCongratsMessageFormat: String { localize("call.congrats.messageFormat", comment: "C-5 gap-012：充值成功副标题（%d 钻石）") }
    static var callCongratsOK: String { localize("call.congrats.ok", comment: "C-5 gap-012：充值成功 OK 按钮") }
    // C-4 Wave4 UI 布局对齐（gap-004 占位 + gap-005 占位）
    static var callActionAskForGift: String { localize("call.action.askForGift", comment: "1v1：索要礼物按钮（H5 g-faceTime askForGift）") }
    static var callActionMore: String { localize("call.action.more", comment: "1v1：更多菜单按钮（打开反馈/举报 sheet）") }
    /// 底部第 1 键：聊天输入（H5 icon-chat-btn；点击展开公屏输入框，Wave 6 依赖 NIM 通话通道）
    static var callActionChatInput: String { localize("call.action.chatInput", comment: "1v1：聊天输入按钮（发公屏消息）") }
    /// 底部第 3 键：反馈（H5 icon-more-btn；打开 feedback sheet type='call'）
    static var callActionFeedback: String { localize("call.action.feedback", comment: "1v1：反馈按钮（打开反馈 sheet）") }
    static var callActionComingSoon: String { localize("call.action.comingSoon", comment: "1v1：占位实现的按钮 Coming Soon toast") }
    // C-4 Wave4 C 组 gap-010：远端摄像头 off fallback
    static var callRemoteCameraOff: String { localize("call.remoteCameraOff", comment: "C-gap010：对方关摄像头时占位文案") }
    static var callLiveBanner: String { localize("call.liveBanner", comment: "1v1：直播私 call 顶部 banner") }
    /// 通话结束回直播弹窗（D 里程碑 resumeCall；对齐 H5 returnLivePopup.vue）
    static var liveReturnAutoFormat: String { localize("live.returnPopup.autoFormat", comment: "%d seconds later it will automatically return to live") }
    static var liveReturnButton: String { localize("live.returnPopup.button", comment: "Return to live 立刻回直播按钮") }

    // 设计稿主播端.png 对齐（2026-07-09）：顶部信息卡装饰性信号条 + waitState 内联粉色 tag
    static var callSignalLabelYou: String { localize("call.signal.label.you", comment: "顶部信息卡 You 信号条标签（装饰性 UI，非真实网络质量）") }
    static var callSignalLabelUser: String { localize("call.signal.label.user", comment: "顶部信息卡 User 信号条标签（装饰性 UI）") }
    static var callWaitStateRechargingFormat: String { localize("call.waitState.rechargingFormat", comment: "顶部信息卡粉色 tag：User recharging, please wait %ds.") }

    // Phase C 通话内公屏输入框（对齐 H5 g-faceTime showInput）
    static var callChatInputPlaceholder: String { localize("call.chat.input.placeholder", comment: "通话中公屏输入框占位文案") }
    static var callChatInputSend: String { localize("call.chat.input.send", comment: "通话中公屏输入框发送按钮") }

    // v22（2026-07-10）：主播索取礼物被用户拒绝的 toast
    static var callAskForGiftRejected: String { localize("call.askForGift.rejected", comment: "主播索取礼物被用户拒绝时的 toast 提示") }
    static var callAskForGiftWaitingForReward: String { localize("call.askForGift.waitingForReward", comment: "主播索礼成功后的等待奖励提示") }

    // MARK: - J 机器人通话
    static var robotCallIncomingTitle: String { localize("robotCall.incoming.title", comment: "机器人来电标题") }
    static var robotCallIncomingSupport: String { localize("robotCall.incoming.support", comment: "机器人来电副标题") }
    static var robotCallWaiting: String { localize("robotCall.incoming.waiting", comment: "机器人来电等待提示") }
    static var robotCallAccept: String { localize("robotCall.action.accept", comment: "接听机器人来电") }
    static var robotCallReject: String { localize("robotCall.action.reject", comment: "拒绝机器人来电") }
    static var robotCallEnd: String { localize("robotCall.action.end", comment: "结束机器人通话") }
    static var robotCallMinimumDuration: String { localize("robotCall.minimumDuration", comment: "机器人通话最短 10 秒提示") }
    static var robotCallAcceptFailed: String { localize("robotCall.acceptFailed", comment: "机器人来电接听失败") }
    static var robotCallRewardTitle: String { localize("robotCall.reward.title", comment: "机器人通话奖励达标标题") }
    static var robotCallNoRewardTitle: String { localize("robotCall.noReward.title", comment: "机器人通话未达标标题") }
    static var robotCallDurationFormat: String { localize("robotCall.duration.format", comment: "机器人通话时长") }
    static var robotCallRewardDurationFormat: String { localize("robotCall.reward.duration.format", comment: "机器人通话奖励达标时长") }
    static var robotCallRewardCoinsFormat: String { localize("robotCall.reward.coins.format", comment: "机器人通话奖励钻石") }
    static var robotCallRewardOK: String { localize("robotCall.reward.ok", comment: "机器人通话奖励确认") }

    // v22（2026-07-11）：PK 开始公屏消息（对齐 H5 preparingCountdown 结束后 sendLiveRoomNotice）
    static var pkNotificationStart: String { localize("pk.pkNotificationStart", comment: "PK 开始公屏文案") }

    // v22（2026-07-10）：PK 结果公屏消息（对齐 H5 sendPkEndNotice 3 分支文案）
    static func pkResultWinFormat(_ my: String, _ opponent: String) -> String {
        String(format: localize("pk.pkResultWin", comment: "PK 胜利公屏文案"), my, opponent)
    }
    static func pkResultLoseFormat(_ my: String, _ opponent: String) -> String {
        String(format: localize("pk.pkResultLose", comment: "PK 失败公屏文案"), my, opponent)
    }
    static func pkResultDrawFormat(_ my: String, _ opponent: String) -> String {
        String(format: localize("pk.pkResultDraw", comment: "PK 平局公屏文案"), my, opponent)
    }

    // MARK: - v25（2026-07-17）: 直播间任务面板 LiveGiftTask · 对齐 H5 girlWeeklyTask.vue
    // 三语言翻译需从 H5 locales/[en|ar|tr].json 迁移 task.* 键值，禁止三语同填英文
    static var liveRoomTaskSheetTitle: String { localize("liveRoom.task.sheet.title", comment: "任务面板标题 Live Stream Task") }
    static var liveRoomTaskTabLiveGift: String { localize("liveRoom.task.tab.liveGift", comment: "Tab1 Live Gift Task") }
    static var liveRoomTaskTabActiveTycoon: String { localize("liveRoom.task.tab.activeTycoon", comment: "Tab2 Active Tycoon Task") }
    static var liveRoomTaskProgressTitle: String { localize("liveRoom.task.progress.title", comment: "任务进度卡标题 task progress") }
    static var liveRoomTaskProgressSubtitle: String { localize("liveRoom.task.progress.subtitle", comment: "任务进度卡副文案") }
    static var liveRoomTaskHistoryTitle: String { localize("liveRoom.task.history.title", comment: "今日送礼历史标题") }
    static var liveRoomTaskHistoryFinished: String { localize("liveRoom.task.history.finished", comment: "无更多历史 / 空态") }
    static var liveRoomTaskHistoryError: String { localize("liveRoom.task.history.error", comment: "加载失败 tap 重试") }
    static var liveRoomTaskTycoonCompleted: String { localize("liveRoom.task.tycoon.completed", comment: "任务已完成绿色标记") }
    static var liveRoomTaskTycoonEmpty: String { localize("liveRoom.task.tycoon.empty", comment: "Tycoon 空态") }
    static var liveRoomTaskTycoonLoading: String { localize("liveRoom.task.tycoon.loading", comment: "Tycoon 加载中") }
    static var liveRoomTaskRulesButton: String { localize("liveRoom.task.rules.button", comment: "规则弹窗 OK 按钮") }
    static var liveRoomTaskRulesTitleLiveGift: String { localize("liveRoom.task.rules.title.liveGift", comment: "Live Gift Task 规则标题") }
    static var liveRoomTaskRulesTitleTycoon: String { localize("liveRoom.task.rules.title.tycoon", comment: "Active Tycoon Task 规则标题") }
    static var liveRoomTaskRulesBodyLiveGift: String { localize("liveRoom.task.rules.body.liveGift", comment: "Live Gift Task 规则正文") }
    static var liveRoomTaskRulesBodyTycoon: String { localize("liveRoom.task.rules.body.tycoon", comment: "Active Tycoon Task 规则正文默认") }

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
    /// 全局顶部错误通知：envelope 解析失败（APIClient / PartyAPIClient / SapiTokenStore 共用；技术错误，三语言统一英文）
    static var apiResponseParseFailed: String { localize("api.error.responseParseFailed", comment: "响应解析失败：全局顶部通知文案，三语言统一英文") }
    /// 全局顶部错误通知：网络错误（URLError 层失败，如离线/超时/DNS）；三语言统一英文
    static var apiNetworkError: String { localize("api.error.network", comment: "网络错误：全局顶部通知文案，三语言统一英文") }
    /// 全局顶部错误通知：sapi 二次 401（session 失效但不走 1004/1005 主接口分流）；三语言统一英文
    static var apiSessionExpired: String { localize("api.error.session", comment: "会话失效：全局顶部通知文案，三语言统一英文") }
    /// 全局顶部错误通知：HTTP 非 2xx server 侧错误（%d = status code）；三语言统一英文
    static func apiServerErrorFormat(_ code: Int) -> String { String(format: localize("api.error.serverFormat", comment: "服务错误：HTTP %d 全局顶部通知文案，三语言统一英文"), code) }
    /// 通用请求失败兜底：业务码非成功但 message 为空时用（%@ = code）；三语言统一英文
    static func apiRequestFailedFormat(_ code: String) -> String { String(format: localize("api.error.requestFailedFormat", comment: "请求失败(code)：业务码空 message 兜底，三语言统一英文"), code) }

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
    /// 通用关注/取关成功 toast（对齐 H5 `jsToast.userFollow` / `userCancelFollow`，所有场景共用）
    static var commonFollowSuccess: String          { localize("common.followSuccess", comment: "关注成功 toast") }
    static var commonUnfollowSuccess: String        { localize("common.unfollowSuccess", comment: "取消关注成功 toast") }
    // P1-6（2026-07-14）主播审核弹窗
    static var commonKindReminder: String           { localize("common.kindReminder", comment: "通用弹窗提示 title（对齐 H5 Vant showDialog 默认）") }
    static var commonConfirm: String                { localize("common.confirm", comment: "通用 Confirm 按钮") }
    static var commonClose: String                  { localize("common.close", comment: "通用关闭按钮 accessibility label") }
    static var auditPassedMessage: String           { localize("audit.passed.message", comment: "主播审核通过 alert 文案（H5 固定英文原文）") }
    static var auditRejectedFallback: String        { localize("audit.rejected.fallback", comment: "主播审核拒绝 payload.content 空时 fallback") }
    static var userProfileA11yAvatar: String        { localize("userProfile.a11y.avatar", comment: "无障碍：头像 label") }
    static var userProfileA11yMenu: String          { localize("userProfile.a11y.menu", comment: "无障碍：菜单按钮 label") }
    static var userProfileA11yGiftFallback: String  { localize("userProfile.a11y.giftFallback", comment: "无障碍：礼物 name 为 nil 时兜底") }

    // Report sheet（对齐 H5 c-feedbackPopup type='userProfile' 分支）
    static var reportTitle: String                  { localize("report.title", comment: "举报 sheet 标题 + 提交按钮") }
    static var reportReasonIncorrect: String        { localize("report.reason.incorrect", comment: "原因：信息不准") }
    static var reportReasonSexual: String           { localize("report.reason.sexual", comment: "原因：色情内容") }
    static var reportReasonHarassment: String       { localize("report.reason.harassment", comment: "原因：骚扰/恶意言语") }
    static var reportReasonUnreasonable: String     { localize("report.reason.unreasonable", comment: "原因：不合理要求") }
    static var reportDescriptionLabel: String       { localize("report.description.label", comment: "描述输入区 label") }
    static var reportDescriptionPlaceholder: String { localize("report.description.placeholder", comment: "描述输入区 placeholder") }
    static var reportSuccessToast: String           { localize("report.success.toast", comment: "举报成功 toast") }
    static var commonOther: String                  { localize("common.other", comment: "通用：其他") }
    static var commonNetworkError: String           { localize("common.networkError", comment: "网络请求错误兜底文案") }
    static var commonRetry: String                  { localize("common.retry", comment: "重试按钮") }
    static var commonWeekly: String                 { localize("common.weekly", comment: "周（对齐 H5 common.weekly）") }
    static var commonMonthly: String                { localize("common.monthly", comment: "月（对齐 H5 common.monthly）") }
    static var commonThisWeek: String               { localize("common.thisWeek", comment: "本周") }
    static var commonLastWeek: String               { localize("common.lastWeek", comment: "上周") }
    static var commonThisMonth: String              { localize("common.thisMonth", comment: "本月") }
    static var commonLastMonth: String              { localize("common.lastMonth", comment: "上月") }
    static var commonTwoMonthsAgo: String           { localize("common.twoMonthsAgo", comment: "两个月前") }
    static var commonDate: String                   { localize("common.date", comment: "日期 label") }
    static var commonIncome: String                 { localize("common.income", comment: "收益 label") }

    // MARK: - Phase B 直播数据页（对齐 H5 views/liveData/index.vue）
    static var liveDataNavTitle: String             { localize("liveData.navTitle", comment: "Live Stream Data") }
    static var liveDataTotalData: String            { localize("liveData.totalData", comment: "Total Data") }
    static var liveDataTotalDuration: String        { localize("liveData.totalDuration", comment: "Total Duration") }
    static var liveDataTotalIncome: String          { localize("liveData.totalIncome", comment: "Total Income") }
    static var liveDataDetailData: String           { localize("liveData.detailData", comment: "Detail Data") }
    static var liveDataLiveIncome: String           { localize("liveData.liveIncome", comment: "Live Income") }
    static var liveDataPrivateCallIncome: String    { localize("liveData.privateCallIncome", comment: "Private Call Income") }
    static var liveDataLiveDuration: String         { localize("liveData.liveDuration", comment: "Live Duration") }
    static var liveDataTimeRemaining: String        { localize("liveData.timeRemaining", comment: "Time Remaining:") }
    static var liveDataDays: String                 { localize("liveData.days", comment: "days") }
    static var liveDataExpand: String               { localize("liveData.expand", comment: "展开：无障碍") }
    static var liveDataCollapse: String             { localize("liveData.collapse", comment: "收起：无障碍") }

    // MARK: - Party Data 派对数据看板（对齐安卓 PartyRoomDataActivity；analysis §3）
    static var partyDataNavTitle: String            { localize("partyData.navTitle", comment: "Party Data") }
    static var partyDataTotalMicTime: String        { localize("partyData.totalMicTime", comment: "Total Mic Time") }
    static var partyDataMicTime: String             { localize("partyData.micTime", comment: "Mic Time · daily row label") }
    static var partyDataTotalIncome: String         { localize("partyData.totalIncome", comment: "Total Income") }
    static var partyDataGiftIncome: String          { localize("partyData.giftIncome", comment: "Party Gift Income") }
    static var partyDataCallIncome: String          { localize("partyData.callIncome", comment: "Partycall Income (calls+gifts merged)") }

    // Party Data 规则 sheet (对齐安卓 PartyRoomDataRuleActivity 4 小节)
    static var partyDataRuleNavTitle: String        { localize("partyData.rule.navTitle", comment: "Party Data Rules") }
    static var partyDataRuleSection1: String        { localize("partyData.rule.section1", comment: "Basic Information") }
    static var partyDataRuleSection2: String        { localize("partyData.rule.section2", comment: "Mic Time Rules") }
    static var partyDataRuleSection3: String        { localize("partyData.rule.section3", comment: "Income Composition") }
    static var partyDataRuleSection4: String        { localize("partyData.rule.section4", comment: "Display Rules") }
    static var partyDataRuleTitle1: String          { localize("partyData.rule.title1", comment: "Data Update Cycle:") }
    static var partyDataRuleContent1: String        { localize("partyData.rule.content1", comment: "Content 1") }
    static var partyDataRuleTitle2: String          { localize("partyData.rule.title2", comment: "Statistical Rules:") }
    static var partyDataRuleContent2: String        { localize("partyData.rule.content2", comment: "Content 2") }
    static var partyDataRuleTitle3: String          { localize("partyData.rule.title3", comment: "Income Sources:") }
    static var partyDataRuleContent3: String        { localize("partyData.rule.content3", comment: "Content 3") }
    static var partyDataRuleTitle4: String          { localize("partyData.rule.title4", comment: "Display Rules:") }
    static var partyDataRuleContent4: String        { localize("partyData.rule.content4", comment: "Content 4") }

    // Party 麦时二级页
    static var partyMicTimeDetailTitle: String      { localize("party.micTimeDetail.title", comment: "Mic Time by Room") }
    static var partyMicTimeTotal: String            { localize("party.micTime.total", comment: "Total") }
    static var partyMicTimeVoice: String            { localize("party.micTime.voice", comment: "Voice") }
    static var partyMicTimeVideo: String            { localize("party.micTime.video", comment: "Video") }
    static var partyMicTimeEmpty: String            { localize("party.micTime.empty", comment: "No mic time data yet") }

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

    // MARK: - EditProfile 用户资料编辑页（I 里程碑，对齐 H5 anchor-livechat-h5/src/views/profile/index.vue）
    enum EditProfile {
        // 顶栏 & 通用
        static var navTitle: String              { localize("editProfile.navTitle", comment: "编辑页导航标题") }
        static var confirm: String               { localize("editProfile.confirm", comment: "保存 / Confirm 按钮") }
        static var cancel: String                { localize("editProfile.cancel", comment: "取消按钮") }

        // Section 标题 & hint
        static var sectionBasicTitle: String     { localize("editProfile.section.basic.title", comment: "基本信息 section") }
        static var sectionBasicHint: String      { localize("editProfile.section.basic.hint", comment: "基本信息 section 提示") }
        static var sectionPhotosTitleFormat: String  { localize("editProfile.section.photos.titleFormat", comment: "Photos (%d/9)") }
        static var sectionVideosTitleFormat: String  { localize("editProfile.section.videos.titleFormat", comment: "Videos (%d/6)") }
        static var sectionCallVideoTitle: String { localize("editProfile.section.callVideo.title", comment: "来电视频 section 标题") }
        static var sectionCallVideoHint: String  { localize("editProfile.section.callVideo.hint", comment: "来电视频 section 提示") }
        static var sectionGreetMsgsTitle: String { localize("editProfile.section.greetMsgs.title", comment: "问候语 section 标题") }
        static var sectionGreetMsgsHint: String  { localize("editProfile.section.greetMsgs.hint", comment: "问候语 section 提示") }
        static var sectionGreetMsgsReviewingTitle: String { localize("editProfile.section.greetMsgs.reviewingTitle", comment: "问候语 - 审核中分组标题") }

        // 昵称
        static var nicknameLabel: String         { localize("editProfile.nickname.label", comment: "昵称字段标签") }
        static var nicknamePlaceholder: String   { localize("editProfile.nickname.placeholder", comment: "昵称 sheet 占位") }
        static var nicknameEditTitle: String     { localize("editProfile.nickname.editTitle", comment: "昵称编辑 sheet 顶部标题") }
        static func nicknameWordCountFormat(_ count: Int) -> String {
            String(format: localize("editProfile.nickname.wordCountFormat", comment: "%d/15"), count)
        }

        // 简介
        static var bioLabel: String              { localize("editProfile.bio.label", comment: "简介标签") }
        static var bioPlaceholder: String        { localize("editProfile.bio.placeholder", comment: "简介占位") }
        static func bioWordCountFormat(_ count: Int) -> String {
            String(format: localize("editProfile.bio.wordCountFormat", comment: "%d/200"), count)
        }

        // 问候语
        static var greetMsgAddButton: String     { localize("editProfile.greetMsg.addButton", comment: "问候语添加按钮") }
        static var greetMsgPlaceholder: String   { localize("editProfile.greetMsg.placeholder", comment: "问候语输入占位") }
        static func greetMsgWordCountFormat(_ count: Int) -> String {
            String(format: localize("editProfile.greetMsg.wordCountFormat", comment: "%d/50"), count)
        }

        // 审核中徽章
        static var badgeInReview: String         { localize("editProfile.badge.inReview", comment: "In Review 胶囊") }

        // Load error / Success / Discard / SizeAlert
        static var loadErrorTitle: String        { localize("editProfile.loadError.title", comment: "加载失败标题") }
        static var loadErrorRetry: String        { localize("editProfile.loadError.retry", comment: "加载失败重试按钮") }
        static var successDialogTitle: String    { localize("editProfile.success.title", comment: "保存成功提示（提交审核）") }
        static var successDialogConfirm: String  { localize("editProfile.success.confirm", comment: "成功弹窗确认按钮") }
        static var discardTitle: String          { localize("editProfile.discard.title", comment: "放弃编辑弹窗标题") }
        static var discardMessage: String        { localize("editProfile.discard.message", comment: "放弃编辑弹窗内容") }
        static var discardConfirm: String        { localize("editProfile.discard.confirm", comment: "放弃编辑 - Discard 按钮") }
        static var discardKeep: String           { localize("editProfile.discard.keep", comment: "放弃编辑 - 继续编辑按钮") }
        static var sizeAlertTitle: String        { localize("editProfile.sizeAlert.title", comment: "上传大小错误标题") }
        static var sizeAlertOK: String           { localize("editProfile.sizeAlert.ok", comment: "上传大小错误 OK 按钮") }

        // Toasts
        static var toastPhotosLimit: String      { localize("editProfile.toast.photosLimit", comment: "相册达上限") }
        static var toastVideosLimit: String      { localize("editProfile.toast.videosLimit", comment: "视频达上限") }
        static var toastUploading: String        { localize("editProfile.toast.uploading", comment: "上传中 toast") }
        static var toastUploadFailed: String     { localize("editProfile.toast.uploadFailed", comment: "上传失败 toast") }
        static var toastUploadTimeout: String    { localize("editProfile.toast.uploadTimeout", comment: "上传超时 toast") }
        static var toastImageTooLarge: String    { localize("editProfile.toast.imageTooLarge", comment: "图片过大 toast") }
        static var toastVideoTooLarge: String    { localize("editProfile.toast.videoTooLarge", comment: "视频过大 toast") }
        static var toastVideoFormatUnsupported: String { localize("editProfile.toast.videoFormatUnsupported", comment: "视频格式不支持 toast") }
        static var toastAvatarInReview: String   { localize("editProfile.toast.avatarInReview", comment: "头像审核中点击 toast") }
        static var toastNicknameInReview: String { localize("editProfile.toast.nicknameInReview", comment: "昵称/资料审核中点击 toast") }
        static var toastNetworkError: String     { localize("editProfile.toast.networkError", comment: "网络错误 toast") }
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
    static var matchToastImOffline: String {
        localize("match.toast.imOffline", comment: "IM 离线 toast")
    }
    /// Gap-5：非匹配来电接通挂断后的 Resume Match 确认 Alert
    static var matchResumeAlertTitle: String {
        localize("match.resumeAlert.title", comment: "Resume Match Alert 标题")
    }
    static var matchResumeAlertMessage: String {
        localize("match.resumeAlert.message", comment: "Resume Match Alert 正文")
    }
    static var matchResumeAlertConfirm: String {
        localize("match.resumeAlert.confirm", comment: "Resume Match Alert 确认按钮")
    }
    static var matchResumeAlertCancel: String {
        localize("match.resumeAlert.cancel", comment: "Resume Match Alert 取消按钮")
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

    // MARK: v10 Wishlist 全套 + 心愿达成飘屏（2026-07-08 —— 对齐 H5 wishlist/wishlist-anchor-panel）
    static var wishlistProgressComplete: String { localize("wishlist.progress.complete", comment: "心愿达成态文案 Complete") }
    /// %@ 主播昵称
    static var wishlistPanelTitle: String { localize("wishlist.panel.title", comment: "面板标题 %@'s wish list for this round") }
    static var wishlistPanelSubtitle: String { localize("wishlist.panel.subtitle", comment: "面板副标题") }
    static var wishlistPanelEmpty: String { localize("wishlist.panel.empty", comment: "本场未设置心愿单") }
    static var wishlistTop6Title: String { localize("wishlist.panel.top6Title", comment: "Top Gifters 标题") }
    static var wishlistTop6Empty: String { localize("wishlist.panel.top6Empty", comment: "Top6 说明文案") }
    static var wishlistFloatComplete: String { localize("wishlist.float.complete", comment: "心愿达成横幅前缀") }
    static var wishlistFloatThanks: String { localize("wishlist.float.thanks", comment: "心愿达成横幅感谢语") }
    static var wishlistTop1Prefix: String { localize("wishlist.top1.prefix", comment: "TOP1 公屏昵称后的前缀") }
    static var wishlistTop1Suffix: String { localize("wishlist.top1.suffix", comment: "TOP1 公屏标签后的后缀") }

    // MARK: - A-2 新主播注册流程一期（en；ar/tr Step 4 by /i18n translate）
    enum Register {
        // 标题
        static var titleBasicInfo: String { localize("register.title.basicInfo", comment: "P1 顶部标题 基本资料") }
        static var titleRequired: String { localize("register.title.required", comment: "P2 顶部标题 必填资料") }
        static var titleVideoGuide: String { localize("register.title.videoGuide", comment: "视频录制引导弹窗标题") }
        // 字段 label
        static var fieldNickname: String { localize("register.field.nickname", comment: "昵称字段 placeholder") }
        static var fieldBirthday: String { localize("register.field.birthday", comment: "生日字段") }
        static var fieldCountry: String { localize("register.field.country", comment: "国家字段") }
        static var fieldInviteCode: String { localize("register.field.inviteCode", comment: "邀请码字段") }
        static var fieldInviteCodeOptional: String { localize("register.field.inviteCodeOptional", comment: "邀请码可选提示") }
        static var fieldRequiredFields: String { localize("register.field.requiredFields", comment: "Page 1 进入必填资料 row 文案") }
        static var fieldYourLanguage: String { localize("register.field.yourLanguage", comment: "Page 2 语言标题") }
        static var fieldSelectLanguage: String { localize("register.field.selectLanguage", comment: "语言 field placeholder") }
        static func fieldYourPhotos(_ minCount: Int) -> String {
            String(format: localize("register.field.yourPhotos", comment: "Photos 标题带 min N"), minCount)
        }
        static var fieldTakeVideo: String { localize("register.field.takeVideo", comment: "视频卡片标题") }
        // 操作按钮
        static var actionSignUp: String { localize("register.action.signUp", comment: "Page 1 底部按钮") }
        static var actionUpload: String { localize("register.action.upload", comment: "Page 2 底部按钮 未上传态") }
        static var actionEdit: String { localize("register.action.edit", comment: "Page 2 底部按钮 已上传态") }
        static var actionRerecord: String { localize("register.action.rerecord", comment: "预览页重录按钮") }
        static var actionGoToRecord: String { localize("register.action.goToRecord", comment: "视频引导弹窗按钮") }
        static func actionConfirmN(_ n: Int) -> String {
            String(format: localize("register.action.confirmN", comment: "Confirm(N) 按钮"), n)
        }
        static var actionCancel: String { localize("register.action.cancel", comment: "取消") }
        static var actionLanguageTitle: String { localize("register.action.languageTitle", comment: "语言弹窗顶部 title") }
        // 视频引导文案
        static func videoGuideBody(_ seconds: Int) -> String {
            String(format: localize("register.video.guideBody", comment: "视频引导长文案 %d 秒"), seconds)
        }
        static var videoDiscardConfirm: String { localize("register.video.discardConfirm", comment: "录制中 back 二次确认") }
        // 错误文案（toast / alert）
        static var errorAvatarRequired: String { localize("register.error.avatarRequired", comment: "缺头像") }
        static var errorNicknameRequired: String { localize("register.error.nicknameRequired", comment: "缺昵称") }
        static var errorBirthdayRequired: String { localize("register.error.birthdayRequired", comment: "缺生日") }
        static var errorCountryRequired: String { localize("register.error.countryRequired", comment: "缺国家") }
        static var errorLanguageRequired: String { localize("register.error.languageRequired", comment: "缺语言") }
        static var errorLanguageMax: String { localize("register.error.languageMax", comment: "语言超上限 4") }
        static func errorPhotosMin(_ minCount: Int) -> String {
            String(format: localize("register.error.photosMin", comment: "照片少于 %d"), minCount)
        }
        static var errorVideoRequired: String { localize("register.error.videoRequired", comment: "缺视频") }
        static var errorCameraDenied: String { localize("register.error.cameraDenied", comment: "相机权限拒") }
        static var errorMicDenied: String { localize("register.error.micDenied", comment: "麦克风权限拒") }
        static var errorRecordInterrupted: String { localize("register.error.recordInterrupted", comment: "录制中断") }
        static var errorCompressFailed: String { localize("register.error.compressFailed", comment: "视频压缩失败") }
        static var errorUploadFailed: String { localize("register.error.uploadFailed", comment: "上传失败通用") }
        static func errorImageTooLarge(_ maxMB: Int) -> String {
            String(format: localize("register.error.imageTooLarge", comment: "图片超原图硬顶 %d MB"), maxMB)
        }
        static var errorServerTemporary: String { localize("register.error.serverTemporary", comment: "服务端临时错误（空 body / 非 JSON / 5xx），提示用户重试") }
    }

    // MARK: - Wallet (native income, withdrawal and active liveness)
    enum Wallet {
        static var title: String { localize("wallet.title", comment: "Wallet page title") }
        static var balance: String { localize("wallet.balance", comment: "Wallet balance") }
        static var withdrawal: String { localize("wallet.withdrawal", comment: "Withdrawal entry") }
        static var todayIncome: String { localize("wallet.todayIncome", comment: "Wallet today income") }
        static var incomeDetails: String { localize("wallet.incomeDetails", comment: "Income ledger title") }
        static var filterCall: String { localize("wallet.filter.call", comment: "Ledger call filter") }
        static var filterGift: String { localize("wallet.filter.gift", comment: "Ledger gift filter") }
        static var filterTask: String { localize("wallet.filter.task", comment: "Ledger task filter") }
        static var filterInvite: String { localize("wallet.filter.invite", comment: "Ledger invite filter") }
        static var filterMessage: String { localize("wallet.filter.message", comment: "Ledger message filter") }
        static var filterInteraction: String { localize("wallet.filter.interaction", comment: "Ledger interaction filter") }
        static var filterOthers: String { localize("wallet.filter.others", comment: "Ledger other filter") }
        static var time: String { localize("wallet.time", comment: "Ledger time column") }
        static var source: String { localize("wallet.source", comment: "Ledger source column") }
        static var user: String { localize("wallet.user", comment: "Ledger user column") }
        static var detail: String { localize("wallet.detail", comment: "Ledger detail column") }
        static var income: String { localize("wallet.income", comment: "Ledger income column") }
        static var withdrawCash: String { localize("wallet.withdrawCash", comment: "Submit withdrawal") }
        static var cashableBalance: String { localize("wallet.cashableBalance", comment: "Cashable balance") }
        static var withdrawalBalance: String { localize("wallet.withdrawalBalance", comment: "Withdrawal-only balance") }
        static var inviteEntry: String { localize("wallet.inviteEntry", comment: "Invite entry") }
        static var records: String { localize("wallet.records", comment: "Withdrawal records") }
        static var selectAccount: String { localize("wallet.selectAccount", comment: "Select withdrawal account") }
        static var manageAccounts: String { localize("wallet.manageAccounts", comment: "Manage withdrawal accounts") }
        static var addAccount: String { localize("wallet.addAccount", comment: "Add withdrawal account") }
        static var collection: String { localize("wallet.collection", comment: "Collection method") }
        static var enterAmount: String { localize("wallet.enterAmount", comment: "Enter withdrawal amount") }
        static var availableBalance: String { localize("wallet.availableBalance", comment: "Available diamond balance") }
        static var amountPlaceholder: String { localize("wallet.amountPlaceholder", comment: "Withdrawal amount placeholder") }
        static var estimatedReceive: String { localize("wallet.estimatedReceive", comment: "Estimated receipt") }
        static var withdrawalSummary: String { localize("wallet.withdrawalSummary", comment: "Withdrawal quote title") }
        static var grossAmount: String { localize("wallet.grossAmount", comment: "Withdrawal gross amount") }
        static var fee: String { localize("wallet.fee", comment: "Withdrawal fee") }
        static var finalAmount: String { localize("wallet.finalAmount", comment: "Withdrawal final amount") }
        static var remainderReturned: String { localize("wallet.remainderReturned", comment: "Diamond remainder return note") }
        static var cancel: String { localize("wallet.cancel", comment: "Wallet cancel") }
        static var confirm: String { localize("wallet.confirm", comment: "Wallet confirm") }
        static var collectionType: String { localize("wallet.collectionType", comment: "Collection account type") }
        static var collectionDetails: String { localize("wallet.collectionDetails", comment: "Collection details") }
        static var accountName: String { localize("wallet.accountName", comment: "Epay collection name") }
        static var accountIrreversible: String { localize("wallet.accountIrreversible", comment: "Collection warning") }
        static var digifinexMinimum: String { localize("wallet.digifinexMinimum", comment: "Digifinex minimum") }
        static var epayMinimum: String { localize("wallet.epayMinimum", comment: "Epay minimum") }
        static var uidPlaceholder: String { localize("wallet.uidPlaceholder", comment: "Digifinex UID placeholder") }
        static var addressPlaceholder: String { localize("wallet.addressPlaceholder", comment: "USDT address placeholder") }
        static var emailPlaceholder: String { localize("wallet.emailPlaceholder", comment: "Epay email placeholder") }
        static var removeAccount: String { localize("wallet.removeAccount", comment: "Remove account") }
        static var remove: String { localize("wallet.remove", comment: "Destructive confirmation") }
        static var removeAccountDetail: String { localize("wallet.removeAccountDetail", comment: "Remove account confirmation") }
        static var orderNumber: String { localize("wallet.orderNumber", comment: "Withdrawal order number") }
        static var applicationStatus: String { localize("wallet.applicationStatus", comment: "Withdrawal application status") }
        static var reviewing: String { localize("wallet.reviewing", comment: "Withdrawal reviewing state") }
        static var paid: String { localize("wallet.paid", comment: "Withdrawal paid state") }
        static var rejected: String { localize("wallet.rejected", comment: "Withdrawal rejected state") }
        static var loadFailed: String { localize("wallet.loadFailed", comment: "Wallet load failure") }
        static var accountInfoRequired: String { localize("wallet.accountInfoRequired", comment: "Required account information") }
        static var accountTypeInvalid: String { localize("wallet.accountTypeInvalid", comment: "Invalid account type") }
        static var accountAdded: String { localize("wallet.accountAdded", comment: "Account saved") }
        static var accountSaveFailed: String { localize("wallet.accountSaveFailed", comment: "Account save failure") }
        static var accountRemoved: String { localize("wallet.accountRemoved", comment: "Account removed") }
        static var accountRemoveFailed: String { localize("wallet.accountRemoveFailed", comment: "Account remove failure") }
        static var integerAmount: String { localize("wallet.integerAmount", comment: "Whole number amount required") }
        static var amountExceedsBalance: String { localize("wallet.amountExceedsBalance", comment: "Amount exceeds balance") }
        static var minimumDiamond: String { localize("wallet.minimumDiamond", comment: "Minimum 200 diamonds") }
        static var minimumRate: String { localize("wallet.minimumRate", comment: "Minimum exchange rate") }
        static var channelMinimum: String { localize("wallet.channelMinimum", comment: "Channel minimum") }
        static var verificationCheckFailed: String { localize("wallet.verificationCheckFailed", comment: "Face verification preflight failure") }
        static var passwordSixDigits: String { localize("wallet.passwordSixDigits", comment: "Six digit password required") }
        static var passwordSet: String { localize("wallet.passwordSet", comment: "Withdrawal password set") }
        static var withdrawalSubmitted: String { localize("wallet.withdrawalSubmitted", comment: "Withdrawal submitted") }
        static var withdrawalSubmitFailed: String { localize("wallet.withdrawalSubmitFailed", comment: "Withdrawal submit failed") }
        static var setPassword: String { localize("wallet.setPassword", comment: "Set withdrawal password") }
        static var setPasswordDetail: String { localize("wallet.setPasswordDetail", comment: "Set password guidance") }
        static var enterPassword: String { localize("wallet.enterPassword", comment: "Enter withdrawal password") }
        static var enterPasswordDetail: String { localize("wallet.enterPasswordDetail", comment: "Enter password guidance") }
        static var passwordPlaceholder: String { localize("wallet.passwordPlaceholder", comment: "Password input placeholder") }
        static var forgotPassword: String { localize("wallet.forgotPassword", comment: "Withdrawal password recovery") }
        static var livenessFailedTitle: String { localize("wallet.livenessFailedTitle", comment: "Liveness failure title") }
        static var retry: String { localize("wallet.retry", comment: "Retry active liveness") }
        static var livenessShakeTitle: String { localize("wallet.livenessShakeTitle", comment: "Shake challenge title") }
        static var livenessShakeDetail: String { localize("wallet.livenessShakeDetail", comment: "Shake challenge detail") }
        static var livenessNodTitle: String { localize("wallet.livenessNodTitle", comment: "Nod challenge title") }
        static var livenessNodDetail: String { localize("wallet.livenessNodDetail", comment: "Nod challenge detail") }
        static var livenessFrontTitle: String { localize("wallet.livenessFrontTitle", comment: "Front challenge title") }
        static var livenessFrontDetail: String { localize("wallet.livenessFrontDetail", comment: "Front challenge detail") }
        static var livenessVerifying: String { localize("wallet.livenessVerifying", comment: "Face verification progress") }
        static var livenessVerifyingDetail: String { localize("wallet.livenessVerifyingDetail", comment: "Face verification detail") }
        static var cameraPermissionRequired: String { localize("wallet.cameraPermissionRequired", comment: "Camera permission failure") }
        static var livenessCameraUnavailable: String { localize("wallet.livenessCameraUnavailable", comment: "Camera setup failure") }
        static var livenessNoFace: String { localize("wallet.livenessNoFace", comment: "No face failure") }
        static var livenessTimedOut: String { localize("wallet.livenessTimedOut", comment: "Liveness timeout") }
        static var livenessUploadFailed: String { localize("wallet.livenessUploadFailed", comment: "Face upload failure") }
    }

    // MARK: - Lottery (native activity chance draw)
    enum Lottery {
        static var title: String { localize("lottery.title", comment: "Activity lottery title fallback") }
        static var loadFailed: String { localize("lottery.loadFailed", comment: "Lottery activity load failure") }
        static var unsupportedPrizeLayout: String { localize("lottery.unsupportedPrizeLayout", comment: "Unsupported prize grid count") }
        static var noPrizeReturned: String { localize("lottery.noPrizeReturned", comment: "Draw response missing prize list") }
        static var pleaseWait: String { localize("lottery.pleaseWait", comment: "Lottery action is in progress") }
        static var notStarted: String { localize("lottery.notStarted", comment: "Lottery activity not started") }
        static var ended: String { localize("lottery.ended", comment: "Lottery activity ended") }
        static var insufficientChances: String { localize("lottery.insufficientChances", comment: "Lottery chance balance insufficient") }
        static var drawFailed: String { localize("lottery.drawFailed", comment: "Lottery draw failed") }
        static var drawReconciled: String { localize("lottery.drawReconciled", comment: "Lottery draw result uncertain and refreshed") }
        static var records: String { localize("lottery.records", comment: "Lottery reward records") }
        static var recordsLoadFailed: String { localize("lottery.recordsLoadFailed", comment: "Lottery record load failure") }
        static var recordsEmpty: String { localize("lottery.recordsEmpty", comment: "Lottery records empty") }
        static var recordsEnd: String { localize("lottery.recordsEnd", comment: "Lottery records pagination end") }
        static var oneTime: String { localize("lottery.oneTime", comment: "Draw once") }
        static var fiveTimes: String { localize("lottery.fiveTimes", comment: "Draw five times") }
        static var draw: String { localize("lottery.draw", comment: "Center draw action") }
        static var congratulations: String { localize("lottery.congratulations", comment: "Lottery result title") }
        static var earnChancesHint: String { localize("lottery.earnChancesHint", comment: "How to earn lottery chances") }
        static var earnChancesPartyHint: String { localize("lottery.earnChancesPartyHint", comment: "How to earn lottery chances in Party only activity") }
        static var go: String { localize("lottery.go", comment: "Lottery persistent room guidance action") }
        static var insufficientTitle: String { localize("lottery.insufficientTitle", comment: "Insufficient lottery chances popup title") }
        static var insufficientMessage: String { localize("lottery.insufficientMessage", comment: "Insufficient lottery chances popup message") }
        static var goPartyRoom: String { localize("lottery.goPartyRoom", comment: "Lottery insufficient popup Party destination") }
        static var goLiveRoom: String { localize("lottery.goLiveRoom", comment: "Lottery insufficient popup Live destination") }
        static var noPartyRoomsAvailable: String { localize("lottery.noPartyRoomsAvailable", comment: "Lottery Party destination has no room") }
        static var noLiveAvailable: String { localize("lottery.noLiveAvailable", comment: "Lottery Live destination has no room") }
        static var roomNavigationFailed: String { localize("lottery.roomNavigationFailed", comment: "Lottery destination request failed") }
        static var startsIn: String { localize("lottery.startsIn", comment: "Lottery countdown before start") }
        static var endsIn: String { localize("lottery.endsIn", comment: "Lottery countdown before end") }
        static var remainingChancesFormat: String { localize("lottery.remainingChancesFormat", comment: "Remaining lottery chances %d") }
        static var pointsNeededFormat: String { localize("lottery.pointsNeededFormat", comment: "Points still needed for a chance %d") }
        static var dailyLimitFormat: String { localize("lottery.dailyLimitFormat", comment: "Daily chance limit %d/%d") }
        static var dailyLimitReached: String { localize("lottery.dailyLimitReached", comment: "Daily chance limit reached without configured quota") }
        static var winnerFormat: String { localize("lottery.winnerFormat", comment: "Lottery winner marquee %@ %@") }
        static var validDaysFormat: String { localize("lottery.validDaysFormat", comment: "Prize valid days %d") }
        static var quantityFormat: String { localize("lottery.quantityFormat", comment: "Prize quantity %d") }
    }

    // MARK: - Invite（安卓主播端为行为基准）
    enum Invite {
        static var title: String { localize("invite.title", comment: "邀请页标题") }
        static var inviteUser: String { localize("invite.user", comment: "邀请用户") }
        static var inviteAnchor: String { localize("invite.anchor", comment: "邀请主播") }
        static var myRewards: String { localize("invite.myRewards", comment: "我的奖励") }
        static var totalBonus: String { localize("invite.totalBonus", comment: "总邀请奖励") }
        static var last7Days: String { localize("invite.last7Days", comment: "最近七天邀请") }
        static var last7DaysUser: String { localize("invite.last7DaysUser", comment: "最近 7 天邀请用户") }
        static var last7DaysAnchor: String { localize("invite.last7DaysAnchor", comment: "最近 7 天邀请主播") }
        static var got: String { localize("invite.got", comment: "获得") }
        static var rules: String { localize("invite.rules", comment: "邀请规则") }
        static var lifetimeReward: String { localize("invite.lifetimeReward", comment: "一次邀请长期收益") }
        static func userRewardHint(_ reward: String) -> String {
            String(format: localize("invite.userRewardHintFormat", comment: "邀请用户收益提示，%@ = 奖励比例"), reward)
        }
        static func anchorRewardHint(_ reward: String) -> String {
            String(format: localize("invite.anchorRewardHintFormat", comment: "邀请主播收益提示，%@ = 收益比例"), reward)
        }
        static var userCommission: String { localize("invite.userCommission", comment: "用户返佣") }
        static var anchorCommission: String { localize("invite.anchorCommission", comment: "主播返佣") }
        static var partyCommission: String { localize("invite.partyCommission", comment: "派对房返佣") }
        static var inviteCode: String { localize("invite.code", comment: "邀请码") }
        static var copyCode: String { localize("invite.copyCode", comment: "复制邀请码") }
        static var details: String { localize("invite.details", comment: "明细") }
        static var totalUsers: String { localize("invite.totalUsers", comment: "累计邀请用户") }
        static var totalAnchors: String { localize("invite.totalAnchors", comment: "累计邀请主播") }
        static var cumulativeReward: String { localize("invite.cumulativeReward", comment: "累计奖励") }
        static var inviteNow: String { localize("invite.now", comment: "立即邀请") }
        static var bigReward: String { localize("invite.bigReward", comment: "高额奖励提示") }
        static var copySuccess: String { localize("invite.copySuccess", comment: "邀请复制成功") }
        static var shareUnavailable: String { localize("invite.shareUnavailable", comment: "暂无可分享内容") }
        static var shareUser: String { localize("invite.shareUser", comment: "分享邀请用户") }
        static var shareAnchor: String { localize("invite.shareAnchor", comment: "分享邀请主播") }
        static var saveAndShare: String { localize("invite.saveAndShare", comment: "保存并分享") }
        static var copyLink: String { localize("invite.copyLink", comment: "复制链接") }
        static var share: String { localize("invite.share", comment: "分享") }
        static var showQRCode: String { localize("invite.showQRCode", comment: "显示邀请二维码") }
        static func userID(_ value: String) -> String {
            String(format: localize("invite.idFormat", comment: "邀请用户 ID，%@ = 用户 ID"), value)
        }
        static func uid(_ value: String) -> String {
            String(format: localize("invite.uidFormat", comment: "邀请榜单 UID，%@ = 用户 ID"), value)
        }
        static var ruleUnavailable: String { localize("invite.ruleUnavailable", comment: "暂无邀请规则") }
        static var faq: String { localize("invite.faq", comment: "常见问题") }
        static var policy: String { localize("invite.policy", comment: "政策说明") }
        static var invitedUsers: String { localize("invite.invitedUsers", comment: "邀请用户列表") }
        static var rewardRecords: String { localize("invite.rewardRecords", comment: "奖励明细") }
        static var startDate: String { localize("invite.startDate", comment: "开始日期") }
        static var endDate: String { localize("invite.endDate", comment: "结束日期") }
        static var applyDate: String { localize("invite.applyDate", comment: "应用日期") }
        static var invalidDateRange: String { localize("invite.invalidDateRange", comment: "日期范围无效") }
        static var dataDetails: String { localize("invite.dataDetails", comment: "数据详情") }
        static var period: String { localize("invite.period", comment: "统计周期") }
        static var identifier: String { localize("invite.identifier", comment: "ID 列名") }
        static var user: String { localize("invite.userColumn", comment: "用户列名") }
        static var nickname: String { localize("invite.nickname", comment: "昵称列名") }
        static var totalIncome: String { localize("invite.totalIncome", comment: "总收益列名") }
        static var diamondIncome: String { localize("invite.diamondIncome", comment: "钻石收益列名") }
        static var dailyOutputReward: String { localize("invite.dailyOutputReward", comment: "每日产出奖励列名") }
        static var accumulatedRewards: String { localize("invite.accumulatedRewards", comment: "累计奖励列名") }
        static var invitationTime: String { localize("invite.invitationTime", comment: "邀请时间列名") }
        static var accumulatedRewardsDetail: String { localize("invite.accumulatedRewardsDetail", comment: "用户奖励详情累计奖励列名") }
        static var invitationTimeDetail: String { localize("invite.invitationTimeDetail", comment: "用户奖励详情邀请时间列名") }
        static var rewardQuantity: String { localize("invite.rewardQuantity", comment: "奖励数量列名") }
        static var today: String { localize("invite.today", comment: "今天") }
        static var thisWeek: String { localize("invite.thisWeek", comment: "本周") }
        static var lastWeek: String { localize("invite.lastWeek", comment: "上周") }
        static var lastMonth: String { localize("invite.lastMonth", comment: "上月") }
        static var referralIncomeReward: String { localize("invite.referralIncomeReward", comment: "推荐收益奖励") }
        static var myDashboard: String { localize("invite.myDashboard", comment: "我的看板") }
        static var cumulativeOutputReward: String { localize("invite.cumulativeOutputReward", comment: "累计产出奖励") }
        static var callIncome: String { localize("invite.callIncome", comment: "通话收益") }
        static var giftIncome: String { localize("invite.giftIncome", comment: "礼物收益") }
        static var connectionRate: String { localize("invite.connectionRate", comment: "接通率") }
        static var currentRanking: String { localize("invite.currentRanking", comment: "当前排名") }
        static var currentLevel: String { localize("invite.currentLevel", comment: "当前等级") }
        static var onlineDuration: String { localize("invite.onlineDuration", comment: "累计在线时长") }
        static var totalCallDuration: String { localize("invite.totalCallDuration", comment: "累计通话时长") }
        static var averageCallDuration: String { localize("invite.averageCallDuration", comment: "平均通话时长") }
        static var startChat: String { localize("invite.startChat", comment: "开始聊天") }
    }
}
