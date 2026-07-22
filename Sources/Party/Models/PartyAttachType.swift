import Foundation

/// 派对房 NIM 自定义消息 `attachType` 枚举（spec §1.4.2 + §1.0.2 第 9 条强制 enum 转换原则）。
///
/// **真值来源**：
/// - 用户提供的 "安卓主播端 IM 通知常量配置整理"§L 派对房运行时事件 + §M 房主视频位邀请
/// - `/Users/joe/Downloads/party房通知类型-安卓vsH5对比.md`（2026-07-14 · Android vs h5-ui 35 一致 + 16 Android 独有 + 3 h5-ui 独有）
///
/// **严格禁止**：项目内任何 attachType 判定**必须**经 `PartyAttachType(rawValue:)` 转换，
/// 禁止裸 Int 比较（参照安卓 `PartyRoomVM.kt:368` 裸 `1100..1112` 反例）。
///
/// **v3（2026-07-14）**：按对比文档全量扩充枚举。**不实装 handler 的类型也加 case 占位**，
/// Router switch 用占位群组集中 debug log；编译器 enum 穷尽保证不漏。
enum PartyAttachType: Int {

    // MARK: - 表情消息（占位 F 期）

    case emojiPlay = -11
    case emojiStatic = -10

    // MARK: - 全服/本房中奖公屏（Step 2 实装）

    /// 136 游戏中奖公屏通知（全服，主入口 session 通道，Party 通道兜底）
    case gameWinNotifyGlobal = 136
    /// 138 PK 小奖 / Party 房游戏小奖（本房）
    case pkSmallPrize = 138
    /// 140 活动中奖公屏广播（含 worldcup 世界杯活动卡）
    case winnerBroadcastGlobal = 140

    // MARK: - 核心房态信令（MVP 必接）

    /// 1001 麦位变化通知（gzip + Base64 压缩 payload）
    case seatUpdate = 1001
    /// 1003 被踢出派对房（双字段守护 userId+roomId 才退房，spec §1.4.4）
    case kickedOut = 1003

    // MARK: - 用户交互动效（已实装 EnterEffectCenter 独立通道）

    /// 1004 用户进场座驾动画（EnterEffectCenter 播放 SVGA/MP4，不上公屏）
    case userEnterVehicle = 1004

    /// 1007 明文送礼（老版本兜底；iOS 一刀切忽略，2049 与其双发去重）
    case giftLegacy = 1007

    /// 1008 麦克风/摄像头状态变化（视频位的 onMediaChange 入口）
    case updateMedia = 1008

    // MARK: - 房间/音乐/鉴黄（占位 F 期）

    case roomCloseOrWhitelist = 1009
    /// 1010 全房音乐总开关；payload `{ roomMusicSwitch: 0|1 }`。
    case musicMainSwitch = 1010
    case musicSongChange = 1011

    /// 1012 更新麦位列表（触发全量 `seat/list` 重拉）
    case seatUpdateList = 1012

    case musicSwitchPerUser = 1013
    case auditGuardWarning = 1014

    /// 1015 禁麦 / 解禁麦
    case prohibitMic = 1015

    /// 1016 锁房通知（h5-ui 空实现 `case 1016: break`）
    case roomLock = 1016

    // MARK: - Room Mode / Mic Application（已实装）

    /// 1017 切换房间模板广播（gzip+Base64）
    case changeMode = 1017
    /// 1018 排麦通知（op 1=申请 / 2=同意 / 3=拒绝 / 4=放弃）
    case queueSeatUpdate = 1018

    // MARK: - 房管变更（Step 2 实装：仅本人被设/取消）

    /// 1019 房管变更（仅本人被设/取消房管时公屏文案）
    case authUpdate = 1019

    /// 1020 拒接上麦通知（h5-ui 空实现 `case 1020: break`；iOS 拒麦走 1018 op=3）
    case rejectMicLegacy = 1020

    /// 1021 排麦开关广播（payload `{ enable: Int }` 0/1）
    case micApplicationSwitch = 1021

    // MARK: - 平台管理员 / 背景（占位 F 期）

    case platformAdminChange = 1024
    case roomBgUpdate = 1025
    case roomBgExpire = 1026

    // MARK: - 派对房私 call

    /// 1029 派对房私 call 状态通知（F · 聊天室通道 · payload.status ∈ {calling, ended}）
    /// Android 值冲突 GIFT_DOUBLED 走 P2P 通道；iOS 聊天室通道 decoder 严校验 status enum 区分
    case privateCallNotify = 1029

    // MARK: - 钻石盲盒（占位 F 期，Android 独有）

    case diamondGiftSend = 1030
    case diamondGiftGrab = 1031
    case diamondGiftSplit = 1032
    case diamondGiftSettle = 1033

    // MARK: - 视频位邀请（MVP 9 类）

    /// 1040 邀请上视频位（被邀请用户收到 → PartyStore.pendingVideoSeatInvite 弹窗）
    case inviteVideoSeat = 1040
    case inviteVideoSeatAccept = 1041
    case inviteVideoSeatReject = 1042
    case inviteVideoSeatTimeout = 1043
    case inviteVideoSeatLeave = 1044
    case inviteVideoSeatOccupied = 1045
    case inviteVideoSeatAlreadyOn = 1046
    /// 1047 视频位邀请接受公屏广播（Step 2 追加公屏系统消息）
    case inviteVideoSeatBroadcast = 1047
    case inviteVideoSeatJoinFailed = 1048

    // MARK: - 房间通告 / LuckyNumber（Step 2 实装）

    /// 1049 房间通告公屏广播
    case roomAnnouncement = 1049
    /// 1050 幸运数字抽数公屏卡片（⚠️ payload 直读 ext，不走 unwrapDataField）
    case luckyNumberDraw = 1050
    /// 1051 幸运数字中奖公屏广播（⚠️ payload 直读 ext）
    case luckyNumberWin = 1051
    /// 1052 幸运数字中奖个人弹窗（CustomSystemNotification 主路径消费；聊天室误投时仅降噪）
    case luckyNumberPersonalDialog = 1052

    // MARK: - PartyBattle（F-1a 落地 2026-07-17）· spec §5.1 attachType 1100-1112 分发

    /// 1100 SELECTING 开始（房主发起 PK → 服务端广播）
    case battleSelectingStart = 1100
    /// 1101 参战成员变化（切队 / 观众上麦 / 下麦）· preservePersonal 语义
    case battleTeamMemberChange = 1101
    /// 1102 观众上麦申请推送（H5 pushApply 无 role gating；观众也收但 UI 门控）
    case battleApplyReceived = 1102
    /// 1103 RUNNING 开始（SELECTING 归零或房主 startNow）
    case battleRunningStart = 1103
    /// 1104 保留（H5/spec 未消费；F-1a 走 fallback log）
    case battleHeartbeat = 1104
    /// 1105 分数板更新（200ms trailing 聚合入口）
    case battleLeaderboardUpdate = 1105
    /// 1106 皇冠归属变更
    case battleCrownHolderUpdate = 1106
    /// 1107 保留（H5/spec 未消费；F-1a 走 fallback log）
    case battleGiftNotify = 1107
    /// 1108 保留（H5/spec 未消费；F-1a 走 fallback log）
    case battleForceEndConfirm = 1108
    /// 1109 PK 结束（stub / full 分类由 payload.durationSec 存在与否判定）
    case battleEnd = 1109
    /// 1110 公屏广播（kind: victory / force_ended / mvp / selecting_started）
    case battleBroadcast = 1110
    /// 1111 保留（H5/spec 未消费；F-1a 走 fallback log）
    case battleApplyPendingNotice = 1111
    /// 1112 冷却结束（无 payload）
    case battleCooldownEnd = 1112

    // MARK: - 送礼压缩版（已实装）

    /// 2049 礼物压缩版（gzip + Base64；与 1007 双发去重 —— iOS 只识别 2049）
    case giftCompressed = 2049

    // MARK: - 转换辅助

    /// 与 init(rawValue:) 等价；语义上更明确"必须经此转换"，禁止裸 Int 比较。
    static func from(rawValue: Int) -> PartyAttachType? {
        PartyAttachType(rawValue: rawValue)
    }
}

/// E 期不识别但日志中可能出现的已知 attachType（用于"unrecognized" 时降噪辅助）。
/// v3（2026-07-14）：绝大多数已升级为 enum case，此处仅保留**未加 case** 的项。
enum PartyKnownButUnhandledAttachType {
    /// **未加 enum case** 的 Android 独有值 + 值冲突历史遗留。
    static let codes: Set<Int> = [
        // 值冲突（spec §1.0.2）—— 1029 已由 privateCallNotify 接管
        45,
        // Android 直播场景（非派对房）
        144,        // LIVE_SMALL_GAME_WIN_NOTICE
        195,        // LIVE_ROOM_ANNOUNCEMENT
        // Android 独有派对房但主播端暂不实装
        1002,       // INVITE_JOIN_PARTY_ROOM（P2P 邀请卡）
        1010,       // PARTY_ROOM_MUSIC_MAIN_SWITCH（全局音乐总开关）
    ]
}
