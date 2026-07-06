import Foundation

/// sysMsg 路由决策（pure）：`AttachType + payload + context` → 应执行的动作。
///
/// 拆分理由（H M4-6 单测落地）：`SystemMessageRouter.route` 内副作用层依赖
/// `LiveStore` / `CallStore` / `SessionStore`，三者各自带 SDK + 单例 + 大量构造依赖，
/// 无法进入 `HilyTests`（logic test bundle 不 link 主 app）。把决策层抽成纯枚举
/// 让测试可以零 SDK 依赖直接断言 spec §1.1.2 全表。
///
/// 副作用层（`SystemMessageRouter.swift`）拿到 `SystemMessageAction` 后转交对应 store helper。
enum SystemMessageAction: Equatable {

    // MARK: - LiveStore 动作
    case forceEndLive(subSource: String)
    case banned(subSource: String)
    case complianceWarning(text: String)
    case markBoostingExposure(on: Bool)

    // MARK: - CallStore 动作
    case callRemoteText(text: String, chatBubble: Int?)
    case callWaitState(type: Int)
    case callIncome(delta: Int)
    case callGiftIncome(delta: Int)
    case callRechargeReward(delta: Int)
    /// `.callCancel` RTM 主路径已处理；sysMsg 通道仅日志占位，避免链路下游误判仍消费。
    case callCancelLogOnly(type: Int)

    // MARK: - SessionStore 动作
    case followIncrement
    case anchorAuditChange(applyStatus: Int, content: String)

    // MARK: - OnlineStatusStore 动作
    /// 触发 hasExceededCallLimit 查询（对齐安卓 queryHideState(showToast=false, doAction=true)）：
    /// 收到 attachType=37 → 服务端主动踢下线 → 查是否达通话上限 → 弹 SetToBusyDialog
    case checkForcedBusy

    /// 非 sysMsg / syncSysMsg 通道或未覆盖 attachType：router 应 `return false` 让链路下游继续。
    case passThrough
}

enum SystemMessageRouteDecision {

    /// 决策入口。任意输入安全，缺字段走兜底值（不抛错、不 crash）。
    /// **穷举式 switch（无 default）**：AttachType 加新 case 时编译期强制开发者在本处声明意图，
    /// 避免新 case 被默默吞掉。
    static func decide(
        attachType: AttachType,
        payload: [String: Any],
        context: MessageContext
    ) -> SystemMessageAction {

        switch context {
        case .sysMsg, .syncSysMsg: break
        default: return .passThrough
        }

        switch attachType {

        // ===== H 核心 12 case：直接转动作 =====

        case .forceEndLive:
            return .forceEndLive(subSource: "sysMsg_44")
        case .banned:
            return .banned(subSource: "sysMsg_62")
        case .complianceWarning:
            let text = (payload["content"] as? String) ?? ""
            return .complianceWarning(text: text)
        case .boostingExposure:
            return .markBoostingExposure(on: true)
        case .boostingExposureExit:
            return .markBoostingExposure(on: false)
        case .callRemoteMessage:
            let raw = (payload["content"] as? String) ?? ""
            let decoded = raw.removingPercentEncoding ?? raw
            let chatBubble = (payload["ext"] as? [String: Any])?["chatBubble"] as? Int
            return .callRemoteText(text: decoded, chatBubble: chatBubble)
        case .callPayWaitState:
            return .callWaitState(type: (payload["type"] as? Int) ?? 0)
        case .callIncomePerMinute:
            return .callIncome(delta: (payload["num"] as? Int) ?? 0)
        case .callGiftIncome:
            return .callGiftIncome(delta: (payload["num"] as? Int) ?? 0)
        case .callRechargeReward:
            return .callRechargeReward(delta: (payload["giveDiamondNum"] as? Int) ?? 0)
        case .callCancel:
            return .callCancelLogOnly(type: (payload["type"] as? Int) ?? -1)
        case .followIncrement:
            return .followIncrement
        case .anchorAuditChange:
            let s = (payload["applyStatus"] as? Int) ?? -1
            let c = (payload["content"] as? String) ?? ""
            return .anchorAuditChange(applyStatus: s, content: c)
        case .forcedOffline:
            // 对齐安卓 CustomNotificationHandler → LiveEventBus "offline_msg"
            return .checkForcedBusy

        // ===== chatroom 通道（PKNIMRouter / PartyMessageRouter 持有），sysMsg 通道直接放行 =====

        case .pkInvite, .pkScoreUpdate, .pkInviteAck, .pkStatusBundle,
             .pkMuteBroadcast, .pkChatNotice:
            return .passThrough
        case .partySeatUpdate, .partyKickedOut, .partyUpdateMedia,
             .partySeatUpdateList, .partyProhibitMic, .partyGiftCompressed,
             .partyInviteVideoSeat:
            return .passThrough

        // ===== H 礼物会话独立实现（送礼 / 心愿单 / 钻石福袋 / 排行榜 / 热度 / 进场动画 / 座驾） =====

        case .sendGift, .liveCallGift, .liveGiftRankUpdate, .rankUpdateOnly,
             .hotScoreUpdate, .enterRoomAnimation, .privateCallEnterAnimation,
             .wishlistFirst, .wishlistTop1, .wishlistPoolDone, .wishlistGiftDone,
             .diamondBoxWarm, .diamondBoxOpen, .diamondBoxClaim, .diamondBoxSettle:
            return .passThrough

        // ===== spec 标记 ❌ 低优先（H 不实现，业务侧无产品决策；J 期按需补） =====

        case .giftRequestRejected, .userRechargeSuccess, .privateCallSwitchChange,
             .liveAnnouncement, .userBindAfterRecharged, .userBindAfterNotRecharged,
             .anchorTaskReward:
            return .passThrough

        // ===== J 期处理（活动 / 猜拳 / 活动报名提醒 + 字符串型扩展 case） =====

        case .activityWinnerPublic, .guessGameWinner, .activityApproved,
             .activityRemind30Min, .cpRankReward, .cpRankPreEnd,
             .activeTycoonEnter, .agentRecharge:
            return .passThrough

        // ===== 已知但不实现 / 完全未知 =====

        case .knownButUnhandled, .unknown:
            return .passThrough
        }
    }
}
