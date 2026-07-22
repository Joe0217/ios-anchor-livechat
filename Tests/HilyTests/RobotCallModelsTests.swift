import XCTest

final class RobotCallModelsTests: XCTestCase {
    func test_invite_requiresPlayableVideoAndNormalizesTypes() {
        let invite = RobotCallInvite(payload: [
            "id": 12,
            "recordId": "record-1",
            "fileUrl": "https://cdn.example.com/video.mp4",
            "autoHangupTime": 0,
            "userId": 32
        ])

        XCTAssertEqual(invite?.videoId, "12")
        XCTAssertEqual(invite?.recordId, "record-1")
        XCTAssertEqual(invite?.autoHangupSeconds, 1)
        XCTAssertEqual(invite?.displayUserId, "32")
    }

    func test_invite_missingVideoURL_isRejected() {
        XCTAssertNil(RobotCallInvite(payload: ["id": 12, "recordId": "record-1"]))
    }

    func test_invite_nonHTTPSVideoURL_isRejected() {
        XCTAssertNil(RobotCallInvite(payload: [
            "id": 12,
            "recordId": "record-1",
            "fileUrl": "file:///private/video.mp4"
        ]))
        XCTAssertNil(RobotCallInvite(payload: [
            "id": 12,
            "recordId": "record-1",
            "fileUrl": "http://cdn.example.com/video.mp4"
        ]))
    }

    func test_invite_usesNIMTimestampToRejectStaleAndFarFutureNotifications() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let current = RobotCallInvite(payload: [
            "id": 12,
            "recordId": "record-1",
            "fileUrl": "https://cdn.example.com/video.mp4",
            "_nimCustomNotificationTimestamp": 1_700_000_080
        ])
        let stale = RobotCallInvite(payload: [
            "id": 12,
            "recordId": "record-2",
            "fileUrl": "https://cdn.example.com/video.mp4",
            "_nimCustomNotificationTimestamp": 1_700_000_000_000
        ])
        let future = RobotCallInvite(payload: [
            "id": 12,
            "recordId": "record-3",
            "fileUrl": "https://cdn.example.com/video.mp4",
            "_nimCustomNotificationTimestamp": 1_700_000_200
        ])

        XCTAssertTrue(current?.isFresh(now: now, maximumAge: 35, maximumFutureSkew: 60) == true)
        XCTAssertFalse(stale?.isFresh(now: now, maximumAge: 35, maximumFutureSkew: 60) == true)
        XCTAssertFalse(future?.isFresh(now: now, maximumAge: 35, maximumFutureSkew: 60) == true)
    }

    func test_admission_blocksOtherCallsDuringRobotCallOrVisibleReward() {
        XCTAssertTrue(RobotCallAdmission.blocksOtherCalls(state: .ringing, hasVisibleReward: false))
        XCTAssertTrue(RobotCallAdmission.blocksOtherCalls(state: .connected, hasVisibleReward: false))
        XCTAssertTrue(RobotCallAdmission.blocksOtherCalls(state: .idle, hasVisibleReward: true))
        XCTAssertFalse(RobotCallAdmission.blocksOtherCalls(state: .idle, hasVisibleReward: false))
    }

    func test_reward_preservesDecimalTextAndParsesEligibility() {
        let reward = RobotCallReward(payload: [
            "recordId": 88,
            "type": true,
            "content": "18.5",
            "callTime": 125
        ])

        XCTAssertEqual(reward?.recordId, "88")
        XCTAssertTrue(reward?.isEligible == true)
        XCTAssertEqual(reward?.diamondText, "18.5")
        XCTAssertEqual(reward?.callDurationSeconds, 125)
    }
}
