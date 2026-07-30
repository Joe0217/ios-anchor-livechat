import XCTest

@MainActor
final class LotteryStoreTests: XCTestCase {
    func testRouteAcceptsTrustedPureLotteryURL() {
        let route = LotteryRoute(url: URL(string: "https://h5-activity-common.pages.dev/lottery?lotteryId=26")!)

        XCTAssertEqual(route?.activityID, "26")
    }

    func testRouteRejectsUntrustedAndCompositeActivityURLs() {
        XCTAssertNil(LotteryRoute(url: URL(string: "https://example.com/lottery?lotteryId=26")!))
        XCTAssertNil(LotteryRoute(url: URL(string: "https://h5-activity-common.pages.dev/lottery?lotteryId=26&taskId=9")!))
        XCTAssertNil(LotteryRoute(url: URL(string: "https://h5-activity-common.pages.dev/lottery?lotteryId=26%2526taskId%3D9")!))
        XCTAssertNil(LotteryRoute(url: URL(string: "https://h5-activity-common.pages.dev/lottery?lotteryId=26#/legacy")!))
        XCTAssertNil(LotteryRoute(url: URL(string: "https://user@h5-activity-common.pages.dev/lottery?lotteryId=26")!))
    }

    func testRouteAcceptsEncodedCompoundPureLotteryID() {
        let route = LotteryRoute(url: URL(string: "https://h5-activity-common.pages.dev/lottery?lotteryId=26%2526source%3Dbanner")!)

        XCTAssertEqual(route?.activityID, "26")
    }

    func testDrawAlwaysUsesEmptyRoomContext() async {
        let service = FakeLotteryService(activity: activity(prizeCount: 8))
        service.drawResult = [.success([prize(id: "8", type: 1, quantity: 9)])]
        let store = LotteryStore(route: route(), service: service)

        await store.loadIfNeeded()
        store.startDraw(.one)
        await wait(seconds: 5.2)

        XCTAssertEqual(service.drawCalls.count, 1)
        XCTAssertEqual(service.drawCalls.first?.activityID, "26")
        XCTAssertEqual(service.drawCalls.first?.mode, .one)
        XCTAssertEqual(service.drawCalls.first?.sourceURL, route().sourceURL)
        XCTAssertEqual(store.remainingTimes, 2)
        XCTAssertTrue(store.isResultPresented)
    }

    func testDrawWithAnotherChanceRestoresOnlyAfterResultDismissal() async {
        let service = FakeLotteryService(activity: activity(prizeCount: 8, userTimes: 3))
        service.drawResult = [.success([prize(id: "8", type: 6)])]
        let store = LotteryStore(route: route(), service: service)

        await store.loadIfNeeded()
        store.startDraw(.one)
        await wait(seconds: 5.2)

        XCTAssertEqual(store.remainingTimes, 2)
        XCTAssertTrue(store.isResultPresented)
        store.dismissResult()
        XCTAssertEqual(store.remainingTimes, 3)
        XCTAssertEqual(store.state, .ready)
    }

    func testFiveDrawRequiresFiveChancesBeforeSubmitting() async {
        let service = FakeLotteryService(activity: activity(prizeCount: 8, userTimes: 4))
        let store = LotteryStore(route: route(), service: service)

        await store.loadIfNeeded()
        store.startDraw(.five)
        await wait(seconds: 0.05)

        XCTAssertTrue(service.drawCalls.isEmpty)
        XCTAssertEqual(store.remainingTimes, 4)
    }

    func testInsufficientChancesPresentsGuidanceWithOriginalEntry() async {
        let service = FakeLotteryService(activity: activity(prizeCount: 8, userTimes: 0))
        let store = LotteryStore(route: route(), service: service)

        await store.loadIfNeeded()
        store.startDraw(.one, entry: .center)

        XCTAssertTrue(store.isInsufficientPresented)
        XCTAssertEqual(store.insufficientEntry, .center)
        XCTAssertTrue(service.drawCalls.isEmpty)
    }

    func testInsufficientGuidanceRequestsRoomIDWithoutPartyJoinDependency() async {
        let service = FakeLotteryService(activity: activity(prizeCount: 8, userTimes: 0))
        service.roomIDResults = [.success("10086")]
        let store = LotteryStore(route: route(), service: service)

        await store.loadIfNeeded()
        store.startDraw(.one)
        let roomID = await store.requestRoomID(for: .party)

        XCTAssertEqual(roomID, "10086")
        XCTAssertEqual(service.roomTargets, [.party])
        XCTAssertTrue(store.isInsufficientPresented)
        XCTAssertNil(store.roomNavigationTarget)
    }

    func testPersistentMoreChancesGuidanceDoesNotRequireInsufficientPopup() async {
        let service = FakeLotteryService(activity: activity(prizeCount: 8, userTimes: 3))
        service.roomIDResults = [.success("10087")]
        let store = LotteryStore(route: route(), service: service)

        await store.loadIfNeeded()
        let roomID = await store.requestRoomID(for: .live, requiresInsufficientPopup: false)

        XCTAssertEqual(roomID, "10087")
        XCTAssertEqual(service.roomTargets, [.live])
        XCTAssertNil(store.roomNavigationTarget)
    }

    func testDismissedInsufficientPopupInvalidatesInFlightRoomNavigation() async {
        let deferredRoomID = DeferredRoomID()
        let service = FakeLotteryService(activity: activity(prizeCount: 8, userTimes: 0))
        service.roomIDHandler = { _ in
            try await deferredRoomID.fetch()
        }
        let store = LotteryStore(route: route(), service: service)

        await store.loadIfNeeded()
        store.startDraw(.one)
        let navigation = Task { @MainActor in
            await store.requestRoomID(for: .party)
        }
        await deferredRoomID.waitUntilRequested()

        store.dismissInsufficientPopup()
        deferredRoomID.resolve("10086")

        let result = await navigation.value
        XCTAssertNil(result)
        XCTAssertNil(store.roomNavigationTarget)
    }

    func testGiftStatSceneFiltersGuidanceTargets() {
        let empty = LotteryInsufficientRoomTargets(giftStatScene: "")
        XCTAssertTrue(empty.showsLive)
        XCTAssertTrue(empty.showsParty)

        let live = LotteryInsufficientRoomTargets(giftStatScene: "LIVE,PRIVATE_CALL")
        XCTAssertTrue(live.showsLive)
        XCTAssertFalse(live.showsParty)

        let party = LotteryInsufficientRoomTargets(giftStatScene: "PARTY_GIFT")
        XCTAssertFalse(party.showsLive)
        XCTAssertTrue(party.showsParty)
        XCTAssertTrue(party.isPartyOnly)

        let both = LotteryInsufficientRoomTargets(giftStatScene: "PARTY_GIFT,LIVE_VIDEO")
        XCTAssertTrue(both.showsLive)
        XCTAssertTrue(both.showsParty)

        let unknown = LotteryInsufficientRoomTargets(giftStatScene: "UNKNOWN")
        XCTAssertFalse(unknown.showsLive)
        XCTAssertFalse(unknown.showsParty)
    }

    func testDailyLimitProgressFillsTrack() {
        let progress = LotteryPointProgress(
            singleLotteryPoints: 100,
            currentPoints: 12,
            pointsToNext: 88,
            dailyChanceLimit: 2,
            dailyChanceUsed: 2,
            dailyChanceReached: true,
            sourceTextKey: "live_private"
        )

        XCTAssertEqual(progress.ratio, 1)
    }

    func testRoomIDPayloadAcceptsStringAndNumberResponses() throws {
        let stringPayload = try JSONDecoder().decode(
            LotteryRoomIDPayload.self,
            from: Data(#"{"roomId":"10086"}"#.utf8)
        )
        let numberPayload = try JSONDecoder().decode(
            LotteryRoomIDPayload.self,
            from: Data(#"{"roomId":10087}"#.utf8)
        )

        XCTAssertEqual(stringPayload.roomID, "10086")
        XCTAssertEqual(numberPayload.roomID, "10087")
    }

    func testCustomInsufficientPopupConsumesServerActions() throws {
        let configuration = try JSONDecoder().decode(
            LotteryPopupConfiguration.self,
            from: Data(
                #"""
                {
                  "popupType": 2,
                  "bgImage": "https://img.example.com/popup.png",
                  "buttons": [
                    {"key":"party","label":"Party","action":"GO_PARTY_ROOM","image":"https://img.example.com/party.png"},
                    {"key":"live","label":"Live","action":"GO_LIVE_ROOM","image":"https://img.example.com/live.png"},
                    {"key":"close","label":"","action":"CLOSE","image":""}
                  ]
                }
                """#.utf8
            )
        )

        XCTAssertTrue(configuration.usesCustomLayout)
        XCTAssertEqual(configuration.buttons.map(\.popupAction), [.goPartyRoom, .goLiveRoom, .close])
    }

    func testFailedDrawRefreshesActivityWithoutAutomaticRetry() async {
        let service = FakeLotteryService(activity: activity(prizeCount: 8, userTimes: 3))
        service.drawResult = [.failure(TestError.offline)]
        service.activityResults = [
            .success(activity(prizeCount: 8, userTimes: 3)),
            .success(activity(prizeCount: 8, userTimes: 2))
        ]
        let store = LotteryStore(route: route(), service: service)

        await store.loadIfNeeded()
        store.startDraw(.one)
        await wait(seconds: 0.15)

        XCTAssertEqual(service.drawCalls.count, 1)
        XCTAssertEqual(service.fetchActivityCallCount, 2)
        XCTAssertEqual(store.remainingTimes, 2)
        XCTAssertEqual(store.state, .ready)
    }

    func testUnsupportedPrizeCountDisablesDraw() async {
        let service = FakeLotteryService(activity: activity(prizeCount: 10))
        let store = LotteryStore(route: route(), service: service)

        await store.loadIfNeeded()
        store.startDraw(.one)

        XCTAssertEqual(store.state, .unsupportedPrizeLayout)
        XCTAssertTrue(service.drawCalls.isEmpty)
    }

    private func route() -> LotteryRoute {
        LotteryRoute(url: URL(string: "https://h5-activity-common.pages.dev/lottery?lotteryId=26")!)!
    }

    private func activity(prizeCount: Int, userTimes: Int = 3) -> LotteryActivity {
        let prizes = (1...prizeCount).map { index in
            prize(id: "\(index)", type: index == 1 ? 1 : 5, quantity: index)
        }
        return LotteryActivity(
            info: LotteryActivityInfo(
                name: "Lucky Draw",
                lotteryStatus: 1,
                giftStatScene: "LIVE",
                startTime: "2020-01-01T00:00:00Z",
                endTime: "2099-01-01T00:00:00Z"
            ),
            prizes: prizes,
            assets: LotteryAssets(images: []),
            userTotalTimes: userTimes,
            pointProgress: .empty,
            popupConfiguration: nil
        )
    }

    private func prize(id: String, type: Int, quantity: Int = 0) -> LotteryPrize {
        let json = """
        {"id":"\(id)","iconImage":"","prizeName":"Prize \(id)","prizeType":\(type),"validDays":0,"quantity":\(quantity)}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(LotteryPrize.self, from: json)
    }

    private func wait(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

@MainActor
private final class FakeLotteryService: LotteryServicing {
    struct DrawCall: Equatable {
        let activityID: String
        let mode: LotteryDrawMode
        let sourceURL: String
    }

    var activityResults: [Result<LotteryActivity, Error>]
    var drawResult: [Result<[LotteryPrize], Error>] = [.success([])]
    var roomIDResults: [Result<String?, Error>] = [.success(nil)]
    var roomIDHandler: ((LotteryRoomTarget) async throws -> String?)?
    var winners: [LotteryRewardRecord] = []
    private(set) var fetchActivityCallCount = 0
    private(set) var drawCalls: [DrawCall] = []
    private(set) var roomTargets: [LotteryRoomTarget] = []

    init(activity: LotteryActivity) {
        activityResults = [.success(activity)]
    }

    func fetchActivity(activityID: String) async throws -> LotteryActivity {
        fetchActivityCallCount += 1
        let index = min(fetchActivityCallCount - 1, activityResults.count - 1)
        return try activityResults[index].get()
    }

    func draw(activityID: String, mode: LotteryDrawMode, sourceURL: String) async throws -> [LotteryPrize] {
        drawCalls.append(DrawCall(activityID: activityID, mode: mode, sourceURL: sourceURL))
        let index = min(drawCalls.count - 1, drawResult.count - 1)
        return try drawResult[index].get()
    }

    func fetchRecords(activityID: String, page: Int, pageSize: Int) async throws -> LotteryRecordPage {
        LotteryRecordPage(records: [], remainingTimes: nil)
    }

    func fetchWinners(activityID: String) async throws -> [LotteryRewardRecord] {
        winners
    }

    func fetchRoomID(for target: LotteryRoomTarget) async throws -> String? {
        roomTargets.append(target)
        if let roomIDHandler {
            return try await roomIDHandler(target)
        }
        let index = min(roomTargets.count - 1, roomIDResults.count - 1)
        return try roomIDResults[index].get()
    }
}

@MainActor
private final class DeferredRoomID {
    private var continuation: CheckedContinuation<String?, Error>?

    func fetch() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resolve(_ roomID: String?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: roomID)
    }
}
