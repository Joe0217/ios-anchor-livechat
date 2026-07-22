import XCTest

final class PartyBattleTypesTests: XCTestCase {

    func testStatusRawValues() {
        XCTAssertEqual(PartyBattleStatus.selecting.rawValue, 1)
        XCTAssertEqual(PartyBattleStatus.running.rawValue, 2)
        XCTAssertEqual(PartyBattleStatus.ended.rawValue, 3)
        XCTAssertEqual(PartyBattleStatus.forceEnded.rawValue, 4)
        XCTAssertEqual(PartyBattleStatus.cooldown.rawValue, 5)
    }

    func testDoubleOrStringDecodeDouble() throws {
        let json = "12.5".data(using: .utf8)!
        let v = try JSONDecoder().decode(DoubleOrString.self, from: json)
        XCTAssertEqual(v.doubleValue, 12.5)
    }

    func testDoubleOrStringDecodeInt64() throws {
        let json = "1234567890123456".data(using: .utf8)!
        let v = try JSONDecoder().decode(DoubleOrString.self, from: json)
        XCTAssertEqual(v.doubleValue, 1234567890123456.0)
    }

    func testDoubleOrStringDecodeString() throws {
        let json = "\"999999.99\"".data(using: .utf8)!
        let v = try JSONDecoder().decode(DoubleOrString.self, from: json)
        XCTAssertEqual(v.doubleValue, 999999.99)
    }

    func testDoubleOrStringDecodeEmptyString() throws {
        let json = "\"\"".data(using: .utf8)!
        let v = try JSONDecoder().decode(DoubleOrString.self, from: json)
        XCTAssertEqual(v.doubleValue, 0)
    }

    func testDoubleOrStringEncodeRoundTrip() throws {
        let orig = DoubleOrString.double(12.5)
        let encoded = try JSONEncoder().encode(orig)
        let decoded = try JSONDecoder().decode(DoubleOrString.self, from: encoded)
        XCTAssertEqual(decoded.doubleValue, 12.5)
    }
}
