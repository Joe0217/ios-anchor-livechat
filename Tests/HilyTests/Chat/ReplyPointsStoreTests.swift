import XCTest

/// H-3 Step 1a-3：ReplyPointsStore 状态机 + 4 tip 注入 + auto-claim + 结算防重放。
///
/// 覆盖 spec §5.1 F-8 ~ F-17 / F-42 + §5.2 R-9 ~ R-16 相关 + Critical-5 / Critical-6 + Major-6 / Major-7 / Minor-3 / Minor-4。
@MainActor
final class ReplyPointsStoreTests: XCTestCase {

    // MARK: - Helpers

    /// FakeReplyPointsService.init 是 @MainActor，Swift 6 concurrency 下不能作为 default parameter；
    /// 改传 nil，body 里 fallback。
    private func makeStore(
        service: FakeReplyPointsService? = nil,
        configLoaded: Bool = true,
        pay: Int? = 5,
        free: Int? = 1
    ) -> ReplyPointsStore {
        ReplyPointsStore(
            service: service ?? FakeReplyPointsService(),
            configBridge: FakeReplyPointsConfigBridge(isLoaded: configLoaded, pay: pay, free: free)
        )
    }

    private func makeBoxList(
        items: [(points: Int, diamond: Int, status: BoxStatus)] = [],
        anchorPoint: Int = 0
    ) -> MessageBoxList {
        MessageBoxList(
            pointInfoList: items.map { MessageBoxItem(points: $0.points, diamond: $0.diamond, status: $0.status) },
            anchorPoint: anchorPoint
        )
    }

    private let peer = "peer-1"

    // MARK: - isOpenPaidMessage 派生

    /// spec §F-8：拉到非空 messageBoxList → isOpenPaidMessage=true
    func testIsOpenPaidMessage_Nonempty_True() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)], anchorPoint: 0))
        let store = makeStore(service: svc)

        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        XCTAssertTrue(store.isOpenPaidMessage(peer: peer))
    }

    /// spec §F-18 / R-9：拉到空 pointInfoList → isOpenPaidMessage=false（RewardProgress 隐藏；跳全流程）
    func testIsOpenPaidMessage_EmptyList_False() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: []))
        let store = makeStore(service: svc)

        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        XCTAssertFalse(store.isOpenPaidMessage(peer: peer))
    }

    /// spec §R-9：fetchMessageBoxList 失败 → sessions[peer] 保空 + isOpenPaidMessage=false
    func testBeginSession_FetchFails_LeavesSessionEmpty() async {
        struct FetchError: Error {}
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .failure(FetchError())
        let store = makeStore(service: svc)

        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        XCTAssertNil(store.sessions[peer])
        XCTAssertFalse(store.isOpenPaidMessage(peer: peer))
    }

    // MARK: - Critical-6: auto-claim 时机在 fetchMessageBoxList 时按 status==2 触发

    /// spec §F-9 / Critical-6：进页 messageBoxList 含 status=.claimable 节点 → 自动 claim
    func testBeginSession_AutoClaim_TriggeredForClaimable() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(
            items: [
                (100, 10, .claimed),       // 已领
                (200, 20, .claimable),     // 该 claim
                (300, 30, .notReached),    // 未达
                (400, 40, .claimable),     // 该 claim
            ],
            anchorPoint: 500
        ))
        svc.stubClaimDiamond = .success(15)
        let store = makeStore(service: svc)

        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        XCTAssertEqual(svc.claimCalls.count, 2, "两个 .claimable 节点应各触发一次 claim")
        XCTAssertEqual(svc.claimCalls, [peer, peer])
        // 本地 status 更新为 .claimed（防下次 onReceive 误触发）
        let items = store.sessions[peer]?.messageBoxList
        XCTAssertEqual(items?[1].status, .claimed)
        XCTAssertEqual(items?[3].status, .claimed)
        // 未 claim 的保原状
        XCTAssertEqual(items?[0].status, .claimed)
        XCTAssertEqual(items?[2].status, .notReached)
    }

    /// spec §R-13：auto-claim 失败 → node status 不变；下次进页重试
    func testBeginSession_ClaimFailure_KeepStatus() async {
        struct ClaimError: Error {}
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(200, 20, .claimable)]))
        svc.stubClaimDiamond = .failure(ClaimError())
        let store = makeStore(service: svc)

        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        XCTAssertEqual(svc.claimCalls.count, 1)
        XCTAssertEqual(store.sessions[peer]?.messageBoxList?[0].status, .claimable, "claim 失败应保留 .claimable，下次重试")
    }

    // MARK: - onReceiveUserMsg 累加（spec §F-13 / F-14 / R-10 / Major-6）

    /// F-13：pay 消息 → currentProgress += payPoints；count += 1
    func testOnReceiveUserMsg_PayMsg_AccumulatesPayPoints() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)], anchorPoint: 0))
        let store = makeStore(service: svc, pay: 5, free: 1)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        store.onReceiveUserMsg(
            peer: peer, msgId: "m1", timestamp: 1_720_000_000_000,
            msgType: "pay", isGift: false,
            stimulateTipText: "stimulate"
        )

        XCTAssertEqual(store.sessions[peer]?.currentProgress, 5)
        XCTAssertEqual(store.currentUserSendPaidMessageCount, 1)
    }

    /// F-14：msgType 缺失（nil）默认 "pay"（Major-6，对齐 H5 `message.js:903`）
    func testOnReceiveUserMsg_MsgTypeNil_DefaultsToPay() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc, pay: 5, free: 1)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        store.onReceiveUserMsg(
            peer: peer, msgId: "m1", timestamp: 1_720_000_000_000,
            msgType: nil, isGift: false,
            stimulateTipText: "stimulate"
        )

        XCTAssertEqual(store.sessions[peer]?.currentProgress, 5, "nil msgType 应按 pay 累加 5，而非 free 累加 1")
    }

    /// F-13：free 消息 → 累加 freePoints
    func testOnReceiveUserMsg_FreeMsg_AccumulatesFreePoints() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc, pay: 5, free: 1)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        store.onReceiveUserMsg(
            peer: peer, msgId: "m1", timestamp: 1_720_000_000_000,
            msgType: "free", isGift: false,
            stimulateTipText: "stimulate"
        )

        XCTAssertEqual(store.sessions[peer]?.currentProgress, 1)
    }

    /// R-10：AppConfigStore 未 loaded → 不累加（下次 loaded 后由 view 重刷）
    func testOnReceiveUserMsg_ConfigNotLoaded_SkipsAccumulate() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc, configLoaded: false, pay: nil, free: nil)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        store.onReceiveUserMsg(
            peer: peer, msgId: "m1", timestamp: 1_720_000_000_000,
            msgType: "pay", isGift: false,
            stimulateTipText: "stimulate"
        )

        XCTAssertEqual(store.sessions[peer]?.currentProgress, 0)
    }

    /// F-15 / R-16：isGift 消息不参与累加
    func testOnReceiveUserMsg_IsGift_Skips() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        store.onReceiveUserMsg(
            peer: peer, msgId: "m1", timestamp: 1_720_000_000_000,
            msgType: "pay", isGift: true,
            stimulateTipText: "stimulate"
        )

        XCTAssertEqual(store.sessions[peer]?.currentProgress, 0)
        XCTAssertNil(store.sessions[peer]?.lastUserMsgInfo)
    }

    /// !isOpenPaidMessage → 全跳过（F-18）
    func testOnReceiveUserMsg_NotOpenPaidMessage_Skips() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: []))  // 空 → isOpenPaidMessage=false
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        store.onReceiveUserMsg(
            peer: peer, msgId: "m1", timestamp: 1_720_000_000_000,
            msgType: "pay", isGift: false,
            stimulateTipText: "stimulate"
        )

        // sessions[peer] 未设（isOpenPaidMessage=false 时 beginSession 也不留 state）
        // 或有 state 但 currentProgress=0
        XCTAssertEqual(store.sessions[peer]?.currentProgress ?? 0, 0)
    }

    // MARK: - F-13 / Major-6：stimulateTip counter 跨会话累积

    /// F-13：count 累加到 10 → inject stimulateTip + count 清 0
    func testOnReceiveUserMsg_CountReaches10_InjectsStimulateTipAndResets() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        for i in 0..<9 {
            store.onReceiveUserMsg(
                peer: peer, msgId: "m\(i)", timestamp: Int64(1_720_000_000_000 + i * 1000),
                msgType: "pay", isGift: false,
                stimulateTipText: "stimulate"
            )
        }
        XCTAssertEqual(store.currentUserSendPaidMessageCount, 9)
        XCTAssertFalse(store.sessions[peer]?.tips.contains(where: { $0.kind == .stimulate }) ?? true)

        store.onReceiveUserMsg(
            peer: peer, msgId: "m10", timestamp: 1_720_000_100_000,
            msgType: "pay", isGift: false,
            stimulateTipText: "stimulate"
        )

        XCTAssertEqual(store.currentUserSendPaidMessageCount, 0, "触发后 count 清 0")
        XCTAssertTrue(store.sessions[peer]?.tips.contains(where: { $0.kind == .stimulate }) ?? false)
    }

    /// F-42 / Major-6：切换 peer 会话不清 count（跨会话保留）
    func testOnReceiveUserMsg_CountSurvivesEndSession() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        for i in 0..<3 {
            store.onReceiveUserMsg(
                peer: peer, msgId: "m\(i)", timestamp: Int64(i),
                msgType: "pay", isGift: false, stimulateTipText: "s"
            )
        }
        XCTAssertEqual(store.currentUserSendPaidMessageCount, 3)

        store.endSession(peer: peer)
        XCTAssertEqual(store.currentUserSendPaidMessageCount, 3, "endSession 不清 count（跨会话保留）")
        XCTAssertNil(store.sessions[peer])
    }

    // MARK: - Critical-5: onSendAnchorMsg 无论成败清 lastUserMsgInfo（防重放）

    /// F-14：settle 成功 → currentProgress = res.currentTotalPoints + pendingSettleResult 设 + lastUserMsgInfo 清
    func testOnSendAnchorMsg_SettleSuccess_UpdatesState() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)], anchorPoint: 5))
        svc.stubSettleResult = .success(SettleReplyPointsResult(
            settled: true, points: 10, multiplier: 2, basePoints: 5, currentTotalPoints: 15, message: nil
        ))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)
        store.onReceiveUserMsg(peer: peer, msgId: "u1", timestamp: 1, msgType: "pay", isGift: false, stimulateTipText: "s")

        await store.onSendAnchorMsg(peer: peer, msgType: "text")

        XCTAssertEqual(store.sessions[peer]?.currentProgress, 15, "服务端权威覆盖")
        XCTAssertEqual(store.pendingSettleResult?.settled, true)
        XCTAssertTrue(store.sessions[peer]?.hasHistoryReply ?? false)
        XCTAssertNil(store.sessions[peer]?.lastUserMsgInfo, "Critical-5：清 lastUserMsgInfo 防重放")
    }

    /// Critical-5：settle **失败**也必须清 lastUserMsgInfo（防用户 1 条主播 N 次重放触发风控）
    func testOnSendAnchorMsg_SettleFailure_StillClearsLastUserMsgInfo() async {
        struct SettleError: Error {}
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        svc.stubSettleResult = .failure(SettleError())
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)
        store.onReceiveUserMsg(peer: peer, msgId: "u1", timestamp: 1, msgType: "pay", isGift: false, stimulateTipText: "s")
        XCTAssertNotNil(store.sessions[peer]?.lastUserMsgInfo)

        await store.onSendAnchorMsg(peer: peer, msgType: "text")

        XCTAssertNil(store.sessions[peer]?.lastUserMsgInfo, "Critical-5：失败也清 lastUserMsgInfo（防重放）")
        XCTAssertFalse(store.sessions[peer]?.hasHistoryReply ?? true, "失败不 mark hasHistoryReply")
    }

    /// R-12：res.settled=false → 不覆盖 currentProgress，但仍清 lastUserMsgInfo
    func testOnSendAnchorMsg_SettledFalse_DoesNotOverwriteButClears() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)], anchorPoint: 5))
        svc.stubSettleResult = .success(SettleReplyPointsResult(
            settled: false, points: 0, multiplier: 1, basePoints: 0, currentTotalPoints: 999, message: "isGift"
        ))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)
        store.onReceiveUserMsg(peer: peer, msgId: "u1", timestamp: 1, msgType: "pay", isGift: false, stimulateTipText: "s")

        await store.onSendAnchorMsg(peer: peer, msgType: "text")

        // 未覆盖：仍是初始 anchorPoint + onReceive 累加 5
        XCTAssertEqual(store.sessions[peer]?.currentProgress, 5 + 5)
        XCTAssertNil(store.pendingSettleResult)
        XCTAssertNil(store.sessions[peer]?.lastUserMsgInfo)
    }

    /// F-16：主播回复礼物消息（isGift 短路）→ 不调 settle；lastUserMsgInfo 仍清
    func testOnSendAnchorMsg_LastUserMsgIsGift_ShortCircuitsAndClears() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        // seed 一个 isGift=true 的 lastUserMsgInfo（onReceive 逻辑正常会跳过 isGift，用 _testSeedSession 直接 seed）
        var state = store.sessions[peer] ?? PeerReplyPointsState()
        state.lastUserMsgInfo = LastUserMsgInfo(msgId: "gift-1", timestamp: 1, msgType: "pay", isGift: true)
        store._testSeedSession(peer: peer, state)

        await store.onSendAnchorMsg(peer: peer, msgType: "text")

        XCTAssertEqual(svc.settleCalls.count, 0, "isGift 短路不调 settle")
        XCTAssertNil(store.sessions[peer]?.lastUserMsgInfo, "isGift 短路仍清 lastUserMsgInfo")
    }

    /// F-17：主播连发 3 条消息 → 只第 1 条调 settle（lastUserMsgInfo 清后为 nil）
    func testOnSendAnchorMsg_ConsecutiveSends_OnlyFirstCallsSettle() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        svc.stubSettleResult = .success(SettleReplyPointsResult(
            settled: true, points: 5, multiplier: 1, basePoints: 5, currentTotalPoints: 10, message: nil
        ))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)
        store.onReceiveUserMsg(peer: peer, msgId: "u1", timestamp: 1, msgType: "pay", isGift: false, stimulateTipText: "s")

        await store.onSendAnchorMsg(peer: peer, msgType: "text")
        await store.onSendAnchorMsg(peer: peer, msgType: "text")
        await store.onSendAnchorMsg(peer: peer, msgType: "text")

        XCTAssertEqual(svc.settleCalls.count, 1, "只第 1 条调 settle；后 2 条 lastUserMsgInfo nil 短路")
    }

    // MARK: - checkReplyRemindTrigger（Minor-4：Date 差值判定）

    /// F-11：baseTs 距 now ≥15min → inject replyRemindTip；会话内一次性 sticky
    func testCheckReplyRemindTrigger_Over15Min_Injects() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        let baseTs: Int64 = 1_720_000_000_000
        store.onReceiveUserMsg(peer: peer, msgId: "u1", timestamp: baseTs, msgType: "pay", isGift: false, stimulateTipText: "s")

        let now = Date(timeIntervalSince1970: Double(baseTs) / 1000 + 16 * 60)   // +16min
        store.checkReplyRemindTrigger(peer: peer, tipText: "reply-remind", now: now)

        XCTAssertTrue(store.sessions[peer]?.tips.contains { $0.kind == .replyRemind } ?? false)
        XCTAssertTrue(store.sessions[peer]?.replyRemindSent ?? false)
    }

    /// <15min → 不 inject
    func testCheckReplyRemindTrigger_Under15Min_DoesNotInject() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        let baseTs: Int64 = 1_720_000_000_000
        store.onReceiveUserMsg(peer: peer, msgId: "u1", timestamp: baseTs, msgType: "pay", isGift: false, stimulateTipText: "s")

        let now = Date(timeIntervalSince1970: Double(baseTs) / 1000 + 5 * 60)   // +5min
        store.checkReplyRemindTrigger(peer: peer, tipText: "reply-remind", now: now)

        XCTAssertFalse(store.sessions[peer]?.tips.contains { $0.kind == .replyRemind } ?? true)
    }

    /// hasHistoryReply=true → 不 inject（主播已回复过，无需提醒）
    func testCheckReplyRemindTrigger_HasHistoryReply_DoesNotInject() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        svc.stubSettleResult = .success(SettleReplyPointsResult(
            settled: true, points: 5, multiplier: 1, basePoints: 5, currentTotalPoints: 10, message: nil
        ))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)
        store.onReceiveUserMsg(peer: peer, msgId: "u1", timestamp: 1, msgType: "pay", isGift: false, stimulateTipText: "s")
        await store.onSendAnchorMsg(peer: peer, msgType: "text")   // hasHistoryReply=true

        let now = Date(timeIntervalSince1970: Double(1) / 1000 + 20 * 60)   // +20min
        store.checkReplyRemindTrigger(peer: peer, tipText: "reply-remind", now: now)

        XCTAssertFalse(store.sessions[peer]?.tips.contains { $0.kind == .replyRemind } ?? true)
    }

    /// replyRemindSent=true → 不重复 inject（sticky）
    func testCheckReplyRemindTrigger_AlreadySent_DoesNotReinject() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        let baseTs: Int64 = 1_720_000_000_000
        store.onReceiveUserMsg(peer: peer, msgId: "u1", timestamp: baseTs, msgType: "pay", isGift: false, stimulateTipText: "s")
        let now1 = Date(timeIntervalSince1970: Double(baseTs) / 1000 + 16 * 60)
        store.checkReplyRemindTrigger(peer: peer, tipText: "reply-remind", now: now1)
        let firstCount = store.sessions[peer]?.tips.filter { $0.kind == .replyRemind }.count ?? 0
        XCTAssertEqual(firstCount, 1)

        // 二次调 → sticky 不再注入
        let now2 = Date(timeIntervalSince1970: Double(baseTs) / 1000 + 30 * 60)
        store.checkReplyRemindTrigger(peer: peer, tipText: "reply-remind", now: now2)
        let secondCount = store.sessions[peer]?.tips.filter { $0.kind == .replyRemind }.count ?? 0
        XCTAssertEqual(secondCount, 1, "sticky 后不重复注入")
    }

    // MARK: - Guide tip 24h 去重（跨会话）

    /// F-10：首次进 chat 页 → inject guideTip
    func testBeginSession_FirstTime_InjectsGuideTip() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)

        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)

        XCTAssertTrue(store.sessions[peer]?.tips.contains { $0.kind == .guide } ?? false)
    }

    /// 24h 内二次进页 → 不重复 inject guideTip（对齐 H5 pushPayMsgTip 语义）
    func testBeginSession_Within24h_SkipsGuideTip() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)

        let now1 = Date(timeIntervalSince1970: 1_720_000_000)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all, now: now1)

        store.endSession(peer: peer)   // pop 回列表

        let now2 = Date(timeIntervalSince1970: 1_720_000_000 + 3600)   // +1h
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all, now: now2)

        // 二次会话 guide tip 不再注入
        XCTAssertFalse(store.sessions[peer]?.tips.contains { $0.kind == .guide } ?? true)
    }

    // MARK: - replyPointGuide 触发（有历史 lastUserMsg + 主播未回复过）

    func testBeginSession_InitialLastUserMsg_InjectsReplyPointGuide() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)

        let last = LastUserMsgInfo(msgId: "u1", timestamp: 1_720_000_000_000, msgType: "pay", isGift: false)
        await store.beginSession(peer: peer, initialLastUserMsg: last, tipTexts: FakeReplyPointsTipTexts.all)

        XCTAssertTrue(store.sessions[peer]?.tips.contains { $0.kind == .replyPointGuide } ?? false)
        // 时间戳 = last.timestamp + 1（H5 chat/index.vue:823）
        let tip = store.sessions[peer]?.tips.first { $0.kind == .replyPointGuide }
        XCTAssertEqual(tip?.timestamp, 1_720_000_000_001)
    }

    // MARK: - endSession + clear

    /// spec §Q7 "pop 即清"：endSession 移除 sessions[peer]
    func testEndSession_RemovesPeerState() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)
        XCTAssertNotNil(store.sessions[peer])

        store.endSession(peer: peer)

        XCTAssertNil(store.sessions[peer])
    }

    /// R-32 / R-33：logout clear 全清（session-scoped rule）
    func testClear_ResetsEverything() async {
        let svc = FakeReplyPointsService()
        svc.stubMessageBoxList = .success(makeBoxList(items: [(100, 10, .notReached)]))
        svc.stubSettleResult = .success(SettleReplyPointsResult(
            settled: true, points: 10, multiplier: 1, basePoints: 10, currentTotalPoints: 20, message: nil
        ))
        let store = makeStore(service: svc)
        await store.beginSession(peer: peer, tipTexts: FakeReplyPointsTipTexts.all)
        store.onReceiveUserMsg(peer: peer, msgId: "u1", timestamp: 1, msgType: "pay", isGift: false, stimulateTipText: "s")
        await store.onSendAnchorMsg(peer: peer, msgType: "text")

        XCTAssertEqual(store.currentUserSendPaidMessageCount, 1)
        XCTAssertNotNil(store.pendingSettleResult)

        store.clear()

        XCTAssertEqual(store.currentUserSendPaidMessageCount, 0)
        XCTAssertNil(store.pendingSettleResult)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    // MARK: - ChatTip.stableSortKey（Major-7 + Minor-3）

    /// 同 timestamp 时 tip 按 tieBreaker 排序：real msg (0) < guide (1) < replyPointGuide (2) < replyRemind (3) < stimulate (4)
    func testChatTip_StableSortKey_ByPriority() {
        let ts: Int64 = 1_720_000_000_000
        let guide = ChatTip(kind: .guide, text: "g", timestamp: ts)
        let rpg = ChatTip(kind: .replyPointGuide, text: "rpg", timestamp: ts)
        let rr = ChatTip(kind: .replyRemind, text: "rr", timestamp: ts)
        let stim = ChatTip(kind: .stimulate, text: "s", timestamp: ts)

        let sortedKeys = [stim, rr, rpg, guide].sorted { $0.stableSortKey < $1.stableSortKey }.map(\.kind)
        XCTAssertEqual(sortedKeys, [.guide, .replyPointGuide, .replyRemind, .stimulate])
    }

    /// 大时间戳 tip 排在小时间戳后
    func testChatTip_StableSortKey_ByTimestamp() {
        let t1 = ChatTip(kind: .guide, text: "g1", timestamp: 1_720_000_000_000)
        let t2 = ChatTip(kind: .guide, text: "g2", timestamp: 1_720_000_001_000)
        XCTAssertLessThan(t1.stableSortKey, t2.stableSortKey)
    }
}
