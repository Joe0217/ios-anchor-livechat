import XCTest
// 待测源码通过 project.yml HilyTests.sources 编入 HilyTests module；无需 @testable import Hily

final class GiftEffectItemDecoderTests: XCTestCase {
    private let sceneKey = GiftEffectSceneKey(scene: .live, scopeId: "12345")
    private let mineAccid = "me_yx_001"

    func testDecodesIntGiftId() {
        let payload: [String: Any] = [
            "giftId": 8888,
            "giftName": "Rose",
            "giftNum": 5,
            "giftPrice": 100,
            "giftIcon": "https://cdn/x.svga",
            "giftSmallImg": "https://cdn/x_small.png",
            "senderYxAccid": "user_yx_A",
            "senderNickname": "Alice",
            "senderAvatar": "https://cdn/a.jpg"
        ]
        let item = GiftEffectPayloadDecoder.decode(
            sceneKey: sceneKey, payload: payload, mineYxAccid: mineAccid
        )
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.giftId, 8888)
        XCTAssertEqual(item?.giftCount, 5)
        XCTAssertEqual(item?.animationUrl, "https://cdn/x.svga")
        XCTAssertEqual(item?.isSelfSent, false)
    }

    func testDecodesStringGiftId() {
        let payload: [String: Any] = [
            "giftId": "8888",
            "giftName": "Rose",
            "giftNum": "3",
            "giftIcon": "https://cdn/x.svga"
        ]
        let item = GiftEffectPayloadDecoder.decode(
            sceneKey: sceneKey, payload: payload, mineYxAccid: mineAccid
        )
        XCTAssertEqual(item?.giftId, 8888)
        XCTAssertEqual(item?.giftCount, 3)
    }

    func testMissingUrlReturnsNilAnimation() {
        let payload: [String: Any] = [
            "giftId": 1,
            "giftName": "X",
            "giftNum": 1,
            "giftIcon": "  "   // 空白应归一 nil
        ]
        let item = GiftEffectPayloadDecoder.decode(
            sceneKey: sceneKey, payload: payload, mineYxAccid: mineAccid
        )
        XCTAssertNil(item?.animationUrl)
    }

    func testDetectsSelfSent() {
        let payload: [String: Any] = [
            "giftId": 1,
            "giftName": "X",
            "giftNum": 1,
            "senderYxAccid": mineAccid
        ]
        let item = GiftEffectPayloadDecoder.decode(
            sceneKey: sceneKey, payload: payload, mineYxAccid: mineAccid
        )
        XCTAssertEqual(item?.isSelfSent, true)
    }
}
