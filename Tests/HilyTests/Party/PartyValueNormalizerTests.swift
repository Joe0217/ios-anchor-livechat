import XCTest

/// PartyValueNormalizer 跨通道（HTTP String / NIM Number）类型归一化单测。
///
/// 背景：派对房 `roomId / userId / seatIndex` 等关键标识在不同通道类型不一致：
/// - HTTP 响应（`room/list` `room/enter` `seat/list`）：**String**
/// - NIM payload（1003 / 1012 / 2049 等）：**Number**
/// `stringify` 归到 String 比较（最宽容；不丢 Int64 精度）；`intify` 归到 Int。
final class PartyValueNormalizerTests: XCTestCase {

    // MARK: - stringify

    func test_stringify_StringTrim_returnsTrimmedValue() {
        XCTAssertEqual(PartyValueNormalizer.stringify("  abc  "), "abc")
    }

    func test_stringify_Int_returnsDecimalString() {
        XCTAssertEqual(PartyValueNormalizer.stringify(123), "123")
    }

    func test_stringify_Int64_LargeNumber_noPrecisionLoss() {
        // 超过 2^53 的 Int64 经 Double 会丢精度；走 NSNumber.stringValue 才稳
        let big: Int64 = 9_007_199_254_740_993
        XCTAssertEqual(PartyValueNormalizer.stringify(big), "9007199254740993")
    }

    func test_stringify_DoubleInteger_stripsTrailingZero() {
        // 3.0 不应输出 "3.0"（拼 URL/对比时易错），实际期望 "3"
        XCTAssertEqual(PartyValueNormalizer.stringify(3.0), "3")
    }

    func test_stringify_DoubleFractional_preservesDecimal() {
        XCTAssertEqual(PartyValueNormalizer.stringify(1.5), "1.5")
    }

    func test_stringify_NSNumber_usesStringValue() {
        let n = NSNumber(value: 42)
        XCTAssertEqual(PartyValueNormalizer.stringify(n), "42")
    }

    func test_stringify_EmptyString_returnsNil() {
        XCTAssertNil(PartyValueNormalizer.stringify(""))
    }

    func test_stringify_WhitespaceOnlyString_returnsNil() {
        // trim 后空字符串视为无效
        XCTAssertNil(PartyValueNormalizer.stringify("   "))
    }

    func test_stringify_Nil_returnsNil() {
        XCTAssertNil(PartyValueNormalizer.stringify(nil))
    }

    // MARK: - intify

    func test_intify_Int_returnsSelf() {
        XCTAssertEqual(PartyValueNormalizer.intify(7), 7)
    }

    func test_intify_NSNumber_returnsIntValue() {
        XCTAssertEqual(PartyValueNormalizer.intify(NSNumber(value: 9)), 9)
    }

    func test_intify_DoubleFractional_truncatesToInt() {
        // 1.5 → 1（Int 截断；不四舍五入）
        XCTAssertEqual(PartyValueNormalizer.intify(1.9), 1)
    }

    func test_intify_NumericString_returnsParsedInt() {
        XCTAssertEqual(PartyValueNormalizer.intify("42"), 42)
    }

    func test_intify_NonNumericString_returnsNil() {
        XCTAssertNil(PartyValueNormalizer.intify("abc"))
    }

    func test_intify_Nil_returnsNil() {
        XCTAssertNil(PartyValueNormalizer.intify(nil))
    }
}
