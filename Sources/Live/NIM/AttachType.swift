import Foundation

/// 云信 IM 自定义消息 `attachType` 业务全量枚举（H 里程碑 spec §2.3）。
///
/// 真值来源：`docs/plan/H-IM完善-spec-H5安卓代码二次校验-202606242200.md` §1.1.2 全表。
/// 通道差异由 `MessageContext` 在路由层区分；本枚举仅承载 attachType ↔ case 的解码 / 反编码。
///
/// 双形态解析：H5 既用字符串 'SEND_GIFT' 也用数字 1/4/15/18；负数 attachType
/// H5 后端可能下发 Int 也可能下发 String "-8" / "-9"——`init(raw:)` 内显式兜底两种形态。
///
/// **关键校正**（H 校验清单 §1.1 实证，覆盖 B 期猜测命名）：
/// - 15：通话每分钟预估收入（非"背包礼物"，B 期 backpackGift 命名错误）
/// - 18：通话礼物预估收入（非"特权礼物"，B 期 privilegeGift 命名错误）
/// - 派对房 1001/1003/1008/1015：源码 PartyAttachType 实证 = seatUpdate/kickedOut/updateMedia/prohibitMic
///   （spec §1.1.1 C 表早期 "进出房/公屏文本/麦序变更/禁麦" 描述与源码冲突 → 信源码）
///
/// **99 冲突处理**：
/// - chatroomMsg 通道 99 = pkInviteAck（PK 邀请状态变更）
/// - sysMsg 通道 99 = AGENT_RECHARGE_NOTIFY（H5 形态；安卓走字符串）
/// - 本 enum 数字 99 永远解为 .pkInviteAck；agentRecharge 仅识别字符串 "AGENT_RECHARGE_NOTIFY"
/// - I 期接代充时若后端 sysMsg 上送数字 99，需在 SystemMessageRouter 内按 context 双形态兜底
///
/// **已知但不实现清单**（→ .knownButUnhandled，仅 logger.debug 不噪音）：
/// - 132 / 133（虚拟来电，路线图明确不做）
/// - 1007（派对房 legacy gift，新端一刀切忽略）
/// - 派对房 F 期：1004 / 1014 / 1017 / 1018-1027 / 1049 / 1050-1052 / 1100-1112
enum AttachType: Equatable {

    // MARK: - 合规/强制（B 已覆盖）

    case forceEndLive          // 44 — 强制下播
    case complianceWarning     // 61 — 合规警告 toast
    case banned                // 62 — 封禁下播
    case boostingExposure      // 63 — 进折扣池 BoostingExposure
    case boostingExposureExit  // 64 — 退出折扣池

    // MARK: - 礼物 / 礼物收入（H 礼物会话实现 SVGA 队列；本会话仅枚举）

    case sendGift              // 'SEND_GIFT' (字符串) / 1 (Int) 双形态
    case liveCallGift          // 4 — 通话内对方送礼
    case callIncomePerMinute   // 15 — 通话每分钟预估收入（B 期错命名 backpackGift 已修正）
    case callGiftIncome        // 18 — 通话礼物预估收入（B 期错命名 privilegeGift 已修正）
    case giftRequestRejected   // 16 — 主播索礼被拒
    case liveGiftRankUpdate    // 50 — 送礼物触发排行榜+热度变更（chatroomMsg）
    case rankUpdateOnly        // 56 — 排行榜变更（独立，不含热度）
    case hotScoreUpdate        // 71 — 热度衰减
    case enterRoomAnimation    // 80 — 进场动画（虚拟道具/座驾）

    // MARK: - 直播 PK（G 已覆盖；负数 attachType 同时支持 Int 与 String "-8" / "-9" 兜底）

    case pkInvite              // 97
    case pkScoreUpdate         // 98
    case pkInviteAck           // 99
    case pkStatusBundle        // 100
    case pkMuteBroadcast       // -8
    case pkChatNotice          // -9

    // MARK: - 通话系统消息（C 期缺口，H M4 SystemMessageRouter 实现）

    case callPayWaitState         // -6 通话充值等待状态变更
    case callCancel               // -3 通话取消/挂断（type 0/1/2/3）
    case callRemoteMessage        // -1 通话内远端文字消息（含 chatBubble）
    case followIncrement          // -4 被关注通知
    case userRechargeSuccess      // 35 用户充值成功（主播端非核心，预留 case）
    case anchorAuditChange        // 58 主播审核状态变更（applyStatus 0=通过/1=拒绝）
    case privateCallEnterAnimation // 83 私 call 进场座驾动画
    case callRechargeReward       // 90 通话充值成功钻石奖励

    // MARK: - 直播态扩展（H 礼物会话 / J 期补 UI）

    case privateCallSwitchChange  // 52 私 call 开关状态变更
    case liveAnnouncement         // 195 直播间公告

    // MARK: - 心愿单（H 礼物会话实现）

    case wishlistFirst         // 250 首次贡献
    case wishlistTop1          // 251 TOP1 变更
    case wishlistPoolDone      // 252 整池完成
    case wishlistGiftDone      // 253 单礼物达成

    // MARK: - 钻石福袋（H 礼物会话实现）

    case diamondBoxWarm        // 1030 发包
    case diamondBoxOpen        // 1031 开抢
    case diamondBoxClaim       // 1032 瓜分
    case diamondBoxSettle      // 1033 结算

    // MARK: - 派对房（E 已覆盖核心；F 期扩展走 .knownButUnhandled）
    //
    // case 名对齐源码 `PartyAttachType` 实证（H 校验清单 §1.1.1 C 表早期描述错误）。
    // 派对房消息分发仍由 `PartyMessageRouter` 内部走 `PartyAttachType(rawValue:)` 业务侧；
    // 本 enum 派对房 case 只用作 NIMService dispatch 的统一类型签名。

    case partySeatUpdate           // 1001 麦位变化（gzip）
    case partyKickedOut            // 1003 被踢出派对房
    case partyUpdateMedia          // 1008 麦克风/摄像头状态
    case partySeatUpdateList       // 1012 全量重拉麦位列表
    case partyProhibitMic          // 1015 禁麦 / 解禁
    case partyGiftCompressed       // 2049 派对房礼物（gzip）
    case partyInviteVideoSeat(subType: Int) // 1040-1048 视频位邀请 P2P 链 9 case

    // MARK: - 活动 / 任务 / 猜拳（J 期接 i18n + 文案审核；H 仅 named case 占位）

    case activityWinnerPublic  // 140 活动中奖公屏
    case guessGameWinner       // 144 猜拳获胜公屏
    case activityApproved      // 156 主播活动审核通过弹窗
    case activityRemind30Min   // 157 开播前 30min 活动提醒
    case anchorTaskReward      // 135 新主播任务奖励

    // MARK: - 用户绑定（低优先；预留 case）

    case userBindAfterRecharged    // 103 绑定后已充值
    case userBindAfterNotRecharged // 104 绑定后未充值

    // MARK: - 字符串 attachType（H 礼物会话 / I 期）

    case cpRankReward          // "CP_RANK_REWARD_NOTIFY"
    case cpRankPreEnd          // "CP_RANK_PRE_END_NOTIFY"
    case activeTycoonEnter     // "active_tycoon_enter_room" 活跃大 R 进场 Toast
    case agentRecharge         // "AGENT_RECHARGE_NOTIFY"（H5 数字 99 与 .pkInviteAck 冲突，仅识别字符串形态）

    // MARK: - 已知但不实现（仅 logger.debug，不噪音）

    /// 路线图明确不做 / F 期派对房扩展 / 派对房 legacy gift 1007。
    /// raw 透传方便日志定位；不进任何 Router 业务分发。
    case knownButUnhandled(raw: String)

    /// 未识别 attachType，仅日志留痕。
    case unknown(raw: String)

    // MARK: - raw 反编码

    var raw: String {
        switch self {
        // 合规
        case .forceEndLive:          return "44"
        case .complianceWarning:     return "61"
        case .banned:                return "62"
        case .boostingExposure:      return "63"
        case .boostingExposureExit:  return "64"
        // 礼物 / 礼物收入
        case .sendGift:              return "SEND_GIFT"
        case .liveCallGift:          return "4"
        case .callIncomePerMinute:   return "15"
        case .callGiftIncome:        return "18"
        case .giftRequestRejected:   return "16"
        case .liveGiftRankUpdate:    return "50"
        case .rankUpdateOnly:        return "56"
        case .hotScoreUpdate:        return "71"
        case .enterRoomAnimation:    return "80"
        // PK
        case .pkInvite:              return "97"
        case .pkScoreUpdate:         return "98"
        case .pkInviteAck:           return "99"
        case .pkStatusBundle:        return "100"
        case .pkMuteBroadcast:       return "-8"
        case .pkChatNotice:          return "-9"
        // 通话 sysMsg
        case .callPayWaitState:           return "-6"
        case .callCancel:                 return "-3"
        case .callRemoteMessage:          return "-1"
        case .followIncrement:            return "-4"
        case .userRechargeSuccess:        return "35"
        case .anchorAuditChange:          return "58"
        case .privateCallEnterAnimation:  return "83"
        case .callRechargeReward:         return "90"
        // 直播态扩展
        case .privateCallSwitchChange:    return "52"
        case .liveAnnouncement:           return "195"
        // 心愿单
        case .wishlistFirst:         return "250"
        case .wishlistTop1:          return "251"
        case .wishlistPoolDone:      return "252"
        case .wishlistGiftDone:      return "253"
        // 钻石福袋
        case .diamondBoxWarm:        return "1030"
        case .diamondBoxOpen:        return "1031"
        case .diamondBoxClaim:       return "1032"
        case .diamondBoxSettle:      return "1033"
        // 派对房
        case .partySeatUpdate:       return "1001"
        case .partyKickedOut:        return "1003"
        case .partyUpdateMedia:      return "1008"
        case .partySeatUpdateList:   return "1012"
        case .partyProhibitMic:      return "1015"
        case .partyGiftCompressed:   return "2049"
        case .partyInviteVideoSeat(let sub): return "\(sub)"
        // 活动 / 任务 / 猜拳
        case .activityWinnerPublic:  return "140"
        case .guessGameWinner:       return "144"
        case .activityApproved:      return "156"
        case .activityRemind30Min:   return "157"
        case .anchorTaskReward:      return "135"
        // 用户绑定
        case .userBindAfterRecharged:    return "103"
        case .userBindAfterNotRecharged: return "104"
        // 字符串
        case .cpRankReward:          return "CP_RANK_REWARD_NOTIFY"
        case .cpRankPreEnd:          return "CP_RANK_PRE_END_NOTIFY"
        case .activeTycoonEnter:     return "active_tycoon_enter_room"
        case .agentRecharge:         return "AGENT_RECHARGE_NOTIFY"
        // 兜底
        case .knownButUnhandled(let r): return r
        case .unknown(let r):           return r
        }
    }

    // MARK: - raw 解码

    /// 已知但不实现（log debug 不噪音）的数字 attachType。
    /// 来源：H 校验清单 §1.3 死代码规避清单 + spec §2.3 已知但不实现注释。
    private static let knownUnhandledInts: Set<Int> = [
        // 路线图明确不做
        132, 133,
        // 派对房 legacy gift
        1007,
        // 派对房 F 期扩展（1018-1027 + 1100-1112 由 range 兜底）
        1004, 1014, 1017, 1049, 1050, 1051, 1052,
    ]

    init(raw: Any?) {
        // 1) Int / NSNumber 形态
        if let n = (raw as? NSNumber)?.intValue {
            self = Self.decodeInt(n)
            return
        }
        if let n = raw as? Int {
            self = Self.decodeInt(n)
            return
        }
        // 2) String 形态：先尝试解析为 Int（H5 后端跨字段类型不稳），其次按字符串 case
        if let s = raw as? String {
            if let n = Int(s) {
                self = Self.decodeInt(n)
                return
            }
            switch s {
            case "SEND_GIFT":                 self = .sendGift
            case "CP_RANK_REWARD_NOTIFY":     self = .cpRankReward
            case "CP_RANK_PRE_END_NOTIFY":    self = .cpRankPreEnd
            case "active_tycoon_enter_room":  self = .activeTycoonEnter
            case "AGENT_RECHARGE_NOTIFY":     self = .agentRecharge
            default:                          self = .unknown(raw: s)
            }
            return
        }
        // 3) nil / 不识别类型
        self = .unknown(raw: "nil")
    }

    /// 集中数字解码：保持 init(raw:) 函数体精简。
    private static func decodeInt(_ n: Int) -> AttachType {
        switch n {
        // 合规
        case 44:  return .forceEndLive
        case 61:  return .complianceWarning
        case 62:  return .banned
        case 63:  return .boostingExposure
        case 64:  return .boostingExposureExit
        // 礼物 / 礼物收入
        case 1:   return .sendGift
        case 4:   return .liveCallGift
        case 15:  return .callIncomePerMinute
        case 18:  return .callGiftIncome
        case 16:  return .giftRequestRejected
        case 50:  return .liveGiftRankUpdate
        case 56:  return .rankUpdateOnly
        case 71:  return .hotScoreUpdate
        case 80:  return .enterRoomAnimation
        // PK
        case 97:  return .pkInvite
        case 98:  return .pkScoreUpdate
        case 99:  return .pkInviteAck
        case 100: return .pkStatusBundle
        case -8:  return .pkMuteBroadcast
        case -9:  return .pkChatNotice
        // 通话 sysMsg
        case -6:  return .callPayWaitState
        case -3:  return .callCancel
        case -1:  return .callRemoteMessage
        case -4:  return .followIncrement
        case 35:  return .userRechargeSuccess
        case 58:  return .anchorAuditChange
        case 83:  return .privateCallEnterAnimation
        case 90:  return .callRechargeReward
        // 直播态扩展
        case 52:  return .privateCallSwitchChange
        case 195: return .liveAnnouncement
        // 心愿单
        case 250: return .wishlistFirst
        case 251: return .wishlistTop1
        case 252: return .wishlistPoolDone
        case 253: return .wishlistGiftDone
        // 钻石福袋
        case 1030: return .diamondBoxWarm
        case 1031: return .diamondBoxOpen
        case 1032: return .diamondBoxClaim
        case 1033: return .diamondBoxSettle
        // 派对房
        case 1001: return .partySeatUpdate
        case 1003: return .partyKickedOut
        case 1008: return .partyUpdateMedia
        case 1012: return .partySeatUpdateList
        case 1015: return .partyProhibitMic
        case 2049: return .partyGiftCompressed
        case 1040...1048: return .partyInviteVideoSeat(subType: n)
        // 活动 / 任务 / 猜拳
        case 140: return .activityWinnerPublic
        case 144: return .guessGameWinner
        case 156: return .activityApproved
        case 157: return .activityRemind30Min
        case 135: return .anchorTaskReward
        // 用户绑定
        case 103: return .userBindAfterRecharged
        case 104: return .userBindAfterNotRecharged
        default:
            // 派对房 F 期扩展 range / 已知但不实现数字 → knownButUnhandled
            if knownUnhandledInts.contains(n)
                || (1018...1027).contains(n)
                || (1100...1112).contains(n) {
                return .knownButUnhandled(raw: "\(n)")
            }
            return .unknown(raw: "\(n)")
        }
    }
}
