import XCTest

@MainActor
final class WishlistStoreTests: XCTestCase {

    func testProgressReceivedBeforeInitialLoadIsAppliedToLoadedWishlist() async {
        let store = WishlistStore(service: WishlistFakeService(items: [wish(id: "gift-2", target: 5)]))

        XCTAssertFalse(store.updateProgress(giftId: "gift-2", completedCount: 3))
        store.loadInitial(anchorUserId: "anchor-1", anchorNickname: "Anchor")
        await waitForNextTick()

        XCTAssertEqual(store.items.first?.completedCount, 3)
        XCTAssertEqual(store.items.first?.progress, 0.6)
    }

    func testCompletionReceivedBeforeInitialLoadIsAppliedToLoadedWishlist() async {
        let store = WishlistStore(service: WishlistFakeService(items: [wish(id: "gift-2", target: 5)]))

        XCTAssertFalse(store.markCompleted(wholePool: false, giftId: "gift-2", hasGiftId: true))
        store.loadInitial(anchorUserId: "anchor-1", anchorNickname: "Anchor")
        await waitForNextTick()

        XCTAssertEqual(store.items.first?.completedCount, 5)
        XCTAssertTrue(store.items.first?.isCompleted == true)
    }

    func testMissingAbsoluteProgressUsesReceivedGiftCount() async {
        let store = WishlistStore(service: WishlistFakeService(items: [wish(id: "gift-2", target: 10)]))
        store.loadInitial(anchorUserId: "anchor-1", anchorNickname: "Anchor")
        await waitForNextTick()

        XCTAssertTrue(store.applyGiftProgress(giftId: "gift-2", completedCount: nil, receivedCount: 3))
        XCTAssertEqual(store.items.first?.completedCount, 3)
    }

    func testProgressCyclesThroughEveryWishlistItemIndex() {
        XCTAssertEqual(WishlistCarouselIndex.next(after: 0, count: 3), 1)
        XCTAssertEqual(WishlistCarouselIndex.next(after: 1, count: 3), 2)
        XCTAssertEqual(WishlistCarouselIndex.next(after: 2, count: 3), 0)
    }

    private func waitForNextTick() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private func wish(id: String, target: Int) -> WishlistItem {
        WishlistItem(
            id: id,
            giftName: "Gift",
            giftIconUrl: nil,
            giftPrice: 100,
            targetCount: target,
            completedCount: 0,
            isMarkedCompleted: false,
            promiseText: nil
        )
    }
}

private struct WishlistFakeService: WishlistServiceProtocol {
    let items: [WishlistItem]

    func fetchWishlist(anchorUserId: String) async throws -> [WishlistItem] {
        items
    }

    func fetchTop6(liveRecordId: String, anchorId: String) async throws -> [WishlistTop6Item] {
        []
    }
}
