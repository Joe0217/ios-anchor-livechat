import XCTest

/// PartyRoomInfo / PartyRoomSeat Codable + 衍生属性单测。
///
/// 覆盖：
/// - dev 真实 `room/list` 最小帧 / `room/enter` 完整帧（含 roomSeatList）decode 正路径
/// - 衍生 var：selfRoleType（三 fallback 链）/ roomTempIdInt / stableListId / onlineCount
/// - schema 脆弱性（**PASS_WITH_CONCERNS**）：roomTempId / id / roomRoleType / isPlatformAdmin / heatValue 当前无类型容错；
///   单测以 `XCTAssertThrowsError` 锁定"现状脆弱契约"，后端真出现类型偷换才补 init(from:)
/// - extra 字段前向兼容
final class PartyRoomInfoDecodeTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - 正路径

    func test_decode_minimalRoomList_succeeds() {
        // dev `room/list` 单条最小帧（v3 真值版）
        let json = """
        {
            "id": "100",
            "ownerId": "1001",
            "roomName": "Cozy Room",
            "yxRoomId": "yx-100",
            "agoraChannelId": "ch-100",
            "heatValue": 50,
            "roomTempId": "1",
            "onlineUserList": [
                {"userId": "u1", "nickname": "Alice"},
                {"userId": "u2", "nickname": "Bob"}
            ]
        }
        """.data(using: .utf8)!
        let info = try? decoder.decode(PartyRoomInfo.self, from: json)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.id, "100")
        XCTAssertEqual(info?.roomName, "Cozy Room")
        XCTAssertEqual(info?.heatValue, 50)
        XCTAssertEqual(info?.onlineUserList?.count, 2)
    }

    func test_decode_fullRoomEnter_withSeats_succeeds() {
        let json = """
        {
            "id": "100",
            "ownerId": "1001",
            "roomRoleType": 3,
            "isPlatformAdmin": false,
            "roomName": "Test Room",
            "roomTempId": "1",
            "rtcToken": "agora-token-xyz",
            "yxRoomId": "yx-100",
            "agoraChannelId": "ch-100",
            "roomSeatList": [
                {"seatIndex": 1, "userId": "1001", "nickname": "Owner", "seatType": 1, "isOccupied": 1, "cameraEnabled": 1, "microphoneEnabled": 1},
                {"seatIndex": 2, "seatType": 2, "isOccupied": 0}
            ]
        }
        """.data(using: .utf8)!
        let info = try? decoder.decode(PartyRoomInfo.self, from: json)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.roomSeatList?.count, 2)
        XCTAssertEqual(info?.roomSeatList?[0].seatIndex, 1)
        XCTAssertEqual(info?.roomSeatList?[0].seatType, 1)
        XCTAssertEqual(info?.roomSeatList?[1].seatIndex, 2)
        XCTAssertEqual(info?.rtcToken, "agora-token-xyz")
    }

    // MARK: - selfRoleType 衍生（三 fallback 链）

    func test_selfRoleType_isPlatformAdminTrue_returnsAdmin() {
        let info = makeRoom(isPlatformAdmin: true, roomRoleType: 3, ownerId: "other")
        XCTAssertEqual(info.selfRoleType(myUserId: "1001"), .admin)
    }

    func test_selfRoleType_roomRoleType_admin_returnsAdmin() {
        let info = makeRoom(isPlatformAdmin: nil, roomRoleType: 2, ownerId: "other")
        XCTAssertEqual(info.selfRoleType(myUserId: "1001"), .admin)
    }

    func test_selfRoleType_roomRoleType_audience_returnsAudience() {
        let info = makeRoom(isPlatformAdmin: nil, roomRoleType: 3, ownerId: "other")
        XCTAssertEqual(info.selfRoleType(myUserId: "1001"), .audience)
    }

    func test_selfRoleType_fallback_ownerIdMatch_returnsOwner() {
        // roomRoleType nil 时退化到 ownerId 比较
        let info = makeRoom(isPlatformAdmin: nil, roomRoleType: nil, ownerId: "1001")
        XCTAssertEqual(info.selfRoleType(myUserId: "1001"), .owner)
    }

    func test_selfRoleType_fallback_ownerIdMismatch_returnsAudience() {
        let info = makeRoom(isPlatformAdmin: nil, roomRoleType: nil, ownerId: "other")
        XCTAssertEqual(info.selfRoleType(myUserId: "1001"), .audience)
    }

    // MARK: - roomTempIdInt 衍生

    func test_roomTempIdInt_validNumericString_parses() {
        let info = makeRoom(roomTempId: "5")
        XCTAssertEqual(info.roomTempIdInt, 5)
    }

    func test_roomTempIdInt_emptyString_defaultsToOne() {
        let info = makeRoom(roomTempId: "")
        XCTAssertEqual(info.roomTempIdInt, 1)
    }

    func test_roomTempIdInt_nil_defaultsToOne() {
        let info = makeRoom(roomTempId: nil)
        XCTAssertEqual(info.roomTempIdInt, 1)
    }

    func test_roomTempIdInt_invalidString_defaultsToOne() {
        let info = makeRoom(roomTempId: "abc")
        XCTAssertEqual(info.roomTempIdInt, 1)
    }

    // MARK: - stableListId 衍生（与 PartyIdentityTests 互补，此处偏 decode 后行为）

    func test_stableListId_decodedWithId_usesIdPrefix() {
        let json = """
        {"id": "abc"}
        """.data(using: .utf8)!
        let info = try? decoder.decode(PartyRoomInfo.self, from: json)
        XCTAssertEqual(info?.stableListId, "id_abc")
    }

    func test_stableListId_decodedAllNil_returnsUnknown() {
        let json = "{}".data(using: .utf8)!
        let info = try? decoder.decode(PartyRoomInfo.self, from: json)
        XCTAssertEqual(info?.stableListId, "unknown")
    }

    // MARK: - onlineCount 衍生

    func test_onlineCount_withList_returnsCount() {
        let json = """
        {"onlineUserList": [{"userId":"a"}, {"userId":"b"}, {"userId":"c"}]}
        """.data(using: .utf8)!
        let info = try? decoder.decode(PartyRoomInfo.self, from: json)
        XCTAssertEqual(info?.onlineCount, 3)
    }

    func test_onlineCount_emptyList_returnsZero() {
        let json = """
        {"onlineUserList": []}
        """.data(using: .utf8)!
        let info = try? decoder.decode(PartyRoomInfo.self, from: json)
        XCTAssertEqual(info?.onlineCount, 0)
    }

    func test_onlineCount_nilList_returnsZero() {
        let json = "{}".data(using: .utf8)!
        let info = try? decoder.decode(PartyRoomInfo.self, from: json)
        XCTAssertEqual(info?.onlineCount, 0)
    }

    // MARK: - 前向兼容 / 全 nil

    func test_decode_extraFields_forwardCompat() {
        let json = """
        {
            "id": "100",
            "futureNewField": "ignored",
            "anotherUnknown": 12345
        }
        """.data(using: .utf8)!
        let info = try? decoder.decode(PartyRoomInfo.self, from: json)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.id, "100")
    }

    func test_decode_emptyObject_allNilFields() {
        let json = "{}".data(using: .utf8)!
        let info = try? decoder.decode(PartyRoomInfo.self, from: json)
        XCTAssertNotNil(info)
        XCTAssertNil(info?.id)
        XCTAssertNil(info?.ownerId)
    }

    // MARK: - PartyRoomSeat occupied 衍生

    func test_seat_occupied_isOccupiedOne_returnsTrue() {
        let json = """
        {"seatIndex": 1, "isOccupied": 1}
        """.data(using: .utf8)!
        let seat = try? decoder.decode(PartyRoomSeat.self, from: json)
        XCTAssertEqual(seat?.occupied, true)
    }

    func test_seat_occupied_isOccupiedZero_butUserIdPresent_returnsTrue_byDualCheck() {
        // 双判：占位字段 0 但 userId 非空仍视为占用（安卓口径）
        let json = """
        {"seatIndex": 1, "isOccupied": 0, "userId": "1001"}
        """.data(using: .utf8)!
        let seat = try? decoder.decode(PartyRoomSeat.self, from: json)
        XCTAssertEqual(seat?.occupied, true)
    }

    func test_seat_occupied_allEmpty_returnsFalse() {
        let json = """
        {"seatIndex": 1}
        """.data(using: .utf8)!
        let seat = try? decoder.decode(PartyRoomSeat.self, from: json)
        XCTAssertEqual(seat?.occupied, false)
    }

    func test_seat_isMicrophoneMuted_emptySeatWithAdminMute_returnsTrue() {
        let json = """
        {"seatIndex": 1, "isOccupied": 0, "seatMicrophoneEnabled": 0}
        """.data(using: .utf8)!
        let seat = try? decoder.decode(PartyRoomSeat.self, from: json)
        XCTAssertEqual(seat?.isMicrophoneMuted, true)
    }

    func test_videoSeat_adminMute_isDistinguishedFromUserMute() {
        let json = """
        {"seatIndex": 1, "seatType": 1, "microphoneEnabled": 1, "seatMicrophoneEnabled": 0}
        """.data(using: .utf8)!
        let seat = try? decoder.decode(PartyRoomSeat.self, from: json)

        XCTAssertEqual(seat?.isVideoSeat, true)
        XCTAssertEqual(seat?.isSeatMicrophoneProhibited, true)
        XCTAssertEqual(seat?.isUserMicrophoneMuted, false)
        XCTAssertEqual(seat?.isMicrophoneMuted, true)
    }

    func test_seat_isMCSeat_hostSeatOne_returnsTrue() {
        let json = """
        {"seatIndex": 1, "isHostSeat": 1}
        """.data(using: .utf8)!
        let seat = try? decoder.decode(PartyRoomSeat.self, from: json)
        XCTAssertEqual(seat?.isMCSeat, true)
    }

    func test_seatInviteCandidate_decodesNumericUserIdAndScore() throws {
        let json = """
        {"userId": 1001, "nickname": "Mia", "avatar": "https://example.com/a.png", "userType": 1, "score": 42}
        """.data(using: .utf8)!
        let candidate = try decoder.decode(PartySeatInviteCandidate.self, from: json)
        XCTAssertEqual(candidate.userId, "1001")
        XCTAssertEqual(candidate.nickname, "Mia")
        XCTAssertEqual(candidate.userType, 1)
        XCTAssertEqual(candidate.score, "42")
    }

    // MARK: - schema 脆弱性 PASS_WITH_CONCERNS

    func test_roomTempId_Number_typeFragile_throws() {
        // FIXME: schema 脆弱 — 后端真实返 String "1"，若改为 Number 1 当前 decode 会 fail
        // 本断言锁定**当前脆弱契约**，未来后端类型偷换会让本测试 PASS（assertion 失败）
        // 那时再补 PartyRoomInfo.init(from:) 跨型容错
        let json = """
        {"roomTempId": 1}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PartyRoomInfo.self, from: json))
    }

    func test_isPlatformAdmin_Int_typeFragile_throws() {
        // FIXME: schema 脆弱 — 当前 isPlatformAdmin: Bool?，后端若改为 Int 0/1 会 fail
        let json = """
        {"isPlatformAdmin": 1}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PartyRoomInfo.self, from: json))
    }

    func test_withUpdated_roomRoleType_updatesRoleWithoutChangingOtherFields() {
        let room = makeRoom(roomRoleType: PartyRoomRoleType.audience.rawValue, ownerId: "owner")

        let updated = room.withUpdated(roomRoleType: PartyRoomRoleType.admin.rawValue)

        XCTAssertEqual(updated.roomRoleType, PartyRoomRoleType.admin.rawValue)
        XCTAssertEqual(updated.ownerId, "owner")
    }

    func test_cornerBannerList_decodesNumericIdAndUrls() throws {
        let json = """
        {
            "cornerBannerList": [
                {"id": 42, "picUrl": "https://cdn.example/banner.png", "directUrl": "https://activity.example/play"}
            ]
        }
        """.data(using: .utf8)!

        let info = try decoder.decode(PartyRoomInfo.self, from: json)

        XCTAssertEqual(info.cornerBannerList?.first?.id, "42")
        XCTAssertEqual(info.cornerBannerList?.first?.picUrl, "https://cdn.example/banner.png")
        XCTAssertEqual(info.cornerBannerList?.first?.directUrl, "https://activity.example/play")
        XCTAssertEqual(info.cornerBannerList?.first?.isDisplayable, true)
    }

    func test_bannerList_decodesNumericIdAndKeepsItemsWithoutDirectUrlDisplayable() throws {
        let json = """
        {
            "bannerList": [
                {"id": 43, "picUrl": "https://cdn.example/party-banner.png"}
            ]
        }
        """.data(using: .utf8)!

        let info = try decoder.decode(PartyRoomInfo.self, from: json)

        XCTAssertEqual(info.bannerList?.first?.id, "43")
        XCTAssertEqual(info.bannerList?.first?.picUrl, "https://cdn.example/party-banner.png")
        XCTAssertTrue(info.bannerList?.first?.isDisplayable == true)
        XCTAssertFalse(info.bannerList?.first?.isNavigable == true)
    }

    // MARK: - helpers

    private func makeRoom(isPlatformAdmin: Bool? = nil,
                          roomRoleType: Int? = nil,
                          ownerId: String? = nil,
                          roomTempId: String? = nil) -> PartyRoomInfo {
        PartyRoomInfo(
            id: nil, ownerId: ownerId, roomRoleType: roomRoleType, isPlatformAdmin: isPlatformAdmin,
            roomName: nil, roomAvatar: nil, greetingMessage: nil, roomLanguage: nil,
            heatValue: nil, roomStatus: nil, lockFlag: nil,
            yxRoomId: nil, agoraChannelId: nil, rtcToken: nil,
            onlineUserList: nil, score: nil, createTime: nil, needPassword: nil,
            snapshotId: nil, roomTempId: roomTempId, roomTempType: nil, rangIndex: nil,
            showChest: nil, gemsTotal: nil, pkStatus: nil, pkId: nil, roomSeatList: nil
        )
    }
}
