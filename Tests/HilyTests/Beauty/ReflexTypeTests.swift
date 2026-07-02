import XCTest

/// K spec §5.2 R3：ReflexType 3 类映射双向 + round-trip 精度 = 30 case。
///
/// 覆盖：
/// - type1 (0~100 ↔ 0~1)：0/50/100/-10 越界/110 越界 → 5 case × 2 方向 = 10
/// - type2 (-50~50 ↔ 0~1)：-50/0/50/-60 越界/60 越界 → 5 case × 2 方向 = 10
/// - type3 (0~100 ↔ 0~6)：0/50/100/-10/110 → 5 case × 2 方向 = 10
final class ReflexTypeTests: XCTestCase {

    // MARK: - type1: UI 0~100 ↔ SDK 0~1
    func testType1_toRaw_zero() { XCTAssertEqual(ReflexType.type1.toRaw(0), 0.0, accuracy: 1e-9) }
    func testType1_toRaw_mid() { XCTAssertEqual(ReflexType.type1.toRaw(50), 0.5, accuracy: 1e-9) }
    func testType1_toRaw_max() { XCTAssertEqual(ReflexType.type1.toRaw(100), 1.0, accuracy: 1e-9) }
    func testType1_toRaw_belowMin() { XCTAssertEqual(ReflexType.type1.toRaw(-10), -0.1, accuracy: 1e-9) }
    func testType1_toRaw_aboveMax() { XCTAssertEqual(ReflexType.type1.toRaw(110), 1.1, accuracy: 1e-9) }
    func testType1_toUI_zero() { XCTAssertEqual(ReflexType.type1.toUI(0.0), 0.0, accuracy: 1e-9) }
    func testType1_toUI_mid() { XCTAssertEqual(ReflexType.type1.toUI(0.5), 50.0, accuracy: 1e-9) }
    func testType1_toUI_max() { XCTAssertEqual(ReflexType.type1.toUI(1.0), 100.0, accuracy: 1e-9) }
    func testType1_toUI_belowMin() { XCTAssertEqual(ReflexType.type1.toUI(-0.1), -10.0, accuracy: 1e-9) }
    func testType1_toUI_aboveMax() { XCTAssertEqual(ReflexType.type1.toUI(1.1), 110.0, accuracy: 1e-9) }

    // MARK: - type2: UI -50~50 ↔ SDK 0~1（UI=0 → raw=0.5 中性形变）
    func testType2_toRaw_min() { XCTAssertEqual(ReflexType.type2.toRaw(-50), 0.0, accuracy: 1e-9) }
    func testType2_toRaw_zero() { XCTAssertEqual(ReflexType.type2.toRaw(0), 0.5, accuracy: 1e-9) }
    func testType2_toRaw_max() { XCTAssertEqual(ReflexType.type2.toRaw(50), 1.0, accuracy: 1e-9) }
    func testType2_toRaw_belowMin() { XCTAssertEqual(ReflexType.type2.toRaw(-60), -0.1, accuracy: 1e-9) }
    func testType2_toRaw_aboveMax() { XCTAssertEqual(ReflexType.type2.toRaw(60), 1.1, accuracy: 1e-9) }
    func testType2_toUI_min() { XCTAssertEqual(ReflexType.type2.toUI(0.0), -50.0, accuracy: 1e-9) }
    func testType2_toUI_zero() { XCTAssertEqual(ReflexType.type2.toUI(0.5), 0.0, accuracy: 1e-9) }
    func testType2_toUI_max() { XCTAssertEqual(ReflexType.type2.toUI(1.0), 50.0, accuracy: 1e-9) }
    func testType2_toUI_belowMin() { XCTAssertEqual(ReflexType.type2.toUI(-0.1), -60.0, accuracy: 1e-9) }
    func testType2_toUI_aboveMax() { XCTAssertEqual(ReflexType.type2.toUI(1.1), 60.0, accuracy: 1e-9) }

    // MARK: - type3: UI 0~100 ↔ SDK 0~6（磨皮专用）
    func testType3_toRaw_zero() { XCTAssertEqual(ReflexType.type3.toRaw(0), 0.0, accuracy: 1e-9) }
    func testType3_toRaw_mid() { XCTAssertEqual(ReflexType.type3.toRaw(50), 3.0, accuracy: 1e-9) }
    func testType3_toRaw_max() { XCTAssertEqual(ReflexType.type3.toRaw(100), 6.0, accuracy: 1e-9) }
    func testType3_toRaw_belowMin() { XCTAssertEqual(ReflexType.type3.toRaw(-10), -0.6, accuracy: 1e-9) }
    func testType3_toRaw_aboveMax() { XCTAssertEqual(ReflexType.type3.toRaw(110), 6.6, accuracy: 1e-9) }
    func testType3_toUI_zero() { XCTAssertEqual(ReflexType.type3.toUI(0.0), 0.0, accuracy: 1e-9) }
    func testType3_toUI_mid() { XCTAssertEqual(ReflexType.type3.toUI(3.0), 50.0, accuracy: 1e-9) }
    func testType3_toUI_max() { XCTAssertEqual(ReflexType.type3.toUI(6.0), 100.0, accuracy: 1e-9) }
    func testType3_toUI_belowMin() { XCTAssertEqual(ReflexType.type3.toUI(-0.6), -10.0, accuracy: 1e-9) }
    func testType3_toUI_aboveMax() { XCTAssertEqual(ReflexType.type3.toUI(6.6), 110.0, accuracy: 1e-9) }

    // MARK: - Round-trip 精度（U → raw → U 一致）
    func testRoundTrip_type1_multiValues() {
        for v in stride(from: 0.0, through: 100.0, by: 12.5) {
            XCTAssertEqual(ReflexType.type1.toUI(ReflexType.type1.toRaw(v)), v, accuracy: 1e-9)
        }
    }

    func testRoundTrip_type2_multiValues() {
        for v in stride(from: -50.0, through: 50.0, by: 12.5) {
            XCTAssertEqual(ReflexType.type2.toUI(ReflexType.type2.toRaw(v)), v, accuracy: 1e-9)
        }
    }

    func testRoundTrip_type3_multiValues() {
        for v in stride(from: 0.0, through: 100.0, by: 12.5) {
            XCTAssertEqual(ReflexType.type3.toUI(ReflexType.type3.toRaw(v)), v, accuracy: 1e-9)
        }
    }

    // MARK: - R19 首帧契约：美白 UI initValue=40 → raw=0.4（红队 F2）
    func testWhiten_firstFrameContract() {
        // v2 spec §2.4 D7：删除 rawInitValue=0.2 独立路径，一律走 UI initValue
        XCTAssertEqual(ReflexType.type1.toRaw(40), 0.4, accuracy: 1e-9)
    }

    // MARK: - CaseIterable 完备性
    func testAllCases() {
        XCTAssertEqual(ReflexType.allCases.count, 3)
        XCTAssertEqual(Set(ReflexType.allCases.map(\.rawValue)), [1, 2, 3])
    }
}
