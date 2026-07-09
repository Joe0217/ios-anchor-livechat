import XCTest
@testable import HilyTests

@MainActor
final class LivePublicChatAdapterTests: XCTestCase {

    func test_system_message_becomes_system_variant() {
        let m = PublicChatMessage(text: "网络断开", isSystem: true)
        let u = LivePublicChatAdapter.adapt(m)
        XCTAssertNil(u.sender)
        if case .system(let t) = u.variant { XCTAssertEqual(t, "网络断开") } else { XCTFail() }
    }

    func test_anchor_maps_with_anchor_variant_and_pink_nickname() {
        let m = PublicChatMessage(text: "hi", isSystem: false, senderNickname: "Rola",
                                  isHost: true, messageType: .anchor)
        let u = LivePublicChatAdapter.adapt(m)
        XCTAssertEqual(u.sender?.nickname, "Rola")
        XCTAssertTrue(u.sender?.isHost ?? false)
        XCTAssertEqual(u.sender?.nicknameColor, .anchor)
        if case .anchor(let t, _) = u.variant { XCTAssertEqual(t, "hi") } else { XCTFail() }
    }

    func test_gift_maps_with_icon_name_count() {
        let m = PublicChatMessage(text: "", isSystem: false, senderNickname: "u1",
                                  messageType: .gift(giftIconUrl: "http://x", giftName: "Rose", count: 3))
        let u = LivePublicChatAdapter.adapt(m)
        if case .gift(let url, let name, let count) = u.variant {
            XCTAssertEqual(url, "http://x")
            XCTAssertEqual(name, "Rose")
            XCTAssertEqual(count, 3)
        } else { XCTFail() }
    }

    func test_lucky_gift_carries_totalReward() {
        let m = PublicChatMessage(text: "", isSystem: false, senderNickname: "u1",
                                  messageType: .luckyGift(giftIconUrl: nil, count: 1, totalReward: 5000))
        let u = LivePublicChatAdapter.adapt(m)
        if case .luckyGift(_, let count, let total) = u.variant {
            XCTAssertEqual(count, 1)
            XCTAssertEqual(total, 5000)
        } else { XCTFail() }
    }

    func test_official_boost_enter_maps() {
        let m = PublicChatMessage(text: "", isSystem: false, senderNickname: "u1",
                                  messageType: .officialBoostEnter)
        let u = LivePublicChatAdapter.adapt(m)
        if case .officialBoostEnter = u.variant { /* ok */ } else { XCTFail() }
    }

    func test_diamond_gift_send_subtype_converts() {
        let old = DiamondGiftSubType.send(senderName: "u1", tierName: "SS", totalDiamonds: 1000)
        let m = PublicChatMessage(text: "", isSystem: false, senderNickname: "u1",
                                  messageType: .diamondGift(subType: old))
        let u = LivePublicChatAdapter.adapt(m)
        if case .diamondGift(let sub) = u.variant {
            if case .send(let name, let tier, let total) = sub {
                XCTAssertEqual(name, "u1")
                XCTAssertEqual(tier, "SS")
                XCTAssertEqual(total, 1000)
            } else { XCTFail("wrong sub") }
        } else { XCTFail() }
    }

    func test_regular_text_maps() {
        let m = PublicChatMessage(text: "hello", isSystem: false, senderNickname: "u1",
                                  userLevel: 25, isVip: true, messageType: .regular)
        let u = LivePublicChatAdapter.adapt(m)
        XCTAssertEqual(u.sender?.nickname, "u1")
        XCTAssertEqual(u.sender?.userLevel, 25)
        XCTAssertTrue(u.sender?.isVip ?? false)
        XCTAssertEqual(u.sender?.nicknameColor, .default)
        if case .text(let content, _, _, _) = u.variant { XCTAssertEqual(content, "hello") } else { XCTFail() }
    }
}
