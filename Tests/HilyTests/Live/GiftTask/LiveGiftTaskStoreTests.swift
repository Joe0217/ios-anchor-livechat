import XCTest

/// spec §1.4 tc-1a-1~7 · LiveGiftTaskStore 状态机 + 竞态保护单测。
@MainActor
final class LiveGiftTaskStoreTests: XCTestCase {

    // MARK: - fixtures

    private func makeStore(mode: LiveGiftTaskServiceFakes.Mode = .success) -> LiveGiftTaskStore {
        LiveGiftTaskStore(service: LiveGiftTaskServiceFakes(mode: mode))
    }

    /// 等 async 任务完成的 helper —— 让 Task 有机会 yield
    private func waitForNextTick() async {
        try? await Task.sleep(nanoseconds: 20_000_000)   // 20ms
    }

    // MARK: - tc-1a-1: idle → loadInitial → loading → loaded

    func testLoadInitial_success() async {
        let store = makeStore(mode: .success)
        XCTAssertEqual(store.loadState, .idle)

        store.loadInitial(anchorUserId: "1")
        XCTAssertEqual(store.loadState, .loading)   // 同步进 loading

        await waitForNextTick()

        if case .loaded(let progress) = store.loadState {
            XCTAssertEqual(progress.giftTotal, 1200)
            XCTAssertEqual(progress.taskAmount, 5000)
        } else {
            XCTFail("Expected .loaded, got \(store.loadState)")
        }
        XCTAssertNotNil(store.giftTask)
        XCTAssertTrue(store.isIconVisible)
    }

    // MARK: - tc-1a-2: loadInitial 失败 → error("...")

    func testLoadInitial_failure() async {
        let store = makeStore(mode: .error("network"))
        store.loadInitial(anchorUserId: "1")
        await waitForNextTick()

        if case .error(let msg) = store.loadState {
            XCTAssertTrue(msg.contains("network"))
        } else {
            XCTFail("Expected .error, got \(store.loadState)")
        }
        XCTAssertNil(store.giftTask)
        XCTAssertFalse(store.isIconVisible)
    }

    // MARK: - tc-1a-3: loaded → refreshOnGift → refreshing(previous) → loaded(new)

    func testRefreshOnGift_preservesVisualDuringRefresh() async {
        let store = makeStore(mode: .success)
        store.loadInitial(anchorUserId: "1")
        await waitForNextTick()
        guard case .loaded = store.loadState else {
            XCTFail("Setup failed: expected loaded")
            return
        }

        // 切换 service 到 slow mode 观察 refreshing 中间态
        let slowStore = LiveGiftTaskStore(
            service: LiveGiftTaskServiceFakes(mode: .delayed(nanoseconds: 100_000_000))
        )
        slowStore.loadInitial(anchorUserId: "1")   // 首次 loading(无 previous)
        await waitForNextTick()
        // delayed 模式 preflight 100ms 后 fetch,20ms 内还未完成 → 仍 loading

        // 触发 refresh 前先让首次完成
        try? await Task.sleep(nanoseconds: 150_000_000)
        // 首次会 fallback 到 default success values
        XCTAssertNotNil(slowStore.giftTask, "Setup: 首次加载应完成")
        let previousGiftTotal = slowStore.giftTask?.giftTotal

        // refreshOnGift 触发 → 应进 refreshing(previous),视觉保留
        slowStore.refreshOnGift()
        // 同步进 refreshing 中间态
        if case .refreshing(let previous) = slowStore.loadState {
            XCTAssertEqual(previous.giftTotal, previousGiftTotal)
        } else {
            XCTFail("Expected .refreshing(previous), got \(slowStore.loadState)")
        }

        // 等待完成
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard case .loaded = slowStore.loadState else {
            XCTFail("Expected .loaded after refresh, got \(slowStore.loadState)")
            return
        }
    }

    // MARK: - tc-1a-4: refreshOnGift 失败 → errorWithPrevious(previous)

    func testRefreshOnGift_failurePreservesPrevious() async {
        let store = makeStore(mode: .success)
        store.loadInitial(anchorUserId: "1")
        await waitForNextTick()
        guard case .loaded(let previousProgress) = store.loadState else {
            XCTFail("Setup failed")
            return
        }

        // 切 service 到 error mode 后手动模拟"另一次 fetch 失败"
        // 由于 store 里 service 已注入,这里创建新 store 观察 error 保留 previous 行为
        let errorAwareStore = LiveGiftTaskStore(
            service: SwitchableFake(initialMode: .success, secondCallMode: .error("500"))
        )
        errorAwareStore.loadInitial(anchorUserId: "1")
        await waitForNextTick()
        guard case .loaded(let firstProgress) = errorAwareStore.loadState else {
            XCTFail("Setup failed on switchable")
            return
        }

        // 第二次 refresh → 应 error 保留 previous
        errorAwareStore.refreshOnGift()
        await waitForNextTick()
        if case .errorWithPrevious(let saved, let msg) = errorAwareStore.loadState {
            XCTAssertEqual(saved.giftTotal, firstProgress.giftTotal)
            XCTAssertEqual(saved.taskAmount, firstProgress.taskAmount)
            XCTAssertTrue(msg.contains("500"))
        } else {
            XCTFail("Expected .errorWithPrevious, got \(errorAwareStore.loadState)")
        }
        // giftTask 派生仍返 previous
        XCTAssertEqual(errorAwareStore.giftTask?.giftTotal, previousProgress.giftTotal)
    }

    // MARK: - tc-1a-5: reset → idle

    func testReset() async {
        let store = makeStore(mode: .success)
        store.loadInitial(anchorUserId: "1")
        await waitForNextTick()
        XCTAssertNotNil(store.giftTask)

        store.reset()
        XCTAssertEqual(store.loadState, .idle)
        XCTAssertNil(store.giftTask)
        XCTAssertFalse(store.isIconVisible)
    }

    // MARK: - tc-1a-6: refreshOnGift 竞态保护 · 连续触发只保留最后一次

    func testRefreshOnGift_raceCancellation() async {
        // 用 CountingFake:每次 fetch delay 50ms,并按调用序号返不同 giftTotal
        let counting = CountingFake(delayNs: 50_000_000, valueByCall: [
            1: GiftTaskProgress(giftTotal: 100, taskAmount: 1000),
            2: GiftTaskProgress(giftTotal: 200, taskAmount: 1000),
            3: GiftTaskProgress(giftTotal: 300, taskAmount: 1000)
        ])
        let store = LiveGiftTaskStore(service: counting)

        // 首次 loadInitial → 触发 fetch #1
        store.loadInitial(anchorUserId: "1")
        // 无间隔连续触发 refreshOnGift 两次 → 触发 fetch #2, #3;
        // #1 和 #2 的 currentTask 都应被 cancel,只 #3 完成
        store.refreshOnGift()
        store.refreshOnGift()

        // 等所有 pending 完成
        try? await Task.sleep(nanoseconds: 300_000_000)

        if case .loaded(let final) = store.loadState {
            // 由于 currentTask.cancel + 新 task 覆盖 pattern,只有最后一次 fetch 结果生效
            // service 计数器验证 fetch 触发 3 次,但只 #3 的 assign 会 stick
            XCTAssertEqual(final.giftTotal, 300, "Expected final assign to be call #3")
        } else {
            XCTFail("Expected .loaded final, got \(store.loadState)")
        }
    }

    // MARK: - tc-1a-7 边界:taskAmount=nil 时 icon 隐藏

    func testIconVisibility_taskAmountNil() async {
        let store = makeStore(mode: .empty)
        store.loadInitial(anchorUserId: "1")
        await waitForNextTick()
        XCTAssertNotNil(store.giftTask)
        XCTAssertFalse(store.isIconVisible)
    }
}

// MARK: - Test-only fakes

/// 首次 success,第二次可控 mode(用于 refresh 失败测试)
private final class SwitchableFake: LiveGiftTaskServiceProtocol, @unchecked Sendable {
    private var callCount = 0
    private let lock = NSLock()
    private let secondCallMode: LiveGiftTaskServiceFakes.Mode
    private let successFake = LiveGiftTaskServiceFakes(mode: .success)
    private lazy var secondFake = LiveGiftTaskServiceFakes(mode: secondCallMode)

    init(initialMode: LiveGiftTaskServiceFakes.Mode, secondCallMode: LiveGiftTaskServiceFakes.Mode) {
        self.secondCallMode = secondCallMode
    }

    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress {
        lock.lock()
        callCount += 1
        let n = callCount
        lock.unlock()
        if n == 1 {
            return try await successFake.fetchLiveGiftTask(anchorUserId: "")
        } else {
            return try await secondFake.fetchLiveGiftTask(anchorUserId: "")
        }
    }

    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem] {
        try await successFake.fetchLiveGiftHistory(anchorUserId: anchorUserId, page: page, pageSize: pageSize)
    }

    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO] {
        try await successFake.fetchActiveTycoonTaskPanel()
    }
}

/// 每次 fetch delay + 按 call# 返配置的 value(用于竞态测试)
private final class CountingFake: LiveGiftTaskServiceProtocol, @unchecked Sendable {
    private var callCount = 0
    private let lock = NSLock()
    private let delayNs: UInt64
    private let valueByCall: [Int: GiftTaskProgress]

    init(delayNs: UInt64, valueByCall: [Int: GiftTaskProgress]) {
        self.delayNs = delayNs
        self.valueByCall = valueByCall
    }

    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress {
        lock.lock()
        callCount += 1
        let n = callCount
        lock.unlock()
        try await Task.sleep(nanoseconds: delayNs)
        try Task.checkCancellation()
        return valueByCall[n] ?? GiftTaskProgress(giftTotal: 0, taskAmount: 1000)
    }

    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem] {
        return []
    }

    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO] {
        return []
    }
}
