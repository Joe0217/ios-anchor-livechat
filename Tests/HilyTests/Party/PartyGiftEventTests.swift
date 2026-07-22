import XCTest

/// PartyGiftEvent.from(payload:timestampMs:) 单测（C 档 2049 送礼解析）。
///
/// 安卓确认 §3.3 schema（解压后）：
/// `giftId` / `giftNum`（**不是 num**） / `sendUser`（嵌套 userId/nickname...） / `receiveUserList`（数组） / 无 timestamp
/// 字段缺失策略（与原内联 didReceiveGift 等价，零业务行为变更）：
/// - `giftId` 缺/类型错 → 默认 0
/// - `giftNum` 缺 → 默认 1
/// - `sendUser` 缺 → senderUserId / senderNickname nil
/// - `receiveUserList` 项缺 userId → 静默丢弃（compactMap）
final class PartyGiftEventTests: XCTestCase {

    private let ts: Int64 = 1_750_000_000_000   // 固定 timestampMs 便于断言

    // MARK: - 正路径

    func test_completeSchema_mapsAllFields() {
        let payload: [String: Any] = [
            "giftId": 2049,
            "giftNum": 5,
            "sendUser": ["userId": 1001, "nickname": "Alice"],
            "receiveUserList": [["userId": 2001], ["userId": 2002]]
        ]
        let e = PartyGiftEvent.from(payload: payload, timestampMs: ts)
        XCTAssertEqual(e.giftId, 2049)
        XCTAssertEqual(e.num, 5)
        XCTAssertEqual(e.senderUserId, "1001")
        XCTAssertEqual(e.senderNickname, "Alice")
        XCTAssertEqual(e.receiverUserIds, ["2001", "2002"])
        XCTAssertEqual(e.gems, 0)
        XCTAssertEqual(e.timestamp, ts)
    }

    func test_giftIdNumber_intifies() {
        let e = PartyGiftEvent.from(payload: ["giftId": NSNumber(value: 100)], timestampMs: ts)
        XCTAssertEqual(e.giftId, 100)
    }

    func test_giftIdString_intifies() {
        // intify 支持数字 String（虽然真实 2049 不会用 String，跨型兼容设计内）
        let e = PartyGiftEvent.from(payload: ["giftId": "77"], timestampMs: ts)
        XCTAssertEqual(e.giftId, 77)
    }

    // MARK: - 字段缺失现行行为

    func test_giftIdMissing_defaultsToZero() {
        let e = PartyGiftEvent.from(payload: [:], timestampMs: ts)
        XCTAssertEqual(e.giftId, 0)
    }

    func test_giftNumMissing_defaultsToOne() {
        let e = PartyGiftEvent.from(payload: ["giftId": 1], timestampMs: ts)
        XCTAssertEqual(e.num, 1)
    }

    func test_giftNumZero_keepsZero() {
        let e = PartyGiftEvent.from(payload: ["giftNum": 0], timestampMs: ts)
        XCTAssertEqual(e.num, 0)
    }

    func test_giftNumNegative_keepsNegative_noGuard() {
        // 现行 from 不守卫 num >=0，business 侧 lastGiftEvent push 但 UI 不应渲染（推 F）
        let e = PartyGiftEvent.from(payload: ["giftNum": -3], timestampMs: ts)
        XCTAssertEqual(e.num, -3)
    }

    // MARK: - sendUser 嵌套

    func test_sendUserMissing_senderFieldsNil() {
        let e = PartyGiftEvent.from(payload: ["giftId": 1], timestampMs: ts)
        XCTAssertNil(e.senderUserId)
        XCTAssertNil(e.senderNickname)
    }

    func test_sendUserUserIdNumber_stringifies() {
        let e = PartyGiftEvent.from(
            payload: ["sendUser": ["userId": NSNumber(value: 999)]],
            timestampMs: ts
        )
        XCTAssertEqual(e.senderUserId, "999")
    }

    func test_sendUserNicknameMissing_nil() {
        let e = PartyGiftEvent.from(
            payload: ["sendUser": ["userId": 1]],
            timestampMs: ts
        )
        XCTAssertNil(e.senderNickname)
    }

    // MARK: - receiveUserList

    func test_receiveListMissing_emptyArray() {
        let e = PartyGiftEvent.from(payload: [:], timestampMs: ts)
        XCTAssertEqual(e.receiverUserIds, [])
    }

    func test_receiveListEmpty_emptyArray() {
        let e = PartyGiftEvent.from(payload: ["receiveUserList": []], timestampMs: ts)
        XCTAssertEqual(e.receiverUserIds, [])
    }

    func test_receiveListPartialMissingUserId_silentlyDropped() {
        let payload: [String: Any] = [
            "receiveUserList": [
                ["userId": 1],
                [:],                        // 缺 userId 静默丢
                ["userId": "3"],
                ["nickname": "x"]           // 缺 userId 丢
            ]
        ]
        let e = PartyGiftEvent.from(payload: payload, timestampMs: ts)
        XCTAssertEqual(e.receiverUserIds, ["1", "3"])
    }

    func test_receiveListMixedNumberAndString_stringifyAll() {
        let payload: [String: Any] = [
            "receiveUserList": [["userId": 10], ["userId": "20"], ["userId": NSNumber(value: 30)]]
        ]
        let e = PartyGiftEvent.from(payload: payload, timestampMs: ts)
        XCTAssertEqual(e.receiverUserIds, ["10", "20", "30"])
    }

    // MARK: - 麦位收礼值（2049 gems）

    func test_gems_acceptsDecimalNumberAndString() {
        XCTAssertEqual(
            PartyGiftEvent.from(payload: ["gems": 12.5], timestampMs: ts).gems,
            12.5
        )
        XCTAssertEqual(
            PartyGiftEvent.from(payload: ["gems": "3.25"], timestampMs: ts).gems,
            3.25
        )
    }

    func test_seatGiftValue_addsGemsToEveryRecipientOnSeat() {
        let seats = [
            makeSeat(index: 1, userId: "10", giftValueCount: 4.5),
            makeSeat(index: 2, userId: "20", giftValueCount: nil),
            makeSeat(index: 3, userId: "30", giftValueCount: 8),
        ]
        let updated = PartySeatGiftValue.adding(
            gems: 2.25,
            to: ["10", "20", "20", "404"],
            seats: seats
        )

        XCTAssertEqual(updated[0].giftValueCount, 6.75)
        XCTAssertEqual(updated[1].giftValueCount, 2.25)
        XCTAssertEqual(updated[2].giftValueCount, 8)
    }

    func test_seatGiftValue_preservesOnlySameUsersAcrossSeatRefresh() {
        let current = [
            makeSeat(index: 1, userId: "10", giftValueCount: 12),
            makeSeat(index: 2, userId: "20", giftValueCount: 8),
        ]
        let incoming = [
            makeSeat(index: 1, userId: "10", giftValueCount: nil),
            makeSeat(index: 2, userId: "30", giftValueCount: nil),
        ]
        let updated = PartySeatGiftValue.preservingLocalValues(from: current, in: incoming)

        XCTAssertEqual(updated[0].giftValueCount, 12)
        XCTAssertNil(updated[1].giftValueCount)
    }

    // MARK: - timestamp 透传

    func test_timestamp_passedThrough() {
        let custom: Int64 = 42
        let e = PartyGiftEvent.from(payload: [:], timestampMs: custom)
        XCTAssertEqual(e.timestamp, custom)
    }

    private func makeSeat(index: Int, userId: String, giftValueCount: Double?) -> PartyRoomSeat {
        PartyRoomSeat(
            id: nil,
            roomId: nil,
            seatIndex: index,
            userId: userId,
            avatar: nil,
            nickname: nil,
            seatType: PartyRoomSeatType.voice.rawValue,
            isOccupied: 1,
            cameraEnabled: nil,
            microphoneEnabled: nil,
            roomRoleType: nil,
            giftValueCount: giftValueCount,
            headFrame: nil,
            yxAccid: nil,
            userType: nil,
            seatCameraEnabled: nil,
            seatMicrophoneEnabled: nil,
            lockFlag: nil,
            roomTempId: nil,
            isHostSeat: nil,
            isPlatformAdmin: nil,
            showBubble: nil,
            anchorTaskRewardExt: nil
        )
    }
}
