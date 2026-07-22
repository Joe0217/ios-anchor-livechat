import XCTest

final class PartyGiftEffectItemTests: XCTestCase {
    func test_mapsH5Party2049Schema() {
        let item = PartyGiftEffectItem.from(payload: [
            "giftId": "42",
            "giftName": "Rose",
            "giftNum": 3,
            "giftIcon": "https://cdn.example/gift.svga",
            "smallImg": "https://cdn.example/gift.png",
            "sendUser": [
                "userId": 100,
                "nickname": "Alice",
                "avatar": "https://cdn.example/alice.png"
            ],
            "receiveUserList": [
                ["userId": 200, "nickname": "Bob", "icon": "https://cdn.example/bob.png"],
                ["userId": "300", "nickname": "Cara", "avatar": "https://cdn.example/cara.png"]
            ]
        ])

        XCTAssertEqual(item?.giftId, 42)
        XCTAssertEqual(item?.giftCount, 3)
        XCTAssertEqual(item?.giftCountTotal, 6)
        XCTAssertEqual(item?.senderUserId, "100")
        XCTAssertEqual(item?.senderNickname, "Alice")
        XCTAssertEqual(item?.receiverUserIds, ["200", "300"])
        XCTAssertEqual(item?.thumbnailURL, "https://cdn.example/gift.png")
        XCTAssertTrue(item?.hasPlayableAnimation ?? false)
    }

    func test_staticGiftFallsBackToGiftIconWhenSmallImageMissing() {
        let item = PartyGiftEffectItem.from(payload: [
            "giftId": 9,
            "giftIcon": "https://cdn.example/gift.webp"
        ])

        XCTAssertFalse(item?.hasPlayableAnimation ?? true)
        XCTAssertEqual(item?.staticImageURL, "https://cdn.example/gift.webp")
    }

    func test_luckyGiftHintAcceptsNumericAndStringBooleanValues() {
        XCTAssertTrue(PartyGiftEffectItem.from(payload: ["giftId": 1, "giftTypeV2": "6"])?.isLuckyHint ?? false)
        XCTAssertTrue(PartyGiftEffectItem.from(payload: ["giftId": 2, "luckyGift": "true"])?.isLuckyHint ?? false)
    }

    func test_luckyGiftCatalogMetadataSupportsCategoryAndStringType() throws {
        let categoryGift = GiftListData(
            id: 1,
            name: "Lucky",
            giftPrice: 1,
            giftSmallImg: "",
            giftImg: "",
            category: "Lucky Gift"
        )
        XCTAssertTrue(categoryGift.isLuckyGift)

        let data = try XCTUnwrap(
            """
            {"id":"2","name":"Lucky 2","giftPrice":"1","giftSmallImg":"","giftImg":"","giftTypeV2":"6"}
            """.data(using: .utf8)
        )
        let typeGift = try JSONDecoder().decode(GiftListData.self, from: data)
        XCTAssertEqual(typeGift.giftTypeV2, 6)
        XCTAssertTrue(typeGift.isLuckyGift)
        XCTAssertEqual(GiftPanelTab.fromGroupName("Lucky Gifts"), .luckyGift)
        XCTAssertEqual(GiftPanelTab.fromGroupName("party-lucky-gift"), .luckyGift)
    }

    func test_guestLuckyWinRequiresRewardAndWinningStyle() {
        let payload: [String: Any] = [
            "totalReward": "8888",
            "rewardPool": ["winningStyle": "https://cdn.example/win.webp"],
            "sendUser": [
                "userId": 100,
                "nickname": "Alice",
                "avatar": "https://cdn.example/alice.png"
            ]
        ]

        let win = PartyLuckyGiftWinEffect.from(payload: payload, myUserId: "200")
        XCTAssertEqual(win?.totalReward, 8888)
        XCTAssertEqual(win?.senderUserId, "100")
        XCTAssertEqual(win?.senderNickname, "Alice")
        XCTAssertNil(PartyLuckyGiftWinEffect.from(payload: payload, myUserId: "100"))

        var noStyle = payload
        noStyle["rewardPool"] = [:]
        XCTAssertNil(PartyLuckyGiftWinEffect.from(payload: noStyle, myUserId: "200"))
    }

    func test_missingGiftIdIsRejected() {
        XCTAssertNil(PartyGiftEffectItem.from(payload: ["giftIcon": "https://cdn.example/gift.png"]))
    }
}
