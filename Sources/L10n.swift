import Foundation

/// i18n 本地化 key 中转（B 里程碑 spec §13 i18n 声明）。
///
/// 当前仅 en 默认值；ar/tr 翻译由 J 里程碑收尾。
/// 引入 SwiftGen 后本文件可自动生成；B 阶段手工维护。
enum L10n {
    // 强制下播原因（UI 文案）
    static let forceEndDisconnected   = NSLocalizedString("forceEnd.disconnected", comment: "网络异常已断连")
    static let forceEndBanned         = NSLocalizedString("forceEnd.banned", comment: "账号违规已封禁")
    static let forceEndCameraFailure  = NSLocalizedString("forceEnd.cameraFailure", comment: "相机采集失败")
    static let forceEndNoPermission   = NSLocalizedString("forceEnd.noPermission", comment: "权限校验失败")
    static let forceEndWeakNetwork    = NSLocalizedString("forceEnd.weakNetwork", comment: "网络环境过差")

    // 美颜降级提示
    static let beautyUnavailableHint  = NSLocalizedString("beauty.unavailable", comment: "美颜不可用")

    // 网络弱网降级提示（v5 分层）
    static let networkWarning         = NSLocalizedString("network.warning", comment: "网络较差，已切换低帧率")

    // 开播前置校验
    static let prepareTitleEmpty      = NSLocalizedString("prepare.titleEmpty", comment: "请输入直播标题")
    static let prepareCoverEmpty      = NSLocalizedString("prepare.coverEmpty", comment: "请设置直播封面")
    static let prepareCooldown        = NSLocalizedString("prepare.cooldown", comment: "距上次下播不足 60 秒")
    static let prepareIMOffline       = NSLocalizedString("prepare.imOffline", comment: "聊天服务未连接，请稍后重试")

    // 公屏
    static let imChatroomReconnecting    = NSLocalizedString("im.chatroom.reconnecting", comment: "聊天室重连中...")
    static let imChatroomReconnected     = NSLocalizedString("im.chatroom.reconnected", comment: "聊天室已重连")
    static let userJoined                = NSLocalizedString("im.userJoined", comment: "有用户进入了直播间")
    static let sendGiftAction            = NSLocalizedString("im.sendGiftAction", comment: "送出")
    static let complianceWarningDefault  = NSLocalizedString("im.complianceWarningDefault", comment: "您的直播内容已被警告")
    static let anonymous                 = NSLocalizedString("im.anonymous", comment: "匿名")

    // MARK: - Work 工作台（设计稿还原）
    static let workWeeklyLevel    = NSLocalizedString("work.weeklyLevel", comment: "周等级")
    static let workDetail         = NSLocalizedString("work.detail", comment: "详情")
    static let workScorePrefix    = NSLocalizedString("work.scorePrefix", comment: "分数前缀")
    static let workNeedMoreFormat = NSLocalizedString("work.needMoreFormat", comment: "升级还需 %d 分")

    static let workCallsToday     = NSLocalizedString("work.callsToday", comment: "今日通话数")
    static let workPositiveRating = NSLocalizedString("work.positiveRating", comment: "好评率")
    static let workWeeklyRevenue  = NSLocalizedString("work.weeklyRevenue", comment: "周收益")

    static let workTodaysIncome   = NSLocalizedString("work.todaysIncome", comment: "今日收益")
    static let workWithdrawal     = NSLocalizedString("work.withdrawal", comment: "提现")
    static let workCallIncomes    = NSLocalizedString("work.callIncomes", comment: "通话收益")
    static let workGiftIncomes    = NSLocalizedString("work.giftIncomes", comment: "礼物收益")
    static let workTaskIncomes    = NSLocalizedString("work.taskIncomes", comment: "任务收益")
    static let workInviteIncomes  = NSLocalizedString("work.inviteIncomes", comment: "邀请收益")
    static let workManagedIncomes = NSLocalizedString("work.managedIncomes", comment: "管理收益")
    static let workTotalIncomes   = NSLocalizedString("work.totalIncomes", comment: "总收益")

    static let workTools          = NSLocalizedString("work.tools", comment: "工具")
    static let workOnline         = NSLocalizedString("work.online", comment: "在线")
    static let workOnlineOn       = NSLocalizedString("work.online.on", comment: "在线开关-开")
    static let workOnlineOff      = NSLocalizedString("work.online.off", comment: "在线开关-关")

    // 工具图标标签
    static let toolHi             = NSLocalizedString("work.tool.hi", comment: "打招呼")
    static let toolGoLive         = NSLocalizedString("work.tool.goLive", comment: "开播")
    static let toolMatch          = NSLocalizedString("work.tool.match", comment: "匹配")
    static let toolTask           = NSLocalizedString("work.tool.task", comment: "任务")
    static let toolBeauty         = NSLocalizedString("work.tool.beauty", comment: "美颜")
    static let toolPoints         = NSLocalizedString("work.tool.points", comment: "积分")
    static let toolGiftMessage    = NSLocalizedString("work.tool.giftMessage", comment: "礼物消息")
    static let toolProfileUpdate  = NSLocalizedString("work.tool.profileUpdate", comment: "资料更新")
    static let toolInvite         = NSLocalizedString("work.tool.invite", comment: "邀请")
    static let toolWorkingGuide   = NSLocalizedString("work.tool.workingGuide", comment: "工作指南")
    static let toolBackpack       = NSLocalizedString("work.tool.backpack", comment: "背包")

    // 底部 tab 标签
    static let tabHome            = NSLocalizedString("tab.home", comment: "首页")
    static let tabMessages        = NSLocalizedString("tab.messages", comment: "消息")
    static let tabWork            = NSLocalizedString("tab.work", comment: "工作台")
    static let tabProfile         = NSLocalizedString("tab.profile", comment: "我的")
}
