import XCTest

/// H 里程碑 M3-4 PartyAttachType 单测（spec §5）。
///
/// 覆盖：
/// 1. 6+9 = 15 个 named case 的 rawValue Int round-trip（`PartyAttachType.from(rawValue:)`）
/// 2. F 期 / 值冲突 attachType 不归 named case（应进入 `PartyKnownButUnhandledAttachType.codes`）
/// 3. `toMsgType()` 映射（仅 giftCompressed 映射到 .gift；其他全部 nil 表示房态信令不上公屏）
///
/// PartyMessageRouter 业务分发（attachType → delegate.partyRoomChat(...) 回调）依赖
/// NIMSDK + PartyRoomChatManager 类型，不能进 logic test bundle；留 M6 集成测试覆盖。
final class PartyAttachTypeTests: XCTestCase {

    // MARK: - 1. 核心 6 类房态信令 round-trip

    func test_core6_seatUpdate_roundTrip() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 1001), .seatUpdate)
        XCTAssertEqual(PartyAttachType.seatUpdate.rawValue, 1001)
    }

    func test_core6_kickedOut_roundTrip() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 1003), .kickedOut)
        XCTAssertEqual(PartyAttachType.kickedOut.rawValue, 1003)
    }

    func test_core6_updateMedia_roundTrip() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 1008), .updateMedia)
        XCTAssertEqual(PartyAttachType.updateMedia.rawValue, 1008)
    }

    func test_core6_seatUpdateList_roundTrip() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 1012), .seatUpdateList)
        XCTAssertEqual(PartyAttachType.seatUpdateList.rawValue, 1012)
    }

    func test_core6_prohibitMic_roundTrip() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 1015), .prohibitMic)
        XCTAssertEqual(PartyAttachType.prohibitMic.rawValue, 1015)
    }

    func test_core6_giftCompressed_roundTrip() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 2049), .giftCompressed)
        XCTAssertEqual(PartyAttachType.giftCompressed.rawValue, 2049)
    }

    // MARK: - 2. 视频位邀请 9 类 1040-1048 round-trip

    func test_inviteVideoSeat_range_1040_1048_allMapped() {
        let expected: [Int: PartyAttachType] = [
            1040: .inviteVideoSeat,
            1041: .inviteVideoSeatAccept,
            1042: .inviteVideoSeatReject,
            1043: .inviteVideoSeatTimeout,
            1044: .inviteVideoSeatLeave,
            1045: .inviteVideoSeatOccupied,
            1046: .inviteVideoSeatAlreadyOn,
            1047: .inviteVideoSeatBroadcast,
            1048: .inviteVideoSeatJoinFailed,
        ]
        for (raw, kind) in expected {
            XCTAssertEqual(PartyAttachType.from(rawValue: raw), kind, "raw=\(raw)")
            XCTAssertEqual(kind.rawValue, raw, "kind=\(kind)")
        }
    }

    // MARK: - 3. F 期 / 值冲突 → knownButUnhandled，不归 named case

    func test_fStage_attachType_notMapped() {
        // F 期非 range case
        for raw in [1004, 1014, 1017, 1049, 1007] {
            XCTAssertNil(PartyAttachType.from(rawValue: raw),
                         "F 期 attachType \(raw) 不应被 PartyAttachType 识别为 named case")
            XCTAssertTrue(PartyKnownButUnhandledAttachType.codes.contains(raw),
                          "F 期 attachType \(raw) 应在 PartyKnownButUnhandledAttachType.codes 内（降噪用）")
        }
    }

    func test_partyBattle_range_1100_1112_inKnownUnhandled() {
        // PartyBattle PK 13 类
        for raw in 1100...1112 {
            XCTAssertNil(PartyAttachType.from(rawValue: raw),
                         "PartyBattle attachType \(raw) F 期不实现")
            XCTAssertTrue(PartyKnownButUnhandledAttachType.codes.contains(raw),
                          "PartyBattle attachType \(raw) 应在 codes 内")
        }
    }

    func test_luckyNumber_range_1050_1052_inKnownUnhandled() {
        for raw in [1050, 1051, 1052] {
            XCTAssertNil(PartyAttachType.from(rawValue: raw))
            XCTAssertTrue(PartyKnownButUnhandledAttachType.codes.contains(raw))
        }
    }

    func test_valueConflict_45_and_1029_inKnownUnhandled() {
        // spec §1.0.2 值冲突项
        XCTAssertNil(PartyAttachType.from(rawValue: 45))
        XCTAssertNil(PartyAttachType.from(rawValue: 1029))
        XCTAssertTrue(PartyKnownButUnhandledAttachType.codes.contains(45))
        XCTAssertTrue(PartyKnownButUnhandledAttachType.codes.contains(1029))
    }

    // MARK: - 4. toMsgType 映射

    func test_toMsgType_giftCompressed_mapsToGift() {
        XCTAssertEqual(PartyAttachType.giftCompressed.toMsgType(), .gift)
    }

    func test_toMsgType_seatUpdate_isNilNotForPublicScreen() {
        // 房态信令不上公屏 → nil
        XCTAssertNil(PartyAttachType.seatUpdate.toMsgType())
        XCTAssertNil(PartyAttachType.kickedOut.toMsgType())
        XCTAssertNil(PartyAttachType.prohibitMic.toMsgType())
        XCTAssertNil(PartyAttachType.updateMedia.toMsgType())
        XCTAssertNil(PartyAttachType.seatUpdateList.toMsgType())
    }

    func test_toMsgType_inviteVideoSeat_isNil() {
        // 邀请消息是 P2P 触发 UI 弹窗，不上公屏
        XCTAssertNil(PartyAttachType.inviteVideoSeat.toMsgType())
        XCTAssertNil(PartyAttachType.inviteVideoSeatAccept.toMsgType())
        XCTAssertNil(PartyAttachType.inviteVideoSeatJoinFailed.toMsgType())
    }

    // MARK: - 5. 未知 attachType（无 named case + 无 knownButUnhandled）

    func test_unknown_attachType_notMappedNotInKnown() {
        // 比如 99999 完全未识别——M3 路由器会打 notice 日志而非降噪
        XCTAssertNil(PartyAttachType.from(rawValue: 99999))
        XCTAssertFalse(PartyKnownButUnhandledAttachType.codes.contains(99999))
    }
}
