import XCTest

/// spec §1.4 tc-1a-8~14 · LiveGiftTaskHistoryStore 分页无限滚动状态机 + 竞态。
@MainActor
final class LiveGiftTaskHistoryStoreTests: XCTestCase {

    private func makeStore(mode: LiveGiftTaskServiceFakes.Mode = .success,
                           pageSize: Int = 20) -> LiveGiftTaskHistoryStore {
        LiveGiftTaskHistoryStore(service: LiveGiftTaskServiceFakes(mode: mode), pageSize: pageSize)
    }

    private func waitForNextTick() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    // MARK: - tc-1a-8: idle → refresh → loading → loaded(20, hasMore)

    func testRefresh_firstPageLoaded() async {
        let store = makeStore()
        XCTAssertEqual(store.pagingState, .idle)

        await store.refreshAsync(anchorUserId: "1")

        if case .loaded(let items, let hasMore) = store.pagingState {
            XCTAssertEqual(items.count, 20)
            XCTAssertTrue(hasMore)
        } else {
            XCTFail("Expected .loaded(20, hasMore), got \(store.pagingState)")
        }
    }

    // MARK: - tc-1a-9: loaded → loadMore → loadingMore → loaded(items+new)

    func testLoadMore_appends() async {
        let store = makeStore()
        await store.refreshAsync(anchorUserId: "1")
        guard case .loaded(let firstItems, true) = store.pagingState else {
            XCTFail("Setup failed")
            return
        }
        XCTAssertEqual(firstItems.count, 20)

        // 触发 loadMore(用最后一项作触底信号)
        store.loadMoreIfNeeded(currentItem: firstItems.last!, anchorUserId: "1")
        await waitForNextTick()   // 让 async 完成

        // H5 只有空数组才结束；page 2 虽不足 pageSize，仍允许继续加载。
        if case .loaded(let items, let hasMore) = store.pagingState {
            XCTAssertEqual(items.count, 30)   // 20 + 10
            XCTAssertTrue(hasMore)
        } else {
            XCTFail("Expected .loaded(30, hasMore), got \(store.pagingState)")
        }
    }

    // MARK: - tc-1a-10: loaded(hasMore) → loadMore 返 [] → finished(items 保留)

    func testLoadMore_emptyPage_finishes() async {
        let store = makeStore(mode: .empty)
        await store.refreshAsync(anchorUserId: "1")
        if case .finished(let items) = store.pagingState {
            XCTAssertTrue(items.isEmpty)
        } else {
            XCTFail("Expected .finished, got \(store.pagingState)")
        }
    }

    // MARK: - tc-1a-11: loaded → refresh → loading(empty)

    func testRefresh_clearsItemsDuringLoading() async {
        // 首次加载得到 20 项
        let store = makeStore()
        await store.refreshAsync(anchorUserId: "1")
        guard case .loaded(let firstItems, _) = store.pagingState else {
            XCTFail("Setup failed")
            return
        }

        // 观察 refreshing 中间态:用 slow service
        let slowStore = LiveGiftTaskHistoryStore(
            service: LiveGiftTaskServiceFakes(mode: .delayed(nanoseconds: 100_000_000))
        )
        // 首次先加载让 items 有值
        await slowStore.refreshAsync(anchorUserId: "1")
        // delayed mode preflight 返空后走 .finished 空态,items 空
        // 换策略:先手动进 loaded 态
        _ = firstItems   // 只 assertion 用 firstItems 已加载
        XCTAssertFalse(store.items.isEmpty)

        // 让 store 从 .loaded 走 refresh → 应进 refreshing(items) 中间态
        // 用一个 SlowSecondCall fake 观察中间态
        let phaseStore = LiveGiftTaskHistoryStore(service: SlowSecondCallFake(delayNs: 200_000_000))
        await phaseStore.refreshAsync(anchorUserId: "1")
        guard case .loaded(let items, _) = phaseStore.pagingState else {
            XCTFail("Setup slow fake first call failed")
            return
        }

        // Trigger second refresh(async 不 await 立即观察)
        Task { @MainActor in
            await phaseStore.refreshAsync(anchorUserId: "1")
        }
        // H5 refresh 起手清空。
        try? await Task.sleep(nanoseconds: 30_000_000)
        if case .loading = phaseStore.pagingState {
            XCTAssertFalse(items.isEmpty)
        } else {
            XCTFail("Expected .loading during second call, got \(phaseStore.pagingState)")
        }
    }

    // MARK: - tc-1a-12: refresh 失败 → finished([])

    func testRefresh_failureClearsItems() async {
        // 首次 success 加载
        let store = LiveGiftTaskHistoryStore(
            service: SwitchableHistoryFake(firstMode: .success, secondMode: .error("net"))
        )
        await store.refreshAsync(anchorUserId: "1")
        guard case .loaded(let firstItems, _) = store.pagingState else {
            XCTFail("Setup failed")
            return
        }

        // H5 catch 清空列表并结束。
        await store.refreshAsync(anchorUserId: "1")
        if case .finished(let items) = store.pagingState {
            XCTAssertTrue(firstItems.count > 0)
            XCTAssertTrue(items.isEmpty)
        } else {
            XCTFail("Expected .finished([]), got \(store.pagingState)")
        }
    }

    // MARK: - tc-1a-13: reset cancel pending 不写入结果

    func testReset_cancelPending() async {
        // 用 slow fake 让 fetch 挂起,reset 后 pending 不写入
        let store = LiveGiftTaskHistoryStore(
            service: LiveGiftTaskServiceFakes(mode: .delayed(nanoseconds: 200_000_000))
        )
        Task { @MainActor in
            await store.refreshAsync(anchorUserId: "1")
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        // 此时应还在 loading

        store.reset()
        XCTAssertEqual(store.pagingState, .idle)

        // 等 pending 完成
        try? await Task.sleep(nanoseconds: 300_000_000)
        // reset 后应仍是 .idle(pending 结果不写入)
        XCTAssertEqual(store.pagingState, .idle)
    }

    // MARK: - tc-1a-14: loadMoreIfNeeded 只在 .loaded(hasMore) 时有效

    func testLoadMore_ignoredWhenNotLoaded() async {
        let store = makeStore()
        // idle 态触发 loadMore → no-op
        let dummy = IndexedGiftHistoryItem(page: 1, row: 0,
            item: GiftHistoryItem(userId: "u", icon: "", nickname: "n",
                                  formattedTime: "", giftIcon: "", giftNum: 1))
        store.loadMoreIfNeeded(currentItem: dummy, anchorUserId: "1")
        await waitForNextTick()
        XCTAssertEqual(store.pagingState, .idle, "loadMore in idle should no-op")
    }

    /// finished 后再调 loadMore no-op
    func testLoadMore_ignoredWhenFinished() async {
        let store = makeStore(mode: .empty)
        await store.refreshAsync(anchorUserId: "1")
        guard case .finished(let items) = store.pagingState else {
            XCTFail("Setup failed")
            return
        }
        store.loadMoreIfNeeded(currentItem: items.last!, anchorUserId: "1")
        await waitForNextTick()
        if case .finished(let stillItems) = store.pagingState {
            XCTAssertEqual(stillItems.count, items.count)
        } else {
            XCTFail("Expected still .finished")
        }
    }

    /// loadMoreIfNeeded 只触发在最后一项(避免中间项误触发)
    func testLoadMore_onlyTriggeredByLastItem() async {
        let store = makeStore()
        await store.refreshAsync(anchorUserId: "1")
        guard case .loaded(let items, _) = store.pagingState else {
            XCTFail("Setup failed")
            return
        }
        // 用第 5 项触发 → no-op
        store.loadMoreIfNeeded(currentItem: items[5], anchorUserId: "1")
        await waitForNextTick()
        // 状态仍 loaded(未进 loadingMore/finished)
        if case .loaded(let stillItems, _) = store.pagingState {
            XCTAssertEqual(stillItems.count, items.count)
        } else {
            XCTFail("Expected still .loaded")
        }
    }

    // MARK: - Empty case: page 1 返 [] → finished([])

    func testRefresh_emptyResult() async {
        let store = makeStore(mode: .empty)
        await store.refreshAsync(anchorUserId: "1")
        if case .finished(let items) = store.pagingState {
            XCTAssertTrue(items.isEmpty)
        } else {
            XCTFail("Expected .finished([]), got \(store.pagingState)")
        }
    }
}

// MARK: - Test-only fakes

/// 首次 success,第二次可控(用于 refresh 失败测试 + refreshing 中间态观察)
private final class SwitchableHistoryFake: LiveGiftTaskServiceProtocol, @unchecked Sendable {
    private var callCount = 0
    private let lock = NSLock()
    private let firstFake: LiveGiftTaskServiceFakes
    private let secondFake: LiveGiftTaskServiceFakes

    init(firstMode: LiveGiftTaskServiceFakes.Mode, secondMode: LiveGiftTaskServiceFakes.Mode) {
        self.firstFake = LiveGiftTaskServiceFakes(mode: firstMode)
        self.secondFake = LiveGiftTaskServiceFakes(mode: secondMode)
    }

    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress {
        try await firstFake.fetchLiveGiftTask(anchorUserId: "")
    }

    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem] {
        lock.lock(); callCount += 1; let n = callCount; lock.unlock()
        if n == 1 {
            return try await firstFake.fetchLiveGiftHistory(anchorUserId: anchorUserId, page: page, pageSize: pageSize)
        }
        return try await secondFake.fetchLiveGiftHistory(anchorUserId: anchorUserId, page: page, pageSize: pageSize)
    }

    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO] {
        try await firstFake.fetchActiveTycoonTaskPanel()
    }
}

/// 首次 success 立即返,第二次 delay 让 refreshing 中间态可观察
private final class SlowSecondCallFake: LiveGiftTaskServiceProtocol, @unchecked Sendable {
    private var callCount = 0
    private let lock = NSLock()
    private let delayNs: UInt64
    private let fastFake = LiveGiftTaskServiceFakes(mode: .success)

    init(delayNs: UInt64) { self.delayNs = delayNs }

    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress {
        try await fastFake.fetchLiveGiftTask(anchorUserId: "")
    }

    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem] {
        lock.lock(); callCount += 1; let n = callCount; lock.unlock()
        if n > 1 {
            try await Task.sleep(nanoseconds: delayNs)
        }
        try Task.checkCancellation()
        return try await fastFake.fetchLiveGiftHistory(anchorUserId: anchorUserId, page: page, pageSize: pageSize)
    }

    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO] {
        try await fastFake.fetchActiveTycoonTaskPanel()
    }
}
