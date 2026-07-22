import XCTest

/// H 里程碑 M0-6 AttachType 全量 case 单测（spec §2.3）。
///
/// 覆盖：
/// 1. 所有 named case 的 raw 反编码与 init(raw:) 解码双向 round-trip
/// 2. Int / String 双形态对同一语义 case 的归一
/// 3. knownButUnhandled / unknown 兜底 case 不混淆
/// 4. 派对房 1018-1027 + 1100-1112 range 进 knownButUnhandled
final class AttachTypeFullTests: XCTestCase {

    // MARK: - 1. 合规 / 强制（B 已覆盖）

    func test_compliance_5cases_roundTrip() {
        assertRoundTrip(.forceEndLive, raw: "44")
        assertRoundTrip(.complianceWarning, raw: "61")
        assertRoundTrip(.banned, raw: "62")
        assertRoundTrip(.boostingExposure, raw: "63")
        assertRoundTrip(.boostingExposureExit, raw: "64")
    }

    // MARK: - 2. 礼物 / 礼物收入

    func test_gift_9cases_roundTrip() {
        assertRoundTrip(.sendGift, raw: "SEND_GIFT", alternateInt: 1)
        assertRoundTrip(.liveCallGift, raw: "4")
        assertRoundTrip(.callIncomePerMinute, raw: "15")
        assertRoundTrip(.callGiftIncome, raw: "18")
        assertRoundTrip(.giftRequestRejected, raw: "16")
        assertRoundTrip(.liveGiftRankUpdate, raw: "50")
        assertRoundTrip(.rankUpdateOnly, raw: "56")
        assertRoundTrip(.hotScoreUpdate, raw: "71")
        assertRoundTrip(.enterRoomAnimation, raw: "80")
    }

    // MARK: - 3. PK（G 已覆盖；负数 Int + String 双形态都识别）

    func test_pk_6cases_roundTrip() {
        assertRoundTrip(.pkInvite, raw: "97")
        assertRoundTrip(.pkScoreUpdate, raw: "98")
        assertRoundTrip(.pkInviteAck, raw: "99")
        assertRoundTrip(.pkStatusBundle, raw: "100")
        assertRoundTrip(.pkMuteBroadcast, raw: "-8")
        assertRoundTrip(.pkChatNotice, raw: "-9")
    }

    func test_pk_negativeStringForm_resolvesSameCase() {
        XCTAssertEqual(AttachType(raw: "-8"), .pkMuteBroadcast)
        XCTAssertEqual(AttachType(raw: "-9"), .pkChatNotice)
    }

    // MARK: - 4. 通话系统消息（C 期缺口，H M4 实现）

    func test_callSysMsg_8cases_roundTrip() {
        assertRoundTrip(.callPayWaitState, raw: "-6")
        assertRoundTrip(.callCancel, raw: "-3")
        assertRoundTrip(.callRemoteMessage, raw: "-1")
        assertRoundTrip(.followIncrement, raw: "-4")
        assertRoundTrip(.userRechargeSuccess, raw: "35")
        assertRoundTrip(.anchorAuditChange, raw: "58")
        assertRoundTrip(.privateCallEnterAnimation, raw: "83")
        assertRoundTrip(.callRechargeReward, raw: "90")
    }

    func test_callSysMsg_negativeStringForm_resolvesSameCase() {
        XCTAssertEqual(AttachType(raw: "-6"), .callPayWaitState)
        XCTAssertEqual(AttachType(raw: "-3"), .callCancel)
        XCTAssertEqual(AttachType(raw: "-1"), .callRemoteMessage)
        XCTAssertEqual(AttachType(raw: "-4"), .followIncrement)
    }

    // MARK: - 5. 直播态扩展 / 心愿单 / 钻石福袋

    func test_liveExtra_2cases_roundTrip() {
        assertRoundTrip(.privateCallSwitchChange, raw: "52")
        assertRoundTrip(.liveAnnouncement, raw: "195")
    }

    func test_wishlist_4cases_roundTrip() {
        assertRoundTrip(.wishlistFirst, raw: "250")
        assertRoundTrip(.wishlistTop1, raw: "251")
        assertRoundTrip(.wishlistPoolDone, raw: "252")
        assertRoundTrip(.wishlistGiftDone, raw: "253")
    }

    func test_diamondBox_4cases_roundTrip() {
        assertRoundTrip(.diamondBoxWarm, raw: "1030")
        assertRoundTrip(.diamondBoxOpen, raw: "1031")
        assertRoundTrip(.diamondBoxClaim, raw: "1032")
        assertRoundTrip(.diamondBoxSettle, raw: "1033")
    }

    // MARK: - 6. 派对房（case 名按源码 PartyAttachType 真值，覆盖 spec §1.1.1 C 表错描述）

    func test_party_6Named_roundTrip() {
        assertRoundTrip(.partySeatUpdate, raw: "1001")
        assertRoundTrip(.partyKickedOut, raw: "1003")
        assertRoundTrip(.partyUpdateMedia, raw: "1008")
        assertRoundTrip(.partySeatUpdateList, raw: "1012")
        assertRoundTrip(.partyProhibitMic, raw: "1015")
        assertRoundTrip(.partyGiftCompressed, raw: "2049")
    }

    func test_party_inviteVideoSeat_range_1040_1048() {
        for sub in 1040...1048 {
            let t = AttachType(raw: NSNumber(value: sub))
            XCTAssertEqual(t, .partyInviteVideoSeat(subType: sub), "raw=\(sub)")
            XCTAssertEqual(t.raw, "\(sub)")
        }
    }

    // MARK: - 7. 活动 / 任务 / 猜拳 / 用户绑定

    func test_jStage_7cases_roundTrip() {
        assertRoundTrip(.activityWinnerPublic, raw: "140")
        assertRoundTrip(.guessGameWinner, raw: "144")
        assertRoundTrip(.activityApproved, raw: "156")
        assertRoundTrip(.activityRemind30Min, raw: "157")
        assertRoundTrip(.anchorTaskReward, raw: "135")
        assertRoundTrip(.userBindAfterRecharged, raw: "103")
        assertRoundTrip(.userBindAfterNotRecharged, raw: "104")
    }

    // MARK: - 8. 字符串 attachType（D 表）

    func test_stringAttachType_4cases_roundTrip() {
        XCTAssertEqual(AttachType(raw: "CP_RANK_REWARD_NOTIFY"), .cpRankReward)
        XCTAssertEqual(AttachType.cpRankReward.raw, "CP_RANK_REWARD_NOTIFY")

        XCTAssertEqual(AttachType(raw: "CP_RANK_PRE_END_NOTIFY"), .cpRankPreEnd)
        XCTAssertEqual(AttachType.cpRankPreEnd.raw, "CP_RANK_PRE_END_NOTIFY")

        XCTAssertEqual(AttachType(raw: "active_tycoon_enter_room"), .activeTycoonEnter)
        XCTAssertEqual(AttachType.activeTycoonEnter.raw, "active_tycoon_enter_room")

        XCTAssertEqual(AttachType(raw: "AGENT_RECHARGE_NOTIFY"), .agentRecharge)
        XCTAssertEqual(AttachType.agentRecharge.raw, "AGENT_RECHARGE_NOTIFY")
    }

    /// 99 冲突处理：数字 99 永远归 .pkInviteAck；字符串 AGENT_RECHARGE_NOTIFY 才走 .agentRecharge
    func test_99_conflict_intGoesToPkInviteAck_stringGoesToAgentRecharge() {
        XCTAssertEqual(AttachType(raw: NSNumber(value: 99)), .pkInviteAck)
        XCTAssertEqual(AttachType(raw: "99"), .pkInviteAck)
        XCTAssertEqual(AttachType(raw: "AGENT_RECHARGE_NOTIFY"), .agentRecharge)
    }

    // MARK: - 9. J 机器人通话 + knownButUnhandled（仅 log debug 不噪音）

    func test_robotCall_attachTypes_roundTrip() {
        assertRoundTrip(.robotCallReward, raw: "132")
        assertRoundTrip(.robotCallIncoming, raw: "133")
    }

    func test_knownButUnhandled_explicitInts() {
        // 派对房 legacy gift
        assertKnownButUnhandled(AttachType(raw: NSNumber(value: 1007)), expectedRaw: "1007")
        // 派对房 F 期非 range case
        assertKnownButUnhandled(AttachType(raw: NSNumber(value: 1004)), expectedRaw: "1004")
        assertKnownButUnhandled(AttachType(raw: NSNumber(value: 1014)), expectedRaw: "1014")
        assertKnownButUnhandled(AttachType(raw: NSNumber(value: 1017)), expectedRaw: "1017")
        assertKnownButUnhandled(AttachType(raw: NSNumber(value: 1049)), expectedRaw: "1049")
        assertKnownButUnhandled(AttachType(raw: NSNumber(value: 1050)), expectedRaw: "1050")
        assertKnownButUnhandled(AttachType(raw: NSNumber(value: 1052)), expectedRaw: "1052")
    }

    func test_knownButUnhandled_partyRange_1018_1027() {
        for n in 1018...1027 {
            assertKnownButUnhandled(AttachType(raw: NSNumber(value: n)), expectedRaw: "\(n)")
        }
    }

    func test_knownButUnhandled_partyRange_1100_1112() {
        for n in 1100...1112 {
            assertKnownButUnhandled(AttachType(raw: NSNumber(value: n)), expectedRaw: "\(n)")
        }
    }

    // MARK: - 10. unknown 兜底

    func test_unknown_nil_returnsNilLiteral() {
        guard case .unknown(let raw) = AttachType(raw: nil) else {
            return XCTFail("nil → .unknown(\"nil\") 期望")
        }
        XCTAssertEqual(raw, "nil")
    }

    func test_unknown_unrecognizedInt() {
        guard case .unknown(let raw) = AttachType(raw: NSNumber(value: 9999)) else {
            return XCTFail("9999 → .unknown 期望")
        }
        XCTAssertEqual(raw, "9999")
    }

    func test_unknown_unrecognizedString() {
        guard case .unknown(let raw) = AttachType(raw: "SOMETHING_NEW") else {
            return XCTFail("未识别 String → .unknown 期望")
        }
        XCTAssertEqual(raw, "SOMETHING_NEW")
    }

    /// String 形态数字与 Int 形态归一
    func test_stringIntForm_resolvesAsInt() {
        XCTAssertEqual(AttachType(raw: "44"), .forceEndLive)
        XCTAssertEqual(AttachType(raw: "62"), .banned)
        XCTAssertEqual(AttachType(raw: "1030"), .diamondBoxWarm)
    }

    // MARK: - Helpers

    /// raw round-trip + Int 形态兜底验证
    private func assertRoundTrip(_ expected: AttachType,
                                  raw expectedRaw: String,
                                  alternateInt: Int? = nil,
                                  file: StaticString = #file,
                                  line: UInt = #line) {
        // 1) expected.raw == expectedRaw
        XCTAssertEqual(expected.raw, expectedRaw, file: file, line: line)
        // 2) init(raw: expectedRaw) == expected（字符串形态）
        XCTAssertEqual(AttachType(raw: expectedRaw), expected, file: file, line: line)
        // 3) Int 形态归一（如果 raw 是纯数字，验证 NSNumber 走同一 case）
        if let n = Int(expectedRaw) {
            XCTAssertEqual(AttachType(raw: NSNumber(value: n)), expected,
                           "NSNumber Int 形态应与 String 数字形态归一",
                           file: file, line: line)
        }
        // 4) 双形态 alt（例如 SEND_GIFT vs 1）
        if let alt = alternateInt {
            XCTAssertEqual(AttachType(raw: NSNumber(value: alt)), expected,
                           "字符串形态与数字形态应归一", file: file, line: line)
        }
    }

    private func assertKnownButUnhandled(_ t: AttachType,
                                          expectedRaw: String,
                                          file: StaticString = #file,
                                          line: UInt = #line) {
        guard case .knownButUnhandled(let raw) = t else {
            return XCTFail("期望 .knownButUnhandled, 实际 \(t)", file: file, line: line)
        }
        XCTAssertEqual(raw, expectedRaw, file: file, line: line)
    }
}
