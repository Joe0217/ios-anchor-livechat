import XCTest
// 待测源码通过 project.yml HilyTests.sources 编入 HilyTests module；无需 @testable import Hily

@MainActor
final class GiftEffectCenterTests: XCTestCase {
    private var center: GiftEffectCenter!
    private var router: FakeGiftPlayerRouter!
    private var hostView: UIView!   // 强引用避免 Center 内 weak hostView 立即释放
    private let liveKey = GiftEffectSceneKey(scene: .live, scopeId: "live_1")
    private let partyKey = GiftEffectSceneKey(scene: .party, scopeId: "party_1")

    override func setUp() {
        super.setUp()
        router = FakeGiftPlayerRouter()
        center = GiftEffectCenter(playerRouter: router)
        hostView = UIView()
        center.registerHostView(hostView)   // UT 用 fake host（strong ref 由 hostView 保持）
    }

    private func item(key: GiftEffectSceneKey, self isSelf: Bool = false,
                      url: String? = "https://cdn/x.svga",
                      name: String = "Gift", id: Int64 = 0) -> GiftEffectItem {
        GiftEffectItem(
            sceneKey: key, senderYxAccid: isSelf ? "me" : "other",
            senderNickname: "N", senderAvatarUrl: nil,
            giftId: id == 0 ? Int64(Int.random(in: 1...1_000_000)) : id,
            giftName: name, giftCount: 1, giftPrice: 100,
            animationUrl: url, staticImgUrl: nil,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            isSelfSent: isSelf
        )
    }

    // 1
    func testEnqueueRejectedWithoutActiveScene() {
        center.enqueue(item(key: liveKey))
        XCTAssertEqual(router.playHistory.count, 0)
        XCTAssertNil(center.current)
    }

    // 2
    func testEnqueueRejectedWhenSceneMismatch() {
        center.setActiveScene(liveKey)
        center.enqueue(item(key: partyKey))
        XCTAssertEqual(router.playHistory.count, 0)
    }

    // 3
    func testEnqueuePlaysImmediatelyWhenIdle() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        XCTAssertEqual(router.playHistory.count, 1)
        XCTAssertEqual(center.current?.giftName, "A")
    }

    // 4：上限 30 FIFO 淘汰最旧
    func testQueueOverflowDropsOldest() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        for i in 1...31 {
            center.enqueue(item(key: liveKey, name: "G\(i)"))
        }
        center.enqueue(item(key: liveKey, name: "G32"))
        router.finishCurrent()   // G1 播完
        XCTAssertEqual(center.current?.giftName, "G3")  // G2 被淘汰
    }

    // 5：派对房 me 送礼插队
    func testPartySelfSentInsertsAtHead() {
        center.setActiveScene(partyKey)
        router.manualFinish = true
        center.enqueue(item(key: partyKey, name: "A"))
        center.enqueue(item(key: partyKey, name: "B"))
        center.enqueue(item(key: partyKey, self: true, name: "ME"))
        XCTAssertEqual(center.current?.giftName, "A")
        router.finishCurrent()
        XCTAssertEqual(center.current?.giftName, "ME")
        router.finishCurrent()
        XCTAssertEqual(center.current?.giftName, "B")
    }

    // 6：直播场景 me 不插队
    func testLiveSelfSentDoesNotInsertAtHead() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.enqueue(item(key: liveKey, name: "B"))
        center.enqueue(item(key: liveKey, self: true, name: "ME"))
        router.finishCurrent()
        XCTAssertEqual(center.current?.giftName, "B")
    }

    // 7：setActiveScene 硬中断
    func testSetActiveSceneHardStopsCurrent() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.enqueue(item(key: liveKey, name: "B"))
        XCTAssertNotNil(center.current)
        XCTAssertEqual(router.playHistory.count, 1)   // A 已 play；B 在 pending
        center.setActiveScene(partyKey)
        XCTAssertEqual(router.stopAllCount, 1)
        XCTAssertNil(center.current)
        // code-review P0：stopAll 同步 fire finish 时 pending 若未 clear 会误播 B。
        // 修复后：stopAll 期间 isTearingDown short-circuit playNextIfIdle → B 不入 playHistory
        XCTAssertEqual(router.playHistory.count, 1)   // 仍是 1（只有 A），B 未被误播
        center.enqueue(item(key: partyKey, name: "P1"))
        XCTAssertEqual(center.current?.giftName, "P1")
        XCTAssertEqual(router.playHistory.count, 2)   // 新场景 P1 正常播
    }

    // 8：leaveScene 硬中断
    func testLeaveSceneClearsAll() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.enqueue(item(key: liveKey, name: "B"))
        XCTAssertEqual(router.playHistory.count, 1)   // A 播中，B 在 pending
        center.leaveScene(liveKey)
        XCTAssertEqual(router.stopAllCount, 1)
        XCTAssertNil(center.current)
        // code-review P0：B 不应被误播（leaveScene 硬中断保护）
        XCTAssertEqual(router.playHistory.count, 1)
    }

    // 9：leaveScene key 不匹配无操作
    func testLeaveSceneNoOpIfKeyMismatch() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.leaveScene(partyKey)
        XCTAssertEqual(router.stopAllCount, 0)
        XCTAssertNotNil(center.current)
    }

    // 10：Chat 场景不启用 MicroToast
    func testMicroToastNotShownInChat() {
        let chatKey = GiftEffectSceneKey(scene: .chat, scopeId: "peer_A")
        center.setActiveScene(chatKey)
        let toast = MicroToastItem(sceneKey: chatKey, imgUrl: "https://x/x.png", giftName: "T", count: 1)
        center.showMicroToast(toast)
        XCTAssertEqual(center.microToasts.count, 0)
    }

    // 11：MicroToast Live 场景 append + auto expire
    func testMicroToastAutoExpires() async throws {
        center.setActiveScene(liveKey)
        let toast = MicroToastItem(sceneKey: liveKey, imgUrl: "https://x/x.png", giftName: "T", count: 1, duration: 0.1)
        center.showMicroToast(toast)
        XCTAssertEqual(center.microToasts.count, 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(center.microToasts.count, 0)
    }

    // 12：内存告警清 pending + microToasts，activeKey 保留
    func testMemoryWarningClearsInFlight() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.enqueue(item(key: liveKey, name: "B"))
        XCTAssertEqual(router.playHistory.count, 1)
        center.handleMemoryWarning()
        XCTAssertEqual(router.stopAllCount, 1)
        XCTAssertNil(center.current)
        XCTAssertEqual(router.playHistory.count, 1)   // code-review P0：B 不误播
        center.enqueue(item(key: liveKey, name: "C"))
        XCTAssertEqual(center.current?.giftName, "C")
        XCTAssertEqual(router.playHistory.count, 2)
    }

    // 13：reset 完整清 + tearDown players
    func testResetTearsDownPlayers() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.enqueue(item(key: liveKey, name: "B"))
        XCTAssertEqual(router.playHistory.count, 1)
        center.reset()
        XCTAssertEqual(router.stopAllCount, 1)
        XCTAssertEqual(router.tearDownCount, 1)
        XCTAssertNil(center.current)
        XCTAssertEqual(router.playHistory.count, 1)   // code-review P0：B 不误播
        center.enqueue(item(key: liveKey, name: "C"))
        XCTAssertNil(center.current)   // reset 后 activeKey nil，enqueue 直接 rejected
    }

    // 14：setActiveScene 幂等（同 key 不触发 stop）
    func testSetActiveSceneIdempotent() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.setActiveScene(liveKey)
        XCTAssertEqual(router.stopAllCount, 0)
        XCTAssertNotNil(center.current)
    }

    // 15：warmupSVGA 转发给 router
    func testWarmupForwards() {
        center.warmupSVGA()
        XCTAssertEqual(router.warmupCount, 1)
    }

    // ==========================================================
    // 2026-07-10 code-review 追加 tc（P0-1/P0-3/P0-4 + E-3）
    // ==========================================================

    // 16：P0-1 修复 —— pending 满 30 时 party me 送礼应替换 tail 保留自己
    func testPartyMeSentYieldsTailWhenFull() {
        center.setActiveScene(partyKey)
        router.manualFinish = true
        // 塞满 30 条（A + 29 条 pending）
        center.enqueue(item(key: partyKey, name: "A"))
        for i in 1...29 {
            center.enqueue(item(key: partyKey, name: "P\(i)"))
        }
        // 此刻 current=A, pending=[P1..P29]（29 条）；再来一条普通 gift 塞满 pending
        center.enqueue(item(key: partyKey, name: "P30"))
        // pending 现在 30 条：[P1..P30]。party me 送礼 → tail(P30) 让位，ME 插头
        center.enqueue(item(key: partyKey, self: true, name: "ME"))
        router.finishCurrent()   // A 播完
        // 修复前：me 会被 while removeFirst 立即淘汰 → 播 P1
        // 修复后：me 保住队首优先级
        XCTAssertEqual(center.current?.giftName, "ME")
    }

    // 17：P0-3 修复 —— setActiveScene push 旧 key，leaveScene pop restore
    func testSceneStackRestoresOnLeave() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "L1"))
        XCTAssertEqual(router.playHistory.count, 1)   // L1 播中

        // Call 覆盖直播（Live push 到栈）
        let callKey = GiftEffectSceneKey(scene: .call, scopeId: "call_1")
        center.setActiveScene(callKey)
        center.enqueue(item(key: callKey, name: "C1"))
        XCTAssertEqual(center.current?.giftName, "C1")

        // Call 结束（leaveScene pop 恢复 Live）
        center.leaveScene(callKey)
        // 现在 activeKey 应该 restore 到 liveKey
        // 直接 enqueue Live gift 验证 restore 成功
        center.enqueue(item(key: liveKey, name: "L2"))
        XCTAssertEqual(center.current?.giftName, "L2")
    }

    // 18：P0-2 修复 —— leaveScene 传空 scopeId 时 scene-only match 也走 restore
    func testLeaveSceneScopeOnlyMatchFallback() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        let callKey = GiftEffectSceneKey(scene: .call, scopeId: "call_A")
        center.setActiveScene(callKey)
        center.enqueue(item(key: callKey, name: "C1"))

        // 模拟 CallView.onDisappear 时 store.current.callId 已被清 → scopeId=""
        let emptyCallKey = GiftEffectSceneKey(scene: .call, scopeId: "")
        center.leaveScene(emptyCallKey)   // scope 不匹配 activeKey 的 "call_A"，但 scene=.call 匹配
        // 修复后：走 scene-only match fallback → pop restore Live
        center.enqueue(item(key: liveKey, name: "L1"))
        XCTAssertEqual(center.current?.giftName, "L1")
    }

    // 19：P0-4 修复 —— installPlayerRouter 期间 pending 不被误播（isTearingDown 包裹）
    func testInstallPlayerRouterProtectsPending() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.enqueue(item(key: liveKey, name: "B"))
        XCTAssertEqual(router.playHistory.count, 1)   // A 播中，B 在 pending

        // 换新 router
        let newRouter = FakeGiftPlayerRouter()
        newRouter.manualFinish = true
        center.installPlayerRouter(newRouter)

        // 老 router 触发 stopAll + tearDown（若无 isTearingDown 保护，会消费 B）
        XCTAssertEqual(router.stopAllCount, 1)
        XCTAssertEqual(router.tearDownCount, 1)
        XCTAssertEqual(router.playHistory.count, 1)   // B 未在老 router 上误播

        // 新 router 承接 pending B（installPlayerRouter 尾部 playNextIfIdle）
        XCTAssertEqual(newRouter.playHistory.count, 1)
        XCTAssertEqual(center.current?.giftName, "B")
    }

    // 20：E-3 修复 —— MicroToast cap 3，超过时替换旧的保留最新
    func testMicroToastCapAt3() {
        center.setActiveScene(liveKey)
        // 突发塞 5 条 MicroToast
        for i in 1...5 {
            let toast = MicroToastItem(sceneKey: liveKey, imgUrl: nil, giftName: "T\(i)", count: 1, duration: 60)
            center.showMicroToast(toast)
        }
        // 应保留最新 3 条（T3/T4/T5），前面被替换
        XCTAssertEqual(center.microToasts.count, 3)
        XCTAssertEqual(center.microToasts.map { $0.giftName }, ["T3", "T4", "T5"])
    }
}
