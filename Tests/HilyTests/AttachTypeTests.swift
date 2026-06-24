import XCTest

/// G 里程碑 M1 AttachType 解析单测（spec §1.4 / §B.2）。
///
/// 覆盖：Int 正数 / Int 负数 / String 数字 / String 负数 / nil / unknown 兜底 / 既有 B 段不破坏。
final class AttachTypeTests: XCTestCase {

    // MARK: - 既有 B 段不破坏

    func test_existingPositiveInt_matches() {
        XCTAssertEqual(AttachType(raw: NSNumber(value: 1)), .sendGift)
        XCTAssertEqual(AttachType(raw: NSNumber(value: 4)), .liveCallGift)
        // H 校验清单 §1.1.2 A 表：15 = 通话每分钟预估收入（B 期错命名 backpackGift 已修正）
        XCTAssertEqual(AttachType(raw: NSNumber(value: 15)), .callIncomePerMinute)
        XCTAssertEqual(AttachType(raw: NSNumber(value: 44)), .forceEndLive)
        XCTAssertEqual(AttachType(raw: NSNumber(value: 62)), .banned)
    }

    func test_existingSendGiftString_matches() {
        XCTAssertEqual(AttachType(raw: "SEND_GIFT"), .sendGift)
    }

    // MARK: - G 里程碑 PK 段 Int 正数

    func test_pkInt_97_98_99_100() {
        XCTAssertEqual(AttachType(raw: NSNumber(value: 97)), .pkInvite)
        XCTAssertEqual(AttachType(raw: NSNumber(value: 98)), .pkScoreUpdate)
        XCTAssertEqual(AttachType(raw: NSNumber(value: 99)), .pkInviteAck)
        XCTAssertEqual(AttachType(raw: NSNumber(value: 100)), .pkStatusBundle)
    }

    // MARK: - G 里程碑 PK 段 Int 负数（H5 livePk.js:326/334 推送形态）

    func test_pkNegativeInt_minus8_minus9() {
        XCTAssertEqual(AttachType(raw: NSNumber(value: -8)), .pkMuteBroadcast)
        XCTAssertEqual(AttachType(raw: NSNumber(value: -9)), .pkChatNotice)
    }

    // MARK: - G 里程碑 PK 段 String 负数兜底（R2 推送形态待 M1 后端确认；先双形态保护）

    func test_pkNegativeString_minus8_minus9() {
        XCTAssertEqual(AttachType(raw: "-8"), .pkMuteBroadcast)
        XCTAssertEqual(AttachType(raw: "-9"), .pkChatNotice)
    }

    // MARK: - G 里程碑 PK 段 String 数字兜底（防御 H5 跨字段类型差异）

    func test_pkPositiveString_97_98_99_100() {
        XCTAssertEqual(AttachType(raw: "97"), .pkInvite)
        XCTAssertEqual(AttachType(raw: "98"), .pkScoreUpdate)
        XCTAssertEqual(AttachType(raw: "99"), .pkInviteAck)
        XCTAssertEqual(AttachType(raw: "100"), .pkStatusBundle)
    }

    // MARK: - nil / 未识别 → unknown

    func test_nilRaw_returnsUnknown() {
        let t = AttachType(raw: nil)
        if case .unknown(let raw) = t {
            XCTAssertEqual(raw, "nil")
        } else {
            XCTFail("nil 应解析为 .unknown(raw: \"nil\")")
        }
    }

    func test_unknownInt_returnsUnknownWithRawString() {
        let t = AttachType(raw: NSNumber(value: 9999))
        if case .unknown(let raw) = t {
            XCTAssertEqual(raw, "9999")
        } else {
            XCTFail("未识别 Int 应回归 .unknown")
        }
    }

    func test_unknownString_returnsUnknownPreservingRaw() {
        let t = AttachType(raw: "SOME_NEW_TYPE")
        if case .unknown(let raw) = t {
            XCTAssertEqual(raw, "SOME_NEW_TYPE")
        } else {
            XCTFail("未识别 String 应回归 .unknown 保留原值")
        }
    }

    // MARK: - raw round-trip（AttachType ↔ raw 双向一致）

    func test_pkRawValues_alignWithSpec() {
        XCTAssertEqual(AttachType.pkInvite.raw, "97")
        XCTAssertEqual(AttachType.pkScoreUpdate.raw, "98")
        XCTAssertEqual(AttachType.pkInviteAck.raw, "99")
        XCTAssertEqual(AttachType.pkStatusBundle.raw, "100")
        XCTAssertEqual(AttachType.pkMuteBroadcast.raw, "-8")
        XCTAssertEqual(AttachType.pkChatNotice.raw, "-9")
    }
}
