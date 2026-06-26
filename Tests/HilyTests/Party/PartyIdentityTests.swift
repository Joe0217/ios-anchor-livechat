import XCTest

/// 派对房 SwiftUI ForEach 用稳定 Identity 单测（review 202606252033 P1-5）。
///
/// 背景：原 `PartyRoomSeat.id: String?` / `PartyRoomInfo.id: String?` 可能 nil；
/// 多个 nil 会让 ForEach Identity 坍缩 → PartyRemoteVideoView 误调 dismantle → 远端视频黑屏。
/// `stableId` / `stableListId` 用业务键 fallback 串保证唯一性。
final class PartyIdentityTests: XCTestCase {

    // MARK: - PartyRoomSeat.stableId

    func test_seat_stableId_usesSeatIndex_whenPresent() {
        let seat = makeSeat(seatIndex: 5)
        XCTAssertEqual(seat.stableId, 5)
    }

    func test_seat_stableId_fallsBackToMinusOne_whenSeatIndexNil() {
        let seat = makeSeat(seatIndex: nil)
        XCTAssertEqual(seat.stableId, -1)
    }

    func test_seat_stableId_multipleNilSeats_collapseToSameId_byDesign() {
        // 设计降级：多个 nil seatIndex 麦位坍缩到 -1
        // 现实后端必给 seatIndex，单测仅断言降级行为不 crash + 标记同 Identity 是 known
        let a = makeSeat(seatIndex: nil)
        let b = makeSeat(seatIndex: nil)
        XCTAssertEqual(a.stableId, b.stableId)
        XCTAssertEqual(a.stableId, -1)
    }

    // MARK: - PartyRoomInfo.stableListId

    func test_roomInfo_stableListId_prefersId_withPrefix() {
        let info = makeRoom(id: "x", agoraChannelId: "ch", yxRoomId: "yx", ownerId: "ow", roomName: "nm")
        XCTAssertEqual(info.stableListId, "id_x")
    }

    func test_roomInfo_stableListId_fallsBackThroughChain() {
        // id nil → agoraChannelId → yxRoomId → ownerId → roomName
        XCTAssertEqual(makeRoom(id: nil, agoraChannelId: "ch", yxRoomId: nil, ownerId: nil, roomName: nil).stableListId, "ch_ch")
        XCTAssertEqual(makeRoom(id: nil, agoraChannelId: nil, yxRoomId: "yx", ownerId: nil, roomName: nil).stableListId, "yx_yx")
        XCTAssertEqual(makeRoom(id: nil, agoraChannelId: nil, yxRoomId: nil, ownerId: "ow", roomName: nil).stableListId, "ow_ow")
        XCTAssertEqual(makeRoom(id: nil, agoraChannelId: nil, yxRoomId: nil, ownerId: nil, roomName: "nm").stableListId, "nm_nm")
        XCTAssertEqual(makeRoom(id: nil, agoraChannelId: nil, yxRoomId: nil, ownerId: nil, roomName: nil).stableListId, "unknown")
    }

    func test_roomInfo_stableListId_prefixSeparates_sameValueInDifferentFields() {
        // 关键不变量：前缀防同串值跨字段域串扰
        // id="x" 的 listId 必须 ≠ ownerId="x" 的 listId
        let a = makeRoom(id: "x", agoraChannelId: nil, yxRoomId: nil, ownerId: nil, roomName: nil)
        let b = makeRoom(id: nil, agoraChannelId: nil, yxRoomId: nil, ownerId: "x", roomName: nil)
        XCTAssertNotEqual(a.stableListId, b.stableListId)
        XCTAssertEqual(a.stableListId, "id_x")
        XCTAssertEqual(b.stableListId, "ow_x")
    }

    // MARK: - helpers

    private func makeSeat(seatIndex: Int?) -> PartyRoomSeat {
        PartyRoomSeat(
            id: nil, roomId: nil, seatIndex: seatIndex, userId: nil, avatar: nil, nickname: nil,
            seatType: nil, isOccupied: nil, cameraEnabled: nil, microphoneEnabled: nil,
            roomRoleType: nil, giftValueCount: nil, headFrame: nil, yxAccid: nil, userType: nil,
            seatCameraEnabled: nil, seatMicrophoneEnabled: nil, lockFlag: nil, roomTempId: nil,
            isHostSeat: nil, isPlatformAdmin: nil, showBubble: nil, anchorTaskRewardExt: nil
        )
    }

    private func makeRoom(id: String?, agoraChannelId: String?, yxRoomId: String?, ownerId: String?, roomName: String?) -> PartyRoomInfo {
        PartyRoomInfo(
            id: id, ownerId: ownerId, roomRoleType: nil, isPlatformAdmin: nil,
            roomName: roomName, roomAvatar: nil, greetingMessage: nil, roomLanguage: nil,
            heatValue: nil, roomStatus: nil, lockFlag: nil,
            yxRoomId: yxRoomId, agoraChannelId: agoraChannelId, rtcToken: nil,
            onlineUserList: nil, score: nil, createTime: nil, needPassword: nil,
            snapshotId: nil, roomTempId: nil, roomTempType: nil, rangIndex: nil,
            showChest: nil, gemsTotal: nil, pkStatus: nil, pkId: nil, roomSeatList: nil
        )
    }
}
