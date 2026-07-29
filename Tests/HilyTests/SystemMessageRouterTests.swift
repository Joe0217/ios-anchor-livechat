import XCTest

/// H 里程碑 M4-6：SystemMessageRouter 决策表单测（spec §6.1）。
///
/// HilyTests 是 logic test bundle 不 link 主 app（FURenderKit arm64 device-only 限制 +
/// CallStore/LiveStore 大量 SDK 依赖），无法直测 `SystemMessageRouter.route`。
/// 改测纯决策层 `SystemMessageRouteDecision.decide`：12 H 核心 case + 上下文过滤 +
/// payload 缺字段兜底。副作用执行层留 M6 真机端到端验证（spec §6.1 M4-7/M4-8）。
final class SystemMessageRouterTests: XCTestCase {

    private func decide(_ at: AttachType,
                        payload: [String: Any] = [:],
                        context: MessageContext = .sysMsg) -> SystemMessageAction {
        SystemMessageRouteDecision.decide(attachType: at, payload: payload, context: context)
    }

    // MARK: - 1. 通道过滤（spec §1.1.2 + SystemMessageRouter.swift §43）

    func test_context_liveChatroom_passThrough() {
        XCTAssertEqual(decide(.forceEndLive, context: .liveChatroom(roomId: "r1")), .passThrough,
                       ".liveChatroom 一律放行让 chatroom 主路径处理")
    }

    func test_context_partyChatroom_passThrough() {
        XCTAssertEqual(decide(.partySeatUpdate, context: .partyChatroom(roomId: "p1")), .passThrough)
    }

    func test_context_p2p_passThrough() {
        XCTAssertEqual(decide(.callRemoteMessage, context: .p2p(fromAccount: "u1")), .passThrough)
    }

    func test_context_syncSysMsg_isAccepted() {
        // 离线补发也得分发（冷启 attachType=62 否则丢失 → 主播不知道被封禁）
        XCTAssertEqual(decide(.banned, context: .syncSysMsg), .banned(subSource: "sysMsg_62"))
    }

    // MARK: - 2. 合规 / 强制（44 / 61 / 62 / 63 / 64）

    func test_44_forceEndLive_emitsCorrectSubSource() {
        XCTAssertEqual(decide(.forceEndLive), .forceEndLive(subSource: "sysMsg_44"))
    }

    func test_62_banned_emitsCorrectSubSource() {
        XCTAssertEqual(decide(.banned), .banned(subSource: "sysMsg_62"))
    }

    func test_61_complianceWarning_carriesContent() {
        XCTAssertEqual(decide(.complianceWarning, payload: ["content": "违规警告"]),
                       .complianceWarning(text: "违规警告"))
    }

    func test_61_complianceWarning_missingContent_emptyString() {
        // 由 router 副作用层兜底为 L10n.complianceWarningDefault；decide 仅返空串
        XCTAssertEqual(decide(.complianceWarning), .complianceWarning(text: ""))
    }

    func test_63_boostingExposure_on() {
        XCTAssertEqual(decide(.boostingExposure), .markBoostingExposure(on: true))
    }

    func test_64_boostingExposureExit_off() {
        XCTAssertEqual(decide(.boostingExposureExit), .markBoostingExposure(on: false))
    }

    // MARK: - 3. 通话 -1（含 URL decode + chatBubble 嵌套提取）

    func test_minus1_callRemoteMessage_plainText() {
        let a = decide(.callRemoteMessage,
                       payload: ["content": "hello", "ext": ["chatBubble": "https://cdn.example.com/bubble.png"]])
        XCTAssertEqual(a, .callRemoteText(text: "hello", chatBubble: "https://cdn.example.com/bubble.png", sender: ""))
    }

    func test_minus1_callRemoteMessage_urlEncoded_decodes() {
        let a = decide(.callRemoteMessage, payload: ["content": "hello%20world%21"])
        XCTAssertEqual(a, .callRemoteText(text: "hello world!", chatBubble: nil, sender: ""))
    }

    func test_minus1_callRemoteMessage_unicodeEscaped_decodes() {
        XCTAssertEqual(decide(.callRemoteMessage, payload: ["content": "\\u4F60\\u597D"]),
                       .callRemoteText(text: "你好", chatBubble: nil, sender: ""))
    }

    func test_minus1_callRemoteMessage_emptyContent_emitsEmpty() {
        // router 副作用层 guard !text.isEmpty 拦截写入；decide 仍返空串保持决策一致
        XCTAssertEqual(decide(.callRemoteMessage),
                       .callRemoteText(text: "", chatBubble: nil, sender: ""))
    }

    func test_minus1_callRemoteMessage_missingExt_chatBubbleNil() {
        XCTAssertEqual(decide(.callRemoteMessage, payload: ["content": "abc"]),
                       .callRemoteText(text: "abc", chatBubble: nil, sender: ""))
    }

    func test_minus1_callRemoteMessage_carriesSystemSender() {
        XCTAssertEqual(
            decide(.callRemoteMessage, payload: ["content": "abc", "_nimSender": "yx-remote"]),
            .callRemoteText(text: "abc", chatBubble: nil, sender: "yx-remote")
        )
    }

    // MARK: - 4. 通话 -6（payWaitState 4 个 type）

    func test_minus6_callPayWaitState_typeVariants() {
        for type in [1, 2, 3, 4] {
            XCTAssertEqual(decide(.callPayWaitState, payload: ["type": type]),
                           .callWaitState(type: type))
        }
    }

    func test_minus6_callPayWaitState_missingType_defaultZero() {
        XCTAssertEqual(decide(.callPayWaitState), .callWaitState(type: 0))
    }

    // MARK: - 5. 通话 15 / 18 / 90（累加型）

    func test_15_callIncomePerMinute_carriesDelta() {
        XCTAssertEqual(decide(.callIncomePerMinute, payload: ["num": 10]),
                       .callIncome(delta: 10))
    }

    func test_15_callIncomePerMinute_missingNum_zero() {
        XCTAssertEqual(decide(.callIncomePerMinute), .callIncome(delta: 0))
    }

    func test_18_callGiftIncome_carriesDelta() {
        XCTAssertEqual(decide(.callGiftIncome, payload: ["num": 25]),
                       .callGiftIncome(delta: 25))
    }

    func test_90_callRechargeReward_carriesDelta() {
        XCTAssertEqual(decide(.callRechargeReward, payload: ["giveDiamondNum": 50]),
                       .callRechargeReward(delta: 50))
    }

    func test_90_callRechargeReward_missingField_zero() {
        XCTAssertEqual(decide(.callRechargeReward), .callRechargeReward(delta: 0))
    }

    // MARK: - 5b. J 机器人通话（132 / 133）

    func test_133_robotCallIncoming_decodesFlexiblePayload() {
        let action = decide(
            .robotCallIncoming,
            payload: [
                "id": 77,
                "recordId": 88,
                "fileUrl": "https://cdn.example.com/robot.mp4",
                "agoraChannelId": 99,
                "autoHangupTime": "45",
                "userId": 100
            ]
        )

        guard case .robotCallIncoming(let invite?) = action else {
            return XCTFail("133 应产生可接听的机器人来电")
        }
        XCTAssertEqual(invite.videoId, "77")
        XCTAssertEqual(invite.recordId, "88")
        XCTAssertEqual(invite.fileURL.absoluteString, "https://cdn.example.com/robot.mp4")
        XCTAssertEqual(invite.agoraChannelId, "99")
        XCTAssertEqual(invite.autoHangupSeconds, 45)
        XCTAssertEqual(invite.displayUserId, "100")
    }

    func test_133_robotCallIncoming_missingRequiredField_isConsumedButInvalid() {
        XCTAssertEqual(
            decide(.robotCallIncoming, payload: ["id": 77, "recordId": 88]),
            .robotCallIncoming(invite: nil)
        )
    }

    func test_132_robotCallReward_decodesEligibleReward() {
        let action = decide(
            .robotCallReward,
            payload: ["recordId": 88, "videoId": 77, "type": "1", "content": 12, "callTime": "63"]
        )

        guard case .robotCallReward(let reward?) = action else {
            return XCTFail("132 应产生机器人通话结算奖励")
        }
        XCTAssertEqual(reward.recordId, "88")
        XCTAssertEqual(reward.videoId, "77")
        XCTAssertTrue(reward.isEligible)
        XCTAssertEqual(reward.diamondText, "12")
        XCTAssertEqual(reward.callDurationSeconds, 63)
    }

    // MARK: - 6. 通话辅助信令 -3

    func test_minus3_callCancel_carriesStringTypeAndChannel() {
        XCTAssertEqual(decide(.callCancel, payload: ["type": "2", "channelId": "c1", "_nimSender": "yx1"]),
                       .callNimSignal(type: "2", channelId: "c1", sender: "yx1"))
    }

    func test_minus3_callCancel_acceptsLegacyIntegerType() {
        XCTAssertEqual(decide(.callCancel, payload: ["type": 1]),
                       .callNimSignal(type: "1", channelId: "", sender: ""))
    }

    func test_minus3_callCancel_missingFields_fallbackEmptyStrings() {
        XCTAssertEqual(decide(.callCancel), .callNimSignal(type: "", channelId: "", sender: ""))
    }

    // MARK: - 7. SessionStore：-4 / 58

    func test_minus4_followIncrement_emitsAction() {
        XCTAssertEqual(decide(.followIncrement), .followIncrement)
    }

    func test_58_anchorAuditChange_carriesFields() {
        XCTAssertEqual(decide(.anchorAuditChange,
                              payload: ["applyStatus": 0, "content": "approved"]),
                       .anchorAuditChange(applyStatus: 0, content: "approved"))
    }

    func test_58_anchorAuditChange_acceptsStringStatus() {
        XCTAssertEqual(decide(.anchorAuditChange,
                              payload: ["applyStatus": "0", "content": "approved"]),
                       .anchorAuditChange(applyStatus: 0, content: "approved"))
        XCTAssertEqual(decide(.anchorAuditChange,
                              payload: ["applyStatus": "1", "content": "rejected"]),
                       .anchorAuditChange(applyStatus: 1, content: "rejected"))
    }

    func test_58_anchorAuditChange_missingFields_fallbacks() {
        XCTAssertEqual(decide(.anchorAuditChange),
                       .anchorAuditChange(applyStatus: -1, content: ""))
    }

    // MARK: - 8. 未实现 case（spec §6.2 渐进式接入 + 穷举式 switch 编译期防漏）

    /// chatroom 通道：PKNIMRouter / PartyMessageRouter 持有，sysMsg 通道一律放行。
    func test_pkAndPartyCases_inSysMsgChannel_passThrough() {
        XCTAssertEqual(decide(.pkInvite), .passThrough)
        XCTAssertEqual(decide(.pkScoreUpdate), .passThrough)
        XCTAssertEqual(decide(.pkChatNotice), .passThrough)
        XCTAssertEqual(decide(.partySeatUpdate), .passThrough)
        XCTAssertEqual(decide(.partyKickedOut), .passThrough)
        XCTAssertEqual(decide(.partyInviteVideoSeat(subType: 1042)), .passThrough)
        XCTAssertEqual(decide(.partyLuckyNumberPersonalDialog), .passThrough,
                       "1052 必须继续交给 PartyMessageRouter 弹个人中奖弹窗")
    }

    /// H 礼物会话独立实现（送礼 / 心愿单 / 钻石福袋 / 排行榜 / 热度 / 进场动画）。
    func test_giftSessionCases_passThrough() {
        XCTAssertEqual(decide(.sendGift), .passThrough)
        XCTAssertEqual(decide(.liveCallGift), .passThrough)
        XCTAssertEqual(decide(.liveGiftRankUpdate), .passThrough)
        XCTAssertEqual(decide(.rankUpdateOnly), .passThrough)
        XCTAssertEqual(decide(.hotScoreUpdate), .passThrough)
        XCTAssertEqual(decide(.enterRoomAnimation), .passThrough)
        XCTAssertEqual(decide(.privateCallEnterAnimation), .passThrough)
        XCTAssertEqual(decide(.wishlistFirst), .passThrough)
        XCTAssertEqual(decide(.wishlistTop1), .passThrough)
        XCTAssertEqual(decide(.wishlistPoolDone), .passThrough)
        XCTAssertEqual(decide(.wishlistGiftDone), .passThrough)
        XCTAssertEqual(decide(.diamondBoxWarm), .passThrough)
        XCTAssertEqual(decide(.diamondBoxOpen), .passThrough)
        XCTAssertEqual(decide(.diamondBoxClaim), .passThrough)
        XCTAssertEqual(decide(.diamondBoxSettle), .passThrough)
    }

    /// 低优先 case + J 期 case + 字符串型扩展 case。
    func test_lowPriorityAndJMilestoneCases_passThrough() {
        XCTAssertEqual(decide(.giftRequestRejected), .passThrough)
        XCTAssertEqual(decide(.userRechargeSuccess), .passThrough)
        // v22：privateCallSwitchChange 已从 passThrough 迁到实现动作（同步 LiveStore.privateCallOpen）
        XCTAssertEqual(decide(.liveAnnouncement), .passThrough)
        XCTAssertEqual(decide(.userBindAfterRecharged), .passThrough)
        XCTAssertEqual(decide(.userBindAfterNotRecharged), .passThrough)
        XCTAssertEqual(decide(.anchorTaskReward), .passThrough)
        XCTAssertEqual(decide(.activityWinnerPublic), .passThrough)
        XCTAssertEqual(decide(.guessGameWinner), .passThrough)
        XCTAssertEqual(decide(.activityApproved), .passThrough)
        XCTAssertEqual(decide(.activityRemind30Min), .passThrough)
        XCTAssertEqual(decide(.cpRankReward), .passThrough)
        XCTAssertEqual(decide(.cpRankPreEnd), .passThrough)
        XCTAssertEqual(decide(.activeTycoonEnter), .passThrough)
        XCTAssertEqual(decide(.agentRecharge), .passThrough)
    }

    func test_unknown_attachType_passThrough() {
        XCTAssertEqual(decide(.unknown(raw: "999")), .passThrough)
    }

    // MARK: - v22 privateCallSwitchChange (52) 反向同步（对齐 H5 live.js:306 `ext.data.privateCallOpen`）

    func test_privateCallSwitchChange_flat_open1() {
        XCTAssertEqual(decide(.privateCallSwitchChange, payload: ["privateCallOpen": 1]),
                       .privateCallSwitchChange(open: true))
    }

    func test_privateCallSwitchChange_flat_open0() {
        XCTAssertEqual(decide(.privateCallSwitchChange, payload: ["privateCallOpen": 0]),
                       .privateCallSwitchChange(open: false))
    }

    func test_privateCallSwitchChange_nestedData() {
        XCTAssertEqual(decide(.privateCallSwitchChange, payload: ["data": ["privateCallOpen": 1]]),
                       .privateCallSwitchChange(open: true))
    }

    func test_privateCallSwitchChange_stringValue() {
        XCTAssertEqual(decide(.privateCallSwitchChange, payload: ["privateCallOpen": "0"]),
                       .privateCallSwitchChange(open: false))
    }

    func test_privateCallSwitchChange_missingField_passThrough() {
        // v22 P0-1 修：对齐 H5 live.js:306 `!== ''`——缺字段跳过，不覆盖本地
        // 兜底 open=true 覆写会让主播关闭态被后端空 payload 误开
        XCTAssertEqual(decide(.privateCallSwitchChange), .passThrough)
    }

    func test_privateCallSwitchChange_emptyString_passThrough() {
        // 同 P0-1：空串等价于缺字段，跳过
        XCTAssertEqual(decide(.privateCallSwitchChange, payload: ["privateCallOpen": ""]),
                       .passThrough)
    }

    func test_privateCallSwitchChange_nestedData_emptyString_passThrough() {
        // 嵌套 data.privateCallOpen 空串也应跳过（H5 也是同一逻辑：`data?.privateCallOpen !== ''`）
        XCTAssertEqual(decide(.privateCallSwitchChange, payload: ["data": ["privateCallOpen": ""]]),
                       .passThrough)
    }

    func test_knownButUnhandled_passThrough() {
        XCTAssertEqual(decide(.knownButUnhandled(raw: "132")), .passThrough)
    }
}
