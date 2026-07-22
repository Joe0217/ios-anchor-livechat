import XCTest

final class AudienceLiveRoomModelsTests: XCTestCase {

    func testLiveJoinUsesNestedRoomIdentifiersAndCurrentRTCtoken() {
        let info = AudienceLiveRoomInfo(
            anchor: anchor(),
            response: [
                "liveRoomState": 2,
                "nickname": "Anchor A",
                "agoraLiveSimpleVO": [
                    "id": "42",
                    "userId": "1001",
                    "yxRoomId": "2002",
                    "agoraChannelId": "live-channel",
                    "hotScore": "88",
                    "pkStatus": "7",
                    "countryId": "US",
                ],
            ],
            rtcToken: "fresh-token"
        )

        XCTAssertEqual(info?.availability, .live)
        XCTAssertEqual(info?.liveRecordId, 42)
        XCTAssertEqual(info?.anchorUserId, 1001)
        XCTAssertEqual(info?.yxRoomId, 2002)
        XCTAssertEqual(info?.agoraChannelId, "live-channel")
        XCTAssertEqual(info?.rtcToken, "fresh-token")
        XCTAssertEqual(info?.initialPKStatus, 7)
        XCTAssertEqual(info?.anchorCountryCode, "US")
    }

    func testEndedRoomDoesNotRequireMediaFields() {
        let info = AudienceLiveRoomInfo(
            anchor: anchor(),
            response: ["liveRoomState": 1, "userId": 1001],
            rtcToken: nil
        )

        XCTAssertEqual(info?.availability, .ended)
        XCTAssertEqual(info?.agoraChannelId, "")
    }

    private func anchor() -> LiveStreamAnchor {
        LiveStreamAnchor(
            userId: "1001",
            nickname: "Fallback",
            icon: nil,
            backgroundImgUrl: nil,
            joinNum: "0",
            weekIncome: nil,
            pkStatus: nil,
            diamondGiftActive: nil
        )
    }
}
