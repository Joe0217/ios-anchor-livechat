import XCTest

final class PartyBattleGlobalConfigParserTests: XCTestCase {

    func testParseJavaMapStyle() {
        let raw = "{totalSwitch=1, cooldownDurationSec=60}"
        let parsed = PartyBattleGlobalConfigParser.parse(raw)
        XCTAssertEqual(parsed?.totalSwitch, 1)
        XCTAssertEqual(parsed?.cooldownDurationSec, 60)
    }

    func testParseEmptyReturnsNil() {
        XCTAssertNil(PartyBattleGlobalConfigParser.parse(""))
    }

    func testParseInvalidGarbageReturnsNil() {
        XCTAssertNil(PartyBattleGlobalConfigParser.parse("garbage"))
    }

    func testParseNoBracesReturnsNil() {
        XCTAssertNil(PartyBattleGlobalConfigParser.parse("totalSwitch=1"))
    }

    func testParseMissingTotalSwitchReturnsNil() {
        // totalSwitch 是必填字段，缺失返回 nil
        XCTAssertNil(PartyBattleGlobalConfigParser.parse("{cooldownDurationSec=60}"))
    }

    func testParseMissingCooldownIsNil() {
        // cooldownDurationSec 是可选
        let raw = "{totalSwitch=0}"
        let parsed = PartyBattleGlobalConfigParser.parse(raw)
        XCTAssertEqual(parsed?.totalSwitch, 0)
        XCTAssertNil(parsed?.cooldownDurationSec)
    }

    func testParseWithExtraSpaces() {
        let raw = "  {  totalSwitch = 1 ,  cooldownDurationSec = 60  }  "
        let parsed = PartyBattleGlobalConfigParser.parse(raw)
        XCTAssertEqual(parsed?.totalSwitch, 1)
        XCTAssertEqual(parsed?.cooldownDurationSec, 60)
    }

    func testParseSwitchOff() {
        let raw = "{totalSwitch=0, cooldownDurationSec=60}"
        let parsed = PartyBattleGlobalConfigParser.parse(raw)
        XCTAssertEqual(parsed?.totalSwitch, 0)
    }

    func testParseWithUnknownExtraKeysIgnored() {
        let raw = "{totalSwitch=1, cooldownDurationSec=60, futureFlag=x}"
        let parsed = PartyBattleGlobalConfigParser.parse(raw)
        XCTAssertEqual(parsed?.totalSwitch, 1)
        XCTAssertEqual(parsed?.cooldownDurationSec, 60)
    }
}
