import XCTest

/// PartyAttachType 单测（v3 通知基建 · 2026-07-14）。
///
/// **覆盖矩阵**：
/// 1. 核心 6 类房态信令 round-trip（1001/1003/1008/1012/1015/2049）
/// 2. 视频位邀请 9 类 round-trip（1040-1048）
/// 3. E v2 房态扩展 round-trip（1017/1018/1021/1029）
/// 4. **v3 新增**：35 个两端一致 attachType 全部 round-trip（对齐 `/Users/joe/Downloads/party房通知类型-安卓vsH5对比.md`）
/// 5. **v3 新增**：`PartyKnownButUnhandledAttachType.codes` 与 enum rawValue 不相交（互斥性）
/// 6. 未知 rawValue 既不进 enum 也不进 codes
///
/// **v3 移除**：`toMsgType()` 相关测试（enum PartyMsgType 已弃用，改用 unified PublicChatVariant）
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

    func test_freeGameResult_roundTrip() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 144), .freeGameResult)
        XCTAssertEqual(PartyAttachType.freeGameResult.rawValue, 144)
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

    // MARK: - 3. E v2 扩展 + 1029 私 call round-trip

    func test_ev2_extensions_roundTrip() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 1017), .changeMode)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1018), .queueSeatUpdate)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1021), .micApplicationSwitch)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1029), .privateCallNotify)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1004), .userEnterVehicle)
    }

    // MARK: - 4. v3：35 个两端一致 attachType 全部覆盖

    /// 对齐对比文档 `/Users/joe/Downloads/party房通知类型-安卓vsH5对比.md` §二 35 个两端一致的类型。
    func test_v3_all_35_common_attach_types_covered() {
        let expected: [Int: PartyAttachType] = [
            -11: .emojiPlay, -10: .emojiStatic,
            136: .gameWinNotifyGlobal, 138: .pkSmallPrize, 140: .winnerBroadcastGlobal,
            1001: .seatUpdate, 1003: .kickedOut, 1004: .userEnterVehicle,
            1007: .giftLegacy, 1008: .updateMedia,
            1009: .roomCloseOrWhitelist, 1011: .musicSongChange,
            1012: .seatUpdateList, 1013: .musicSwitchPerUser, 1014: .auditGuardWarning,
            1015: .prohibitMic, 1017: .changeMode, 1018: .queueSeatUpdate,
            1019: .authUpdate, 1021: .micApplicationSwitch, 1024: .platformAdminChange,
            1025: .roomBgUpdate, 1029: .privateCallNotify,
            1040: .inviteVideoSeat, 1041: .inviteVideoSeatAccept, 1042: .inviteVideoSeatReject,
            1043: .inviteVideoSeatTimeout, 1044: .inviteVideoSeatLeave,
            1045: .inviteVideoSeatOccupied, 1046: .inviteVideoSeatAlreadyOn,
            1047: .inviteVideoSeatBroadcast,
            1049: .roomAnnouncement, 1050: .luckyNumberDraw,
            1051: .luckyNumberWin, 1052: .luckyNumberPersonalDialog,
            2049: .giftCompressed,
        ]
        XCTAssertEqual(expected.count, 35, "对比文档 §二 有 35 个两端一致类型")
        for (raw, kind) in expected {
            XCTAssertEqual(PartyAttachType.from(rawValue: raw), kind, "raw=\(raw) missing")
            XCTAssertEqual(kind.rawValue, raw, "kind=\(kind) rawValue mismatch")
        }
    }

    /// H5 独有 3 类：1016/1020 已加占位 case；1027 不加（P2P 通道，非派对房聊天室）
    func test_v3_h5_specific_types() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 1016), .roomLock)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1020), .rejectMicLegacy)
        XCTAssertNil(PartyAttachType.from(rawValue: 1027), "1027 是 P2P 通道，主播端不消费")
    }

    /// Android 独有已加占位 case：1026 / 1030-1033 / 1048 / 1104 / 1107 / 1108 / 1111
    func test_v3_android_specific_placeholders() {
        XCTAssertEqual(PartyAttachType.from(rawValue: 1026), .roomBgExpire)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1030), .diamondGiftSend)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1031), .diamondGiftGrab)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1032), .diamondGiftSplit)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1033), .diamondGiftSettle)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1048), .inviteVideoSeatJoinFailed)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1104), .battleHeartbeat)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1107), .battleGiftNotify)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1108), .battleForceEndConfirm)
        XCTAssertEqual(PartyAttachType.from(rawValue: 1111), .battleApplyPendingNotice)
    }

    // MARK: - 5. v3：codes 与 enum 不相交

    /// v3 收敛后 `codes` 只保留**未加 case** 的项；144 已由免费互动链路接管。
    /// 单测锁定：任一 codes 内的 rawValue **必须** `from(rawValue:)` 返回 nil。
    func test_v3_codes_disjoint_from_enum() {
        for raw in PartyKnownButUnhandledAttachType.codes {
            XCTAssertNil(PartyAttachType.from(rawValue: raw),
                         "codes 与 enum 不相交违反：\(raw) 应仅在 codes 或仅在 enum，不能同时")
        }
    }

    /// codes 现内容锁定（v3 收敛后）：{45, 195, 1002, 1010}
    func test_v3_codes_current_content() {
        let expected: Set<Int> = [45, 195, 1002, 1010]
        XCTAssertEqual(PartyKnownButUnhandledAttachType.codes, expected,
                       "v3 codes 应只保留未加 case 的 Android 独有 + 值冲突 45")
    }

    // MARK: - 6. 未知 attachType（无 named case + 无 codes）

    func test_unknown_attachType_notMappedNotInKnown() {
        XCTAssertNil(PartyAttachType.from(rawValue: 99999))
        XCTAssertFalse(PartyKnownButUnhandledAttachType.codes.contains(99999))
    }
}
