import XCTest

/// PartyKickedOutGuard.shouldHandle(payload:myUserId:chatRoomId:) 单测（1003 被踢双字段守护）。
///
/// 安卓确认 §3.4：1003 payload `{seatIndex, roomId, userId}` 均为 **Number**；
/// HTTP `chat.roomId` 是 **String** → 跨通道 `stringify` 归一比较。
/// 守卫：`userId == 自己 && roomId == 当前房` 双字段同时匹配才认（防误踢）。
final class PartyKickedOutGuardTests: XCTestCase {

    private let me = "1001"
    private let room = "room-999"

    // MARK: - 正路径

    func test_userIdNumber_roomIdNumber_bothMatch_returnsTrue() {
        let payload: [String: Any] = ["userId": 1001, "roomId": 999]
        XCTAssertTrue(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    func test_userIdString_roomIdString_bothMatch_returnsTrue() {
        let payload: [String: Any] = ["userId": "1001", "roomId": "999"]
        XCTAssertTrue(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    // MARK: - 守卫拒绝

    func test_userIdMismatch_returnsFalse() {
        let payload: [String: Any] = ["userId": 9999, "roomId": "999"]
        XCTAssertFalse(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    func test_roomIdMismatch_returnsFalse() {
        let payload: [String: Any] = ["userId": 1001, "roomId": "different-room"]
        XCTAssertFalse(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    func test_userIdMissing_returnsFalse() {
        let payload: [String: Any] = ["roomId": "999"]
        XCTAssertFalse(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    func test_roomIdMissing_returnsFalse() {
        let payload: [String: Any] = ["userId": "1001"]
        XCTAssertFalse(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    // MARK: - 空登录态

    func test_myUserIdNil_returnsFalse() {
        let payload: [String: Any] = ["userId": "1001", "roomId": "999"]
        XCTAssertFalse(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: nil, chatRoomId: "999"))
    }

    func test_myUserIdEmpty_returnsFalse() {
        let payload: [String: Any] = ["userId": "1001", "roomId": "999"]
        XCTAssertFalse(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: "", chatRoomId: "999"))
    }

    // MARK: - 边界（空字段值）

    func test_payloadUserIdEmptyString_returnsFalse() {
        // stringify 对空 String 返 nil → false
        let payload: [String: Any] = ["userId": "", "roomId": "999"]
        XCTAssertFalse(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    func test_payloadRoomIdEmptyString_returnsFalse() {
        let payload: [String: Any] = ["userId": "1001", "roomId": ""]
        XCTAssertFalse(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    // MARK: - 前向兼容

    func test_extraFields_ignored_stillTrue() {
        let payload: [String: Any] = [
            "userId": 1001, "roomId": 999,
            "seatIndex": 3, "kickReason": "violation", "operatorUserId": "admin-1"
        ]
        XCTAssertTrue(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    // MARK: - 跨型组合

    func test_payloadUserIdNumber_myUserIdString_crossTypeMatch_returnsTrue() {
        // payload userId=Number 1001, my userId="1001" → stringify 归一通过
        let payload: [String: Any] = ["userId": NSNumber(value: 1001), "roomId": "999"]
        XCTAssertTrue(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    func test_payloadRoomIdNumber_chatRoomIdString_crossTypeMatch_returnsTrue() {
        let payload: [String: Any] = ["userId": 1001, "roomId": NSNumber(value: 999)]
        XCTAssertTrue(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }

    func test_userIdMatch_butRoomIdMismatch_doubleGuard_returnsFalse() {
        // 双字段守护：单一字段匹配不足
        let payload: [String: Any] = ["userId": 1001, "roomId": 8888]
        XCTAssertFalse(PartyKickedOutGuard.shouldHandle(payload: payload, myUserId: me, chatRoomId: "999"))
    }
}
