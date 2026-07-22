import XCTest

@MainActor
final class PaidBulletQueueTests: XCTestCase {

    private let context = PaidBulletQueue.Context(roomId: 100, viewerUserId: 7, countryCode: "us")

    func test_roomScope_requiresCurrentBusinessRoom_and_deduplicatesBillId() {
        let queue = PaidBulletQueue(service: FakePaidBulletService())

        XCTAssertEqual(queue.receive(payload: payload(billId: "other", scope: 1, roomId: 99), context: context), .ignored)

        let result = queue.receive(payload: payload(billId: "room-1", scope: 1, roomId: "100"), context: context)
        guard case let .enqueued(item, _) = result else {
            return XCTFail("expected room bullet to enqueue")
        }
        XCTAssertEqual(item.senderNickname, "Ava")
        XCTAssertEqual(item.stayDuration, 5)
        XCTAssertEqual(queue.current?.billId, "room-1")

        XCTAssertEqual(queue.receive(payload: payload(billId: "room-1", scope: 1, roomId: 100), context: context), .ignored)
    }

    func test_countryScope_normalizesCountryCode_and_globalDoesNotNeedTargets() {
        let queue = PaidBulletQueue(service: FakePaidBulletService())

        XCTAssertTrue(queue.receive(payload: payload(billId: "country-hit", scope: 2, targetCountryCodes: ["GB", "US"]), context: context).isEnqueued)
        XCTAssertEqual(queue.receive(payload: payload(billId: "country-miss", scope: 2, targetCountryCodes: ["GB"]), context: context), .ignored)
        XCTAssertTrue(queue.receive(payload: payload(billId: "global", scope: 3, targetCountryCodes: []), context: context).isEnqueued)
    }

    func test_nextBulletStartsOnlyAfterViewCompletesPreviousPlayback() {
        let queue = PaidBulletQueue(service: FakePaidBulletService())
        guard case let .enqueued(first, _) = queue.receive(
            payload: payload(billId: "first", scope: 3),
            context: context
        ) else {
            return XCTFail("expected first bullet to enqueue")
        }
        XCTAssertTrue(queue.receive(payload: payload(billId: "second", scope: 3), context: context).isEnqueued)
        XCTAssertEqual(queue.current?.billId, "first")

        queue.completePlayback(of: first)

        XCTAssertEqual(queue.current?.billId, "second")
    }

    func test_showDuration_matchesH5FallbackAndDecimalSemantics() {
        XCTAssertEqual(receivedDuration(for: 0), 5)
        XCTAssertEqual(receivedDuration(for: "0"), 5)
        XCTAssertEqual(receivedDuration(for: 2.5), 2.5)
        XCTAssertEqual(receivedDuration(for: "2.5"), 2.5)
        XCTAssertEqual(receivedDuration(for: -3), 1)
        XCTAssertEqual(receivedDuration(for: "invalid"), 5)
    }

    func test_dislike_isHostOnly_and_rollsBackOnFailure() async {
        let service = FakePaidBulletService()
        service.error = PaidBulletTestError.failed
        let queue = PaidBulletQueue(service: service)
        guard case let .enqueued(item, _) = queue.receive(
            payload: payload(billId: "bill-1", scope: 3, hostUserId: 7),
            context: context
        ) else {
            return XCTFail("expected bullet to enqueue")
        }

        XCTAssertTrue(queue.canDislike(item))
        do {
            try await queue.dislike(item)
            XCTFail("expected failure")
        } catch {
            XCTAssertFalse(queue.isDisliked(item))
        }

        service.error = nil
        try? await queue.dislike(item)
        XCTAssertTrue(queue.isDisliked(item))
        XCTAssertEqual(service.billIds, ["bill-1", "bill-1"])
    }

    func test_dislike_isHiddenForAnotherHost() async {
        let service = FakePaidBulletService()
        let queue = PaidBulletQueue(service: service)
        guard case let .enqueued(item, _) = queue.receive(
            payload: payload(billId: "bill-2", scope: 3, hostUserId: 8),
            context: context
        ) else {
            return XCTFail("expected bullet to enqueue")
        }

        XCTAssertFalse(queue.canDislike(item))
        try? await queue.dislike(item)
        XCTAssertTrue(service.billIds.isEmpty)
    }

    private func payload(
        billId: String,
        scope: Int,
        roomId: Any = 100,
        hostUserId: Any = 7,
        targetCountryCodes: [String] = []
    ) -> [String: Any] {
        [
            "billId": billId,
            "bulletScope": scope,
            "content": "Hello",
            "showDuration": "5",
            "senderUserId": "42",
            "senderNick": "Ava",
            "senderAvatar": "https://example.com/avatar.png",
            "roomId": roomId,
            "hostUserId": hostUserId,
            "targetCountryCodes": targetCountryCodes,
        ]
    }

    private func receivedDuration(for showDuration: Any) -> TimeInterval? {
        let queue = PaidBulletQueue(service: FakePaidBulletService())
        var raw = payload(billId: UUID().uuidString, scope: 3)
        raw["showDuration"] = showDuration
        guard case let .enqueued(item, _) = queue.receive(payload: raw, context: context) else {
            return nil
        }
        return item.stayDuration
    }
}

private extension PaidBulletQueue.ReceiveResult {
    var isEnqueued: Bool {
        if case .enqueued = self { return true }
        return false
    }
}

private enum PaidBulletTestError: Error {
    case failed
}

private final class FakePaidBulletService: PaidBulletService, @unchecked Sendable {
    var error: Error?
    private(set) var billIds: [String] = []

    func dislike(billId: String) async throws -> PaidBulletDislikeResponse {
        billIds.append(billId)
        if let error { throw error }
        return PaidBulletDislikeResponse(dislikeCount: 1, muted: false)
    }
}
