import XCTest
// test 文件不写 @testable import Hily —— HilyTests 是独立 module（白名单约定）

/// 覆盖 spec §5 F-1 ~ F-10 + R-3 + BlockedFeatures 位运算属性。
/// 见 [P-plan-用户权限管理系统-*.md] Task 2。
final class PermissionMappingTests: XCTestCase {

    // MARK: - F-1 ~ F-3: 未受限 userType

    func test_userType_2_isFullyAllowed() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 2), [])
    }

    func test_userType_9_isFullyAllowed() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 9), [])
    }

    func test_userType_nil_isFullyAllowed() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: nil), [])
    }

    // MARK: - F-4 ~ F-9: 六种黑名单 userType 矩阵

    func test_userType_101_blocksCallOnly() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 101), [.call])
    }

    func test_userType_102_blocksLiveOnly() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 102), [.live])
    }

    func test_userType_103_blocksPartyOnly() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 103), [.party])
    }

    func test_userType_104_blocksCallAndLive() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 104), [.call, .live])
    }

    func test_userType_105_blocksCallAndParty() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 105), [.call, .party])
    }

    func test_userType_106_blocksLiveAndParty() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 106), [.live, .party])
    }

    // MARK: - R-3: 未知 userType 视为不受限

    func test_userType_unknownValues_defaultToEmpty() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 200), [])
        XCTAssertEqual(UserPermissionMapping.blocked(for: 50), [])
        XCTAssertEqual(UserPermissionMapping.blocked(for: 0), [])
        XCTAssertEqual(UserPermissionMapping.blocked(for: 999), [])
        XCTAssertEqual(UserPermissionMapping.blocked(for: -1), [])
    }

    // MARK: - BlockedFeatures 位运算基础属性

    func test_blockedFeatures_containsSingleBit() {
        XCTAssertTrue(BlockedFeatures.call.contains(.call))
        XCTAssertFalse(BlockedFeatures.call.contains(.live))
        XCTAssertFalse(BlockedFeatures.call.contains(.party))
    }

    func test_blockedFeatures_combinationContainsIndividualBits() {
        let combo: BlockedFeatures = [.call, .live]
        XCTAssertTrue(combo.contains(.call))
        XCTAssertTrue(combo.contains(.live))
        XCTAssertFalse(combo.contains(.party))
    }
}
