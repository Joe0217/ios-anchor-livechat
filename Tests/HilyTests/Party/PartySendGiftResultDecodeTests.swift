import XCTest
// 待测源码通过 project.yml HilyTests.sources 编入；同 module 无需 @testable import

/// H-5 派对房送礼 response `PartySendGiftResult` 多别名 decode 单测（spec §2.4 · 红队 P0-2）。
///
/// 覆盖 4 候选字段名（`userDiamond` / `userDiamonds` / `newDiamond` / `remainDiamond`）
/// + 均无字段兜底 nil。契约动机对齐 `agent-recon-field-names-unverified` rule：
/// 后端字段名未真机验证 → CodingKeys 兜底 4 候选，任一命中即 decode 成功。
final class PartySendGiftResultDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> PartySendGiftResult {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(PartySendGiftResult.self, from: data)
    }

    // MARK: - 多别名命中

    func test_userDiamond_hit() throws {
        let r = try decode(#"{"success":true,"giftId":42,"num":1,"totalValue":100,"userDiamond":8888}"#)
        XCTAssertEqual(r.success, true)
        XCTAssertEqual(r.giftId, 42)
        XCTAssertEqual(r.num, 1)
        XCTAssertEqual(r.totalValue, 100)
        XCTAssertEqual(r.userDiamond, 8888)
    }

    func test_userDiamonds_pluralAlias_hit() throws {
        let r = try decode(#"{"success":true,"giftId":42,"num":1,"userDiamonds":7777}"#)
        XCTAssertEqual(r.userDiamond, 7777)
    }

    func test_newDiamond_alias_hit() throws {
        let r = try decode(#"{"success":true,"giftId":42,"num":1,"newDiamond":6666}"#)
        XCTAssertEqual(r.userDiamond, 6666)
    }

    func test_remainDiamond_alias_hit() throws {
        let r = try decode(#"{"success":true,"giftId":42,"num":1,"remainDiamond":5555}"#)
        XCTAssertEqual(r.userDiamond, 5555)
    }

    // MARK: - 无余额字段（兜底 nil）

    func test_noBalanceField_returnsNil_notFail() throws {
        let r = try decode(#"{"success":true,"giftId":42,"num":1,"totalValue":100}"#)
        XCTAssertNil(r.userDiamond)
        XCTAssertEqual(r.success, true)
    }

    // MARK: - 优先级：userDiamond 优先于其他别名（若同时出现）

    func test_multipleAliasesInSameResponse_userDiamondWins() throws {
        // 现实中不应同时出现，但契约兜底行为：userDiamond > userDiamonds > newDiamond > remainDiamond
        let r = try decode(#"{"userDiamond":1,"userDiamonds":2,"newDiamond":3,"remainDiamond":4}"#)
        XCTAssertEqual(r.userDiamond, 1)
    }

    // MARK: - 基础字段兼容

    func test_allFieldsMissing_returnsAllNils() throws {
        let r = try decode(#"{}"#)
        XCTAssertNil(r.success)
        XCTAssertNil(r.giftId)
        XCTAssertNil(r.num)
        XCTAssertNil(r.totalValue)
        XCTAssertNil(r.userDiamond)
    }

    func test_successFalse_stillDecodable() throws {
        let r = try decode(#"{"success":false,"giftId":42,"num":1}"#)
        XCTAssertEqual(r.success, false)
        XCTAssertNil(r.userDiamond)
    }
}
