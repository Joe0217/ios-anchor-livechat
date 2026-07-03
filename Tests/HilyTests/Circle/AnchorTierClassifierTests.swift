import XCTest

/// trial #1 (A-spec §6A.5) — S 级白名单单测。
///
/// 验证 H5 `.contains("S")` 历史坑被白名单严格收紧。
final class AnchorTierClassifierTests: XCTestCase {

    // MARK: - 白名单命中 (S 级)

    func test_isSLevel_S_returnsTrue() {
        XCTAssertTrue(AnchorTierClassifier.isSLevel(levelName: "S"))
    }

    func test_isSLevel_SS_returnsTrue() {
        XCTAssertTrue(AnchorTierClassifier.isSLevel(levelName: "SS"))
    }

    // MARK: - 非 S 级段位 (白名单未命中)

    func test_isSLevel_A_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: "A"))
    }

    func test_isSLevel_B_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: "B"))
    }

    func test_isSLevel_C_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: "C"))
    }

    func test_isSLevel_D_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: "D"))
    }

    func test_isSLevel_NEW_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: "NEW"))
    }

    // MARK: - 白名单收紧关键点：未来段位不被误判 (vs H5 `.contains("S")`)

    func test_isSLevel_STAR_returnsFalse_unlikeH5Contains() {
        // H5 `'STAR'.includes('S') == true`，iOS 白名单严格收紧后应返回 false
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: "STAR"))
    }

    func test_isSLevel_SPECIAL_returnsFalse_unlikeH5Contains() {
        // 同上：'SPECIAL'.includes('S') == true，白名单收紧后应 false
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: "SPECIAL"))
    }

    // MARK: - 边界

    func test_isSLevel_nil_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: nil))
    }

    func test_isSLevel_empty_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: ""))
    }

    func test_isSLevel_lowercaseS_returnsFalse() {
        // 后端约定大写，小写不命中
        XCTAssertFalse(AnchorTierClassifier.isSLevel(levelName: "s"))
    }

    // MARK: - isSLevel(level:) overload (trial step 3 反悔补充)

    /// 后端只发数字 level 不发 levelName 的兜底路径。
    /// 复用 `AnchorInfoStore.tierName(forLevel:)` 映射：["D","C","NEW","B","A","S","SS"]
    /// index 5 = S, 6 = SS

    func test_isSLevel_level5_isS_returnsTrue() {
        XCTAssertTrue(AnchorTierClassifier.isSLevel(level: 5))
    }

    func test_isSLevel_level6_isSS_returnsTrue() {
        XCTAssertTrue(AnchorTierClassifier.isSLevel(level: 6))
    }

    func test_isSLevel_level4_isA_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(level: 4))
    }

    func test_isSLevel_level0_isD_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(level: 0))
    }

    func test_isSLevel_levelNil_returnsFalse() {
        XCTAssertFalse(AnchorTierClassifier.isSLevel(level: nil))
    }

    func test_isSLevel_levelOutOfRange_returnsFalse() {
        // 越界（>=7 或 <0）应返 false，不抛错
        XCTAssertFalse(AnchorTierClassifier.isSLevel(level: 7))
        XCTAssertFalse(AnchorTierClassifier.isSLevel(level: -1))
        XCTAssertFalse(AnchorTierClassifier.isSLevel(level: 99))
    }
}
