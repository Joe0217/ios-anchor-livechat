import XCTest
import UIKit
// 待测源码通过 project.yml HilyTests.sources 编入 HilyTests module；无需 @testable import Hily

@MainActor
final class GiftEffectIntakeTests: XCTestCase {
    private var center: GiftEffectCenter!
    private var router: FakeGiftPlayerRouter!
    /// strong ref 由 test class 属性保持，防 Center.hostView weak var 立即变 nil 走 no-host 分支
    /// （对齐 GiftEffectCenterTests 相同 setUp 惯用法）
    private var hostView: UIView!
    private let liveKey = GiftEffectSceneKey(scene: .live, scopeId: "live_1")
    private let chatKey = GiftEffectSceneKey(scene: .chat, scopeId: "peer_A")
    private let partyKey = GiftEffectSceneKey(scene: .party, scopeId: "party_1")

    override func setUp() {
        super.setUp()
        router = FakeGiftPlayerRouter()
        center = GiftEffectCenter(playerRouter: router)
        hostView = UIView()
        center.registerHostView(hostView)
    }

    // 1. Live SVGA URL → 中央大动画（enqueue）
    func testLiveSvgaGoesCentralQueue() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        let ok = GiftEffectIntake.ingest(
            scene: .live, scopeId: "live_1",
            payload: [
                "giftId": 1, "giftName": "R", "giftNum": 1,
                "giftIcon": "https://cdn/x.svga"
            ],
            mineYxAccid: "me", into: center
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(router.playHistory.count, 1)
        XCTAssertEqual(center.microToasts.count, 0)
    }

    // 2. Live MP4 URL → 中央大动画
    func testLiveMp4GoesCentralQueue() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        let ok = GiftEffectIntake.ingest(
            scene: .live, scopeId: "live_1",
            payload: ["giftId": 1, "giftName": "R", "giftNum": 1,
                      "giftIcon": "https://cdn/x.mp4"],
            mineYxAccid: "me", into: center
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(router.playHistory.count, 1)
    }

    // 3. Live 静态图 URL → MicroToast
    func testLiveStaticImgGoesMicroToast() {
        center.setActiveScene(liveKey)
        router.manualFinish = true
        let ok = GiftEffectIntake.ingest(
            scene: .live, scopeId: "live_1",
            payload: ["giftId": 1, "giftName": "R", "giftNum": 1,
                      "giftImg": "https://cdn/x.png",
                      "giftSmallImg": "https://cdn/x.png"],
            mineYxAccid: "me", into: center
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(router.playHistory.count, 0)
        XCTAssertEqual(center.microToasts.count, 1)
    }

    // 4. Chat 无动画资源 → 既不入队也不 MicroToast（气泡由现有 SystemGiftBubbleView 承担）
    func testChatWithoutAnimationSuppressesMicroToast() {
        center.setActiveScene(chatKey)
        router.manualFinish = true
        let ok = GiftEffectIntake.ingest(
            scene: .chat, scopeId: "peer_A",
            payload: ["giftId": 1, "giftName": "R", "giftNum": 1,
                      "giftImg": "https://cdn/x.png"],
            mineYxAccid: "me", into: center
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(router.playHistory.count, 0)
        XCTAssertEqual(center.microToasts.count, 0)
    }

    // 5. Chat SVGA URL → 中央大动画（用户明示 Chat 也弹全屏）
    func testChatSvgaGoesCentralQueue() {
        center.setActiveScene(chatKey)
        router.manualFinish = true
        let ok = GiftEffectIntake.ingest(
            scene: .chat, scopeId: "peer_A",
            payload: ["giftId": 1, "giftName": "R", "giftNum": 1,
                      "giftIcon": "https://cdn/x.svga"],
            mineYxAccid: "me", into: center
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(router.playHistory.count, 1)
        XCTAssertEqual(center.microToasts.count, 0)
    }

    // 6. Party me 送礼 → 队首插入 + isSelfSent=true 标记
    func testPartyMeSentFlaggedForHeadInsert() {
        center.setActiveScene(partyKey)
        router.manualFinish = true
        _ = GiftEffectIntake.ingest(
            scene: .party, scopeId: "party_1",
            payload: ["giftId": 1, "giftName": "A", "giftNum": 1,
                      "giftIcon": "https://cdn/x.svga",
                      "senderYxAccid": "other"],
            mineYxAccid: "me", into: center
        )
        _ = GiftEffectIntake.ingest(
            scene: .party, scopeId: "party_1",
            payload: ["giftId": 2, "giftName": "ME", "giftNum": 1,
                      "giftIcon": "https://cdn/x.svga",
                      "senderYxAccid": "me"],
            mineYxAccid: "me", into: center
        )
        // A 正在播，ME 应在队首（未抢占）
        router.finishCurrent()
        XCTAssertEqual(center.current?.giftName, "ME")
    }

    // 7. 缺 giftId → 返回 false，不入队
    func testMissingGiftIdRejected() {
        center.setActiveScene(liveKey)
        let ok = GiftEffectIntake.ingest(
            scene: .live, scopeId: "live_1",
            payload: ["giftName": "R"], mineYxAccid: "me", into: center
        )
        XCTAssertFalse(ok)
    }

    // 8. 场景 scopeId 不匹配 activeScene → Center enqueue 层拒绝
    func testMismatchedScopeIdRejected() {
        center.setActiveScene(liveKey)   // scopeId="live_1"
        router.manualFinish = true
        _ = GiftEffectIntake.ingest(
            scene: .live, scopeId: "live_999",   // 不同 scopeId
            payload: ["giftId": 1, "giftName": "R", "giftNum": 1,
                      "giftIcon": "https://cdn/x.svga"],
            mineYxAccid: "me", into: center
        )
        XCTAssertEqual(router.playHistory.count, 0)
    }
}
