import XCTest

/// spec §1.4 tc-1a-15~19 · ActiveTycoonTaskStore 状态机 + firstTaskRuleText 边界。
@MainActor
final class ActiveTycoonTaskStoreTests: XCTestCase {

    private func makeStore(mode: LiveGiftTaskServiceFakes.Mode = .success) -> ActiveTycoonTaskStore {
        ActiveTycoonTaskStore(service: LiveGiftTaskServiceFakes(mode: mode))
    }

    private func waitForNextTick() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    // MARK: - tc-1a-15: idle → loadAsync → loading → loaded

    func testLoadAsync_success() async {
        let store = makeStore()
        XCTAssertEqual(store.loadState, .idle)

        await store.loadAsync()

        if case .loaded(let tasks) = store.loadState {
            XCTAssertEqual(tasks.count, 3)
            XCTAssertEqual(tasks[0].taskTitle, "Receive 10K diamonds")
        } else {
            XCTFail("Expected .loaded, got \(store.loadState)")
        }
    }

    // MARK: - tc-1a-16: loaded → 切走再回来(loadAsync 再调)→ 重新拉取

    func testLoadAsync_reloadsAfterFirstLoad() async {
        let store = makeStore()
        await store.loadAsync()
        let firstTasks = store.tasks
        XCTAssertFalse(firstTasks.isEmpty)

        // H5 active 由 false → true 时会再次 load。
        await store.loadAsync()
        XCTAssertEqual(store.tasks.map(\.taskId), firstTasks.map(\.taskId))
        // 请求完成后回到 loaded。
        if case .loaded = store.loadState {
            // OK
        } else {
            XCTFail("Expected .loaded after second loadAsync, got \(store.loadState)")
        }
    }

    // MARK: - tc-1a-17: loaded → 显式 refresh → refreshing(previous) → loaded(new)

    func testRefresh_preservesPrevious() async {
        let store = makeStore()
        await store.loadAsync()
        guard case .loaded(let firstTasks) = store.loadState else {
            XCTFail("Setup failed")
            return
        }

        // 显式 refresh —— 观察 refreshing(previous) 中间态
        // 用 slow fake
        let phaseStore = ActiveTycoonTaskStore(service: SlowTycoonFake(delayNs: 100_000_000))
        await phaseStore.loadAsync()
        guard case .loaded(let previous) = phaseStore.loadState else {
            XCTFail("Setup slow fake failed")
            return
        }

        Task { @MainActor in await phaseStore.refresh() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        if case .refreshing(let saved) = phaseStore.loadState {
            XCTAssertEqual(saved.count, previous.count)
        } else {
            XCTFail("Expected .refreshing(previous), got \(phaseStore.loadState)")
        }
        _ = firstTasks
    }

    // MARK: - tc-1a-18: firstTaskRuleText 各边界

    func testFirstTaskRuleText_nonEmpty() async {
        let store = makeStore()
        await store.loadAsync()
        // Fakes 里第 1 项 taskRuleText = "Complete tasks to earn rewards"
        XCTAssertEqual(store.firstTaskRuleText(), "Complete tasks to earn rewards")
    }

    func testFirstTaskRuleText_emptyList() async {
        let store = makeStore(mode: .empty)
        await store.loadAsync()
        XCTAssertEqual(store.firstTaskRuleText(), "")
    }

    func testFirstTaskRuleText_whitespaceOnly() async {
        // 用自定义 fake 让第一项 taskRuleText = "   "(空白)
        let store = ActiveTycoonTaskStore(service: CustomTycoonFake(taskRuleText: "   "))
        await store.loadAsync()
        XCTAssertEqual(store.firstTaskRuleText(), "")
    }

    func testFirstTaskRuleText_nilField() async {
        // 第一项 taskRuleText = nil
        let store = ActiveTycoonTaskStore(service: CustomTycoonFake(taskRuleText: nil))
        await store.loadAsync()
        XCTAssertEqual(store.firstTaskRuleText(), "")
    }

    // MARK: - tc-1a-19: loadAsync / refresh 失败均回到空态

    func testLoadAsync_failure_empty() async {
        let store = makeStore(mode: .error("timeout"))
        await store.loadAsync()
        if case .error(let msg) = store.loadState {
            XCTAssertTrue(msg.contains("timeout"))
        } else {
            XCTFail("Expected .error, got \(store.loadState)")
        }
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testRefresh_failureClearsItems() async {
        // 首次 success 加载
        let store = ActiveTycoonTaskStore(
            service: SwitchableTycoonFake(firstMode: .success, secondMode: .error("500"))
        )
        await store.loadAsync()
        guard case .loaded(let firstTasks) = store.loadState else {
            XCTFail("Setup failed")
            return
        }

        // 显式 refresh 触发 failure
        await store.refresh()
        if case .error(let msg) = store.loadState {
            XCTAssertTrue(msg.contains("500"))
        } else {
            XCTFail("Expected .error, got \(store.loadState)")
        }
        XCTAssertFalse(firstTasks.isEmpty)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    // MARK: - reset

    func testReset() async {
        let store = makeStore()
        await store.loadAsync()
        XCTAssertFalse(store.tasks.isEmpty)

        store.reset()
        XCTAssertEqual(store.loadState, .idle)
        XCTAssertTrue(store.tasks.isEmpty)
    }
}

// MARK: - Test-only fakes

private final class SlowTycoonFake: LiveGiftTaskServiceProtocol, @unchecked Sendable {
    private var callCount = 0
    private let lock = NSLock()
    private let delayNs: UInt64
    private let inner = LiveGiftTaskServiceFakes(mode: .success)

    init(delayNs: UInt64) { self.delayNs = delayNs }

    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress {
        try await inner.fetchLiveGiftTask(anchorUserId: "")
    }
    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem] {
        try await inner.fetchLiveGiftHistory(anchorUserId: anchorUserId, page: page, pageSize: pageSize)
    }
    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO] {
        lock.lock(); callCount += 1; let n = callCount; lock.unlock()
        if n > 1 {
            try await Task.sleep(nanoseconds: delayNs)
        }
        try Task.checkCancellation()
        return try await inner.fetchActiveTycoonTaskPanel()
    }
}

/// 让第一项 taskRuleText 可控(测试 firstTaskRuleText 边界)
private struct CustomTycoonFake: LiveGiftTaskServiceProtocol {
    let taskRuleText: String?

    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress {
        GiftTaskProgress(giftTotal: 0, taskAmount: 100)
    }
    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem] {
        []
    }
    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO] {
        var task1: [String: Any] = [
            "taskId": 1, "taskTitle": "T1", "targetValue": 100, "progressValue": 50, "rewardAmount": 10
        ]
        if let text = taskRuleText {
            task1["taskRuleText"] = text
        }
        let data = try JSONSerialization.data(withJSONObject: [task1])
        return try JSONDecoder().decode([ActiveTycoonTaskVO].self, from: data)
    }
}

private final class SwitchableTycoonFake: LiveGiftTaskServiceProtocol, @unchecked Sendable {
    private var callCount = 0
    private let lock = NSLock()
    private let first: LiveGiftTaskServiceFakes
    private let second: LiveGiftTaskServiceFakes

    init(firstMode: LiveGiftTaskServiceFakes.Mode, secondMode: LiveGiftTaskServiceFakes.Mode) {
        self.first = LiveGiftTaskServiceFakes(mode: firstMode)
        self.second = LiveGiftTaskServiceFakes(mode: secondMode)
    }

    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress {
        try await first.fetchLiveGiftTask(anchorUserId: "")
    }
    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem] {
        try await first.fetchLiveGiftHistory(anchorUserId: anchorUserId, page: page, pageSize: pageSize)
    }
    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO] {
        lock.lock(); callCount += 1; let n = callCount; lock.unlock()
        if n == 1 {
            return try await first.fetchActiveTycoonTaskPanel()
        }
        return try await second.fetchActiveTycoonTaskPanel()
    }
}
