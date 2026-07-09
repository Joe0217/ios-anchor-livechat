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
        center.setActiveScene(partyKey)
        XCTAssertEqual(router.stopAllCount, 1)
        XCTAssertNil(center.current)
        center.enqueue(item(key: partyKey, name: "P1"))
        XCTAssertEqual(center.current?.giftName, "P1")
    }

    // 8：leaveScene 硬中断
    func testLeaveSceneClearsAll() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.leaveScene(liveKey)
        XCTAssertEqual(router.stopAllCount, 1)
        XCTAssertNil(center.current)
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
        center.handleMemoryWarning()
        XCTAssertEqual(router.stopAllCount, 1)
        XCTAssertNil(center.current)
        center.enqueue(item(key: liveKey, name: "C"))
        XCTAssertEqual(center.current?.giftName, "C")
    }

    // 13：reset 完整清 + tearDown players
    func testResetTearsDownPlayers() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        center.enqueue(item(key: liveKey, name: "A"))
        center.reset()
        XCTAssertEqual(router.stopAllCount, 1)
        XCTAssertEqual(router.tearDownCount, 1)
        XCTAssertNil(center.current)
        center.enqueue(item(key: liveKey, name: "B"))
        XCTAssertNil(center.current)
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
}
