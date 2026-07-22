import XCTest

/// IMSceneFilter.allows 纯函数单测。
/// 覆盖通道矩阵 / 必收清单 / grace 窗口 / sendGift 跨场景 / PK & 派对房 sysMsg 通道屏蔽。
final class IMSceneFilterTests: XCTestCase {

    private let noGrace = Date.distantPast
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let inGrace = Date(timeIntervalSince1970: 1_700_001_000)  // > now

    // MARK: - 通道矩阵

    func test_liveChatroom_alwaysAllowed_regardlessOfActiveOrAttachType() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .complianceWarning, context: .liveChatroom(roomId: "1"),
            active: [], graceUntil: noGrace, now: now
        ))
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .callRemoteMessage, context: .liveChatroom(roomId: "1"),
            active: [.party], graceUntil: noGrace, now: now
        ))
    }

    func test_partyChatroom_alwaysAllowed() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .partySeatUpdate, context: .partyChatroom(roomId: "1"),
            active: [], graceUntil: noGrace, now: now
        ))
    }

    func test_p2p_alwaysAllowed() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .sendGift, context: .p2p(fromAccount: "x"),
            active: [], graceUntil: noGrace, now: now
        ))
    }

    func test_syncSysMsg_alwaysAllowed() {
        // 离线 backlog 不能按当前 active 过滤
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .callRemoteMessage, context: .syncSysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - backlog grace 窗口

    func test_sysMsg_inGracePeriod_alwaysAllowed() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .callRemoteMessage, context: .sysMsg,
            active: [], graceUntil: inGrace, now: now
        ))
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .unknown(raw: "x"), context: .sysMsg,
            active: [], graceUntil: inGrace, now: now
        ))
    }

    func test_sysMsg_graceExpired_revertToActiveFilter() {
        // graceUntil 已过去 → 按 active 过滤
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .callRemoteMessage, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
    }

    func test_robotCall_messages_areAllowedWithoutAnActiveScene() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .robotCallIncoming, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .robotCallReward, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - 必收清单（mustReceive）

    func test_mustReceive_forceEndLive_alwaysAllowed() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .forceEndLive, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
    }

    func test_mustReceive_banned_alwaysAllowed() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .banned, context: .sysMsg,
            active: [.party], graceUntil: noGrace, now: now
        ))
    }

    func test_mustReceive_followIncrement_alwaysAllowed() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .followIncrement, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
    }

    func test_mustReceive_anchorAuditChange_alwaysAllowed() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .anchorAuditChange, context: .sysMsg,
            active: [.call], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - 直播单独相关（仅 .live active 时收）

    func test_live_complianceWarning_passWhenLiveActive() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .complianceWarning, context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
    }

    func test_live_complianceWarning_dropWhenLiveInactive() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .complianceWarning, context: .sysMsg,
            active: [.call], graceUntil: noGrace, now: now
        ))
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .complianceWarning, context: .sysMsg,
            active: [.party], graceUntil: noGrace, now: now
        ))
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .complianceWarning, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
    }

    func test_live_hotScoreUpdate_dropWhenIdle() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .hotScoreUpdate, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
    }

    func test_live_wishlistFirst_passWhenLiveActive() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .wishlistFirst, context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
    }

    func test_live_diamondBoxOpen_dropWhenPartyOnly() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .diamondBoxOpen, context: .sysMsg,
            active: [.party], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - 通话单独相关（仅 .call active 时收）

    func test_call_callRemoteMessage_passWhenCallActive() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .callRemoteMessage, context: .sysMsg,
            active: [.call], graceUntil: noGrace, now: now
        ))
    }

    func test_call_callRemoteMessage_dropWhenCallInactive() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .callRemoteMessage, context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
    }

    func test_call_callRechargeReward_passWhenCallActive() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .callRechargeReward, context: .sysMsg,
            active: [.call], graceUntil: noGrace, now: now
        ))
    }

    func test_call_callIncomePerMinute_dropWhenIdle() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .callIncomePerMinute, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - 直播私 call 组合（.live + .call 都 active）

    func test_liveCall_bothCategoriesAllowed() {
        let liveCall: IMSceneFilter.ActiveScenes = [.live, .call]
        // 直播相关
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .complianceWarning, context: .sysMsg,
            active: liveCall, graceUntil: noGrace, now: now
        ))
        // 通话相关
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .callRemoteMessage, context: .sysMsg,
            active: liveCall, graceUntil: noGrace, now: now
        ))
        // 必收（任何场景都收）
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .forceEndLive, context: .sysMsg,
            active: liveCall, graceUntil: noGrace, now: now
        ))
    }

    // MARK: - sendGift 跨场景（live 或 call active 都收）

    func test_sendGift_passWhenLiveOnly() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .sendGift, context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
    }

    func test_sendGift_passWhenCallOnly() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .sendGift, context: .sysMsg,
            active: [.call], graceUntil: noGrace, now: now
        ))
    }

    func test_sendGift_passWhenLiveAndCall() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .sendGift, context: .sysMsg,
            active: [.live, .call], graceUntil: noGrace, now: now
        ))
    }

    func test_sendGift_dropWhenIdleOrPartyOnly() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .sendGift, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .sendGift, context: .sysMsg,
            active: [.party], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - PK attachType 在 sysMsg 通道屏蔽（PK 走 liveChatroom）

    func test_pk_attachTypes_droppedInSysMsg_regardlessOfActive() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .pkInvite, context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .pkStatusBundle, context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .pkChatNotice, context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - 派对房 attachType 在 sysMsg 通道屏蔽（派对房走 partyChatroom）

    func test_party_attachTypes_droppedInSysMsg_regardlessOfActive() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .partySeatUpdate, context: .sysMsg,
            active: [.party], graceUntil: noGrace, now: now
        ))
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .partyKickedOut, context: .sysMsg,
            active: [.party], graceUntil: noGrace, now: now
        ))
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .partyInviteVideoSeat(subType: 1040), context: .sysMsg,
            active: [.party], graceUntil: noGrace, now: now
        ))
    }

    func test_partyLuckyNumberPersonalDialog_passesOnlyWhenPartyActive() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .partyLuckyNumberPersonalDialog, context: .sysMsg,
            active: [.party], graceUntil: noGrace, now: now
        ))
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .partyLuckyNumberPersonalDialog, context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - 全局 toast（任何场景都允许）

    func test_global_activityWinnerPublic_passInAnyActive() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .activityWinnerPublic, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .activityWinnerPublic, context: .sysMsg,
            active: [.party], graceUntil: noGrace, now: now
        ))
    }

    func test_global_cpRankReward_passInIdle() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .cpRankReward, context: .sysMsg,
            active: [], graceUntil: noGrace, now: now
        ))
    }

    func test_global_agentRecharge_passInAnyActive() {
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .agentRecharge, context: .sysMsg,
            active: [.call], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - 兜底（knownButUnhandled / unknown）

    func test_knownButUnhandled_dropInSysMsg() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .knownButUnhandled(raw: "1100"), context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
    }

    func test_unknown_dropInSysMsg() {
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .unknown(raw: "9999"), context: .sysMsg,
            active: [.live], graceUntil: noGrace, now: now
        ))
    }

    // MARK: - 派对房单独 active 时 sysMsg 行为综合

    func test_partyOnly_dropsLiveAndCallButKeepsMustReceiveAndGlobal() {
        let party: IMSceneFilter.ActiveScenes = [.party]
        // drop 直播相关
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .complianceWarning, context: .sysMsg,
            active: party, graceUntil: noGrace, now: now
        ))
        // drop 通话相关
        XCTAssertFalse(IMSceneFilter.allows(
            attachType: .callRechargeReward, context: .sysMsg,
            active: party, graceUntil: noGrace, now: now
        ))
        // keep 必收
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .forceEndLive, context: .sysMsg,
            active: party, graceUntil: noGrace, now: now
        ))
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .anchorAuditChange, context: .sysMsg,
            active: party, graceUntil: noGrace, now: now
        ))
        // keep 全局 toast
        XCTAssertTrue(IMSceneFilter.allows(
            attachType: .activityApproved, context: .sysMsg,
            active: party, graceUntil: noGrace, now: now
        ))
    }
}
