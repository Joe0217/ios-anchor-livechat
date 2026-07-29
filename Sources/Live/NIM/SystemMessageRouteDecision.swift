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
    case callRemoteText(text: String, chatBubble: String?, sender: String)
    case callWaitState(type: Int)
    case callIncome(delta: Int)
    case callGiftIncome(delta: Int)
    case callRechargeReward(delta: Int)
    /// H5 `attachType=-3` 的通话辅助信令。RTM 仍是状态机真值，NIM 仅补充弱网提示与挂断原因。
    case callNimSignal(type: String, channelId: String, sender: String)

    // MARK: - J 机器人通话动作
    case robotCallIncoming(invite: RobotCallInvite?)
    case robotCallReward(reward: RobotCallReward?)

    // MARK: - SessionStore 动作
    case followIncrement
    case anchorAuditChange(applyStatus: Int, content: String)

    // MARK: - OnlineStatusStore 动作
    /// 触发 hasExceededCallLimit 查询（对齐安卓 queryHideState(showToast=false, doAction=true)）：
    /// 收到 attachType=37 → 服务端主动踢下线 → 查是否达通话上限 → 弹 SetToBusyDialog
    case checkForcedBusy

    /// v22 attachType 52 私 call 开关状态反向同步（对齐 H5 stores/modules/live.js:306-307
    /// `currentLiveInfo.privateCallOpen = ext.data.privateCallOpen`）—— 后端广播状态变更时
    /// 更新 LiveStore.privateCallOpen；CallStore 据此判 busy reject。
    case privateCallSwitchChange(open: Bool)

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
            let decoded = Self.decodeCallText(raw)
            let ext = payload["ext"] as? [String: Any]
            let chatBubble = Self.optionalString(ext?["chatBubble"])
                ?? Self.optionalString(payload["chatBubble"])
            return .callRemoteText(text: decoded,
                                   chatBubble: chatBubble,
                                   sender: Self.stringValue(payload["_nimSender"]))
        case .callPayWaitState:
            return .callWaitState(type: (payload["type"] as? Int) ?? 0)
        case .callIncomePerMinute:
            return .callIncome(delta: (payload["num"] as? Int) ?? 0)
        case .callGiftIncome:
            return .callGiftIncome(delta: (payload["num"] as? Int) ?? 0)
        case .callRechargeReward:
            return .callRechargeReward(delta: (payload["giveDiamondNum"] as? Int) ?? 0)
        case .callCancel:
            let type: String
            if let value = payload["type"] as? String {
                type = value
            } else if let value = payload["type"] as? Int {
                type = String(value)
            } else {
                type = ""
            }
            return .callNimSignal(
                type: type,
                channelId: Self.stringValue(payload["channelId"]),
                sender: Self.stringValue(payload["_nimSender"])
            )
        case .followIncrement:
            return .followIncrement
        case .anchorAuditChange:
            // 审核状态接口会混发 Int / NSNumber / String，不能把字符串 "0" 当作缺字段。
            let s = Self.intValue(payload["applyStatus"]) ?? -1
            let c = (payload["content"] as? String) ?? ""
            return .anchorAuditChange(applyStatus: s, content: c)
        case .forcedOffline:
            // 对齐安卓 CustomNotificationHandler → LiveEventBus "offline_msg"
            return .checkForcedBusy
        case .robotCallIncoming:
            return .robotCallIncoming(invite: RobotCallInvite(payload: payload))
        case .robotCallReward:
            return .robotCallReward(reward: RobotCallReward(payload: payload))

        // ===== chatroom 通道（PKNIMRouter / PartyMessageRouter 持有），sysMsg 通道直接放行 =====

        case .pkInvite, .pkScoreUpdate, .pkInviteAck, .pkStatusBundle,
             .pkMuteBroadcast, .pkChatNotice:
            return .passThrough
        case .partySeatUpdate, .partyKickedOut, .partyUpdateMedia,
             .partySeatUpdateList, .partyAuditWarning, .partyProhibitMic,
             .partyAuthUpdate, .partyGiftCompressed,
             .partyTaskProgress, .partyTaskReward,
             .partyPlatformAdminChange,
             .partyPrivateCallNotify,  // 1029 派对房私 call 状态通知（聊天室通道，非 sysMsg）
             .partyLuckyNumberPersonalDialog, // 1052 交给 PartyMessageRouter（sysMsg）
             .partyInviteVideoSeat:
            return .passThrough

        // ===== H 礼物会话独立实现（送礼 / 心愿单 / 钻石福袋 / 排行榜 / 热度 / 进场动画 / 座驾） =====

        case .sendGift, .liveCallGift, .liveGiftRankUpdate, .rankUpdateOnly,
             .hotScoreUpdate, .enterRoomAnimation, .privateCallEnterAnimation,
             .firstGiftMoment, .guardianBroadcast,
             .wishlistFirst, .wishlistTop1, .wishlistPoolDone, .wishlistGiftDone,
             .diamondBoxWarm, .diamondBoxOpen, .diamondBoxClaim, .diamondBoxSettle:
            return .passThrough

        // ===== v22 私 call 开关状态反向同步（H5 attachType 52）=====

        case .privateCallSwitchChange:
            // H5 stores/modules/live.js:306：`ext?.data?.privateCallOpen !== ''` —— 兼容多态取值
            // payload 可能为 flat({privateCallOpen:1}) 或嵌套 data.privateCallOpen
            let raw: Any? = {
                if let d = payload["data"] as? [String: Any] { return d["privateCallOpen"] }
                return payload["privateCallOpen"]
            }()
            // v22 P0-1 修：对齐 H5 `!== ''` 语义——无值/空串跳过，**不覆盖本地** privateCallOpen。
            // 若走兜底 open=true 覆写：主播已关时被后端一条空 payload 消息误开 → CallStore 拦截失效
            // → 用户又能拨入 → 破坏"关闭私 call"修复目标（详见 docs/plan/代码审查报告-202607102337.md P0-1）
            guard let raw else { return .passThrough }
            if let s = raw as? String, s.isEmpty { return .passThrough }
            let open: Bool = {
                if let n = raw as? Int { return n != 0 }
                if let n = raw as? NSNumber { return n.intValue != 0 }
                if let s = raw as? String { return Int(s) != 0 }
                return true   // Bool 等极小概率不识别类型
            }()
            return .privateCallSwitchChange(open: open)

        // ===== spec 标记 ❌ 低优先（H 不实现，业务侧无产品决策；J 期按需补） =====

        case .giftRequestRejected, .userRechargeSuccess,
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

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func optionalString(_ value: Any?) -> String? {
        let string = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    /// H5 使用 `unescape(content.replace(/\\u/g, '%u'))`，因此除 URL percent encoding 外还要兼容字面量 `\\uXXXX`。
    private static func decodeCallText(_ raw: String) -> String {
        let percentDecoded = raw.removingPercentEncoding ?? raw
        var result = ""
        var index = percentDecoded.startIndex

        while index < percentDecoded.endIndex {
            guard percentDecoded[index] == "\\" else {
                result.append(percentDecoded[index])
                index = percentDecoded.index(after: index)
                continue
            }
            let uIndex = percentDecoded.index(after: index)
            guard uIndex < percentDecoded.endIndex, percentDecoded[uIndex] == "u" else {
                result.append(percentDecoded[index])
                index = uIndex
                continue
            }
            let hexStart = percentDecoded.index(after: uIndex)
            guard let hexEnd = percentDecoded.index(hexStart, offsetBy: 4, limitedBy: percentDecoded.endIndex),
                  hexEnd <= percentDecoded.endIndex,
                  let scalarValue = UInt32(percentDecoded[hexStart..<hexEnd], radix: 16),
                  let scalar = UnicodeScalar(scalarValue) else {
                result.append(percentDecoded[index])
                index = uIndex
                continue
            }
            result.unicodeScalars.append(scalar)
            index = hexEnd
        }
        return result
    }
}
