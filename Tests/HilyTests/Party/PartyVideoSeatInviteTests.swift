import XCTest

/// PartyVideoSeatInvite.from(payload:fallbackRoomId:timestampMs:) 单测（1040 视频位邀请解析）。
///
/// 安卓确认 §3.8 schema：
/// `{attachType:1040, inviteId(String), roomId(Number), yxRoomId(String),
///   seatIndex(Number), ownerUserId(发起人id), ownerNick(发起人昵称), ttl(秒,默认30), roomTempId(Number)}`
/// ⚠️ 字段名是 `ownerUserId / ownerNick`，**不是** `fromUserId / fromNickname`。
/// 守卫：`!inviteId.isEmpty && seatIndex > 0` 否则返回 nil（不入弹窗队列）。
final class PartyVideoSeatInviteTests: XCTestCase {

    private let ts: Int64 = 1_750_000_000_000
    private let fallbackRoom = "room-fallback"

    // MARK: - 正路径完整 schema

    func test_completeSchema_mapsAllFields() {
        let payload: [String: Any] = [
            "inviteId": "inv-abc-123",
            "seatIndex": 3,
            "ownerUserId": 1001,
            "ownerNick": "Alice",
            "roomId": 7777,
            "yxRoomId": "yx-7777",
            "ttl": 30,
            "roomTempId": 1
        ]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertNotNil(invite)
        XCTAssertEqual(invite?.inviteId, "inv-abc-123")
        XCTAssertEqual(invite?.seatIndex, 3)
        XCTAssertEqual(invite?.fromUserId, "1001")
        XCTAssertEqual(invite?.fromNickname, "Alice")
        XCTAssertEqual(invite?.roomId, "7777")
        XCTAssertEqual(invite?.timestamp, ts)
    }

    // MARK: - inviteId

    func test_inviteIdNumber_stringifiesAndPasses() {
        let payload: [String: Any] = ["inviteId": NSNumber(value: 88), "seatIndex": 1]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertEqual(invite?.inviteId, "88")
    }

    func test_inviteIdEmptyString_returnsNil() {
        let payload: [String: Any] = ["inviteId": "", "seatIndex": 1]
        XCTAssertNil(PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts))
    }

    func test_inviteIdMissing_returnsNil() {
        XCTAssertNil(PartyVideoSeatInvite.from(payload: ["seatIndex": 1], fallbackRoomId: fallbackRoom, timestampMs: ts))
    }

    // MARK: - seatIndex

    func test_seatIndexString_intifiesAndPasses() {
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": "3"]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertEqual(invite?.seatIndex, 3)
    }

    func test_seatIndexZero_rejectedByGuard() {
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": 0]
        XCTAssertNil(PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts))
    }

    func test_seatIndexNegative_rejectedByGuard() {
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": -1]
        XCTAssertNil(PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts))
    }

    func test_seatIndexMissing_returnsNil() {
        XCTAssertNil(PartyVideoSeatInvite.from(payload: ["inviteId": "i1"], fallbackRoomId: fallbackRoom, timestampMs: ts))
    }

    // MARK: - ownerUserId / ownerNick

    func test_ownerUserIdMissing_fromUserIdNil() {
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": 1]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertNotNil(invite)
        XCTAssertNil(invite?.fromUserId)
    }

    func test_ownerUserIdNumber_stringifies() {
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": 1, "ownerUserId": 555]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertEqual(invite?.fromUserId, "555")
    }

    func test_ownerNickMissing_fromNicknameNil() {
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": 1]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertNil(invite?.fromNickname)
    }

    func test_ownerNickNumber_returnsNil_byDesign() {
        // 当前实现是 payload["ownerNick"] as? String 不走 stringify；非 String 类型返 nil
        // 真实后端会给 String 昵称，本断言锁定当前行为；如未来需要 Number 兼容再加 stringify
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": 1, "ownerNick": 999]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertNotNil(invite)
        XCTAssertNil(invite?.fromNickname)
    }

    // MARK: - roomId fallback

    func test_roomIdNumber_stringifies() {
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": 1, "roomId": 7777]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertEqual(invite?.roomId, "7777")
    }

    func test_roomIdMissing_usesFallback() {
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": 1]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertEqual(invite?.roomId, fallbackRoom)
    }

    func test_roomIdPresent_overridesFallback() {
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": 1, "roomId": "real-room"]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: "fallback", timestampMs: ts)
        XCTAssertEqual(invite?.roomId, "real-room")
    }

    // MARK: - 守卫组合 + timestamp

    func test_extraFields_ignored_forwardCompat() {
        let payload: [String: Any] = [
            "inviteId": "i1", "seatIndex": 1,
            "ttl": 30, "roomTempId": 1, "yxRoomId": "yx", "unknownNewField": "foo"
        ]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: ts)
        XCTAssertNotNil(invite)
        XCTAssertEqual(invite?.inviteId, "i1")
    }

    func test_timestamp_passedThrough() {
        let custom: Int64 = 42
        let payload: [String: Any] = ["inviteId": "i1", "seatIndex": 1]
        let invite = PartyVideoSeatInvite.from(payload: payload, fallbackRoomId: fallbackRoom, timestampMs: custom)
        XCTAssertEqual(invite?.timestamp, custom)
    }
}
