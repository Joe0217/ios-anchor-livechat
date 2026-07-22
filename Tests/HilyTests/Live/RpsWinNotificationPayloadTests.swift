import XCTest

final class RpsWinNotificationPayloadTests: XCTestCase {

    func testGrantedHoursPrefersNumericStringOverMedalHours() {
        let payload = RpsWinNotificationPayload(
            data: ["nickname": "Mia", "grantedHours": "2", "medalHours": 8],
            fallbackNickname: "Fallback"
        )

        XCTAssertEqual(payload.nickname, "Mia")
        XCTAssertEqual(payload.medalHours, 2.0)
    }

    func testMedalHoursAcceptsNSNumberWhenGrantedHoursIsNull() {
        let payload = RpsWinNotificationPayload(
            data: ["grantedHours": NSNull(), "medalHours": NSNumber(value: 3)],
            fallbackNickname: "Winner"
        )

        XCTAssertEqual(payload.nickname, "Winner")
        XCTAssertEqual(payload.medalHours, 3.0)
    }

    func testInvalidGrantedHoursDoesNotFallBackToMedalHours() {
        let payload = RpsWinNotificationPayload(
            data: ["grantedHours": "not-a-number", "medalHours": 4],
            fallbackNickname: nil
        )

        XCTAssertNil(payload.medalHours)
    }

    func testBoolHoursAreIgnored() {
        let payload = RpsWinNotificationPayload(
            data: ["grantedHours": true],
            fallbackNickname: nil
        )

        XCTAssertNil(payload.medalHours)
    }

    func testFractionalHoursMatchH5NumberSemantics() {
        let fromString = RpsWinNotificationPayload(
            data: ["grantedHours": "2.5"],
            fallbackNickname: nil
        )
        let fromNumber = RpsWinNotificationPayload(
            data: ["grantedHours": NSNumber(value: 1.25)],
            fallbackNickname: nil
        )

        XCTAssertEqual(fromString.medalHours, 2.5)
        XCTAssertEqual(fromNumber.medalHours, 1.25)
    }
}
