import XCTest

/// I-1（黑名单列表）— BlocklistViewModel 状态机单测。
///
/// 覆盖 spec `I-1-spec-黑名单列表-202606242030.md` §3.3 8 条不变量 + §5 可单测反向/边界用例。
@MainActor
final class BlocklistViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeVM(items: [BlocklistItem] = [],
                       fake: FakeBlocklistService = FakeBlocklistService(),
                       pageSize: Int = 20) -> (BlocklistViewModel, FakeBlocklistService) {
        fake.fetchResult = .success(items)
        let vm = BlocklistViewModel(service: fake, pageSize: pageSize,
                                    networkErrorFallback: "stub-network",
                                    badUserIdFallback: "stub-baduid")
        return (vm, fake)
    }

    // MARK: - F-2 / F-4 / F-9 首页加载正向

    func test_loadFirstPage_success_setsLoadedWithItems() async {
        let items = (1...3).map { BlocklistItem.fixture(userId: "\($0)") }
        let (vm, fake) = makeVM(items: items)
        await vm.loadFirstPage()
        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertEqual(vm.items.count, 3)
        XCTAssertEqual(fake.fetchCalls.count, 1)
        XCTAssertEqual(fake.fetchCalls.first?.page, 1)
    }

    func test_loadFirstPage_resetsItemsAndKeepsLatest() async {
        let (vm, fake) = makeVM(items: [BlocklistItem.fixture(userId: "1")])
        await vm.loadFirstPage()
        XCTAssertEqual(vm.items.map(\.userId), ["1"])
        // 第 2 次调用 loadFirstPage 应覆盖（不追加）
        fake.fetchResult = .success([BlocklistItem.fixture(userId: "99")])
        await vm.loadFirstPage()
        XCTAssertEqual(vm.items.map(\.userId), ["99"])
        XCTAssertEqual(fake.fetchCalls.count, 2)
    }

    // MARK: - F-3 / R-5 触底加载

    func test_loadMore_success_appendsToItems() async {
        let page1 = (1...20).map { BlocklistItem.fixture(userId: "\($0)") }
        let page2 = (21...30).map { BlocklistItem.fixture(userId: "\($0)") }
        let fake = FakeBlocklistService()
        fake.fetchPageResults = [1: .success(page1), 2: .success(page2)]
        let vm = BlocklistViewModel(service: fake, pageSize: 20)

        await vm.loadFirstPage()
        XCTAssertTrue(vm.hasMore)   // 满页 → hasMore=true
        await vm.loadMore()

        XCTAssertEqual(vm.items.count, 30)
        XCTAssertEqual(vm.items.map(\.userId).first, "1")
        XCTAssertEqual(vm.items.map(\.userId).last, "30")
        XCTAssertFalse(vm.hasMore)  // 不足页 → hasMore=false
    }

    func test_loadMore_emptyPage_setsHasMoreFalse() async {
        let page1 = (1...20).map { BlocklistItem.fixture(userId: "\($0)") }
        let fake = FakeBlocklistService()
        fake.fetchPageResults = [1: .success(page1), 2: .success([])]
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 20)
        XCTAssertFalse(vm.hasMore)
    }

    func test_loadMore_hasMoreFalse_isNoop() async {
        let items = [BlocklistItem.fixture(userId: "1")]
        let fake = FakeBlocklistService()
        fake.fetchResult = .success(items)
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        XCTAssertFalse(vm.hasMore)
        await vm.loadMore()
        // service 没被再次调用
        XCTAssertEqual(fake.fetchCalls.count, 1)
    }

    // MARK: - F-5 / R-2 空态

    func test_loadFirstPage_emptyResult_setsLoadedWithEmptyItems() async {
        let (vm, _) = makeVM(items: [])
        await vm.loadFirstPage()
        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertFalse(vm.hasMore)
    }

    // MARK: - R-1 / R-4 加载失败

    func test_loadFirstPage_failure_setsError() async {
        let fake = FakeBlocklistService()
        fake.fetchResult = .failure(StubNetworkError(kind: "timeout"))
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        guard case .error(let msg) = vm.loadState else {
            XCTFail("expected .error, got \(vm.loadState)")
            return
        }
        XCTAssertTrue(msg.contains("timeout"))
        XCTAssertTrue(vm.items.isEmpty)
    }

    func test_loadMore_failure_keepsExistingItemsAndSetsError() async {
        let page1 = (1...20).map { BlocklistItem.fixture(userId: "\($0)") }
        let fake = FakeBlocklistService()
        fake.fetchPageResults = [1: .success(page1), 2: .failure(StubNetworkError(kind: "timeout"))]
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 20)   // 已加载的不抹掉
        XCTAssertTrue(vm.loadState.errorMessage?.contains("timeout") == true)
    }

    // MARK: - retry

    func test_retry_fromErrorWithEmptyItems_callsLoadFirstPage() async {
        let fake = FakeBlocklistService()
        fake.fetchResult = .failure(StubNetworkError(kind: "first-fail"))
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        XCTAssertEqual(fake.fetchCalls.count, 1)

        // 切换为成功，retry
        fake.fetchResult = .success([BlocklistItem.fixture(userId: "1")])
        await vm.retry()
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertEqual(fake.fetchCalls.count, 2)
        XCTAssertEqual(fake.fetchCalls.last?.page, 1)
    }

    func test_retry_fromLoadMoreErrorWithItems_callsLoadMore() async {
        let page1 = (1...20).map { BlocklistItem.fixture(userId: "\($0)") }
        let fake = FakeBlocklistService()
        fake.fetchPageResults = [1: .success(page1), 2: .failure(StubNetworkError(kind: "page-fail"))]
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        await vm.loadMore()
        XCTAssertEqual(fake.fetchCalls.count, 2)
        // 切为成功
        fake.fetchPageResults[2] = .success((21...25).map { BlocklistItem.fixture(userId: "\($0)") })
        await vm.retry()
        XCTAssertEqual(vm.items.count, 25)
        XCTAssertEqual(fake.fetchCalls.count, 3)
        XCTAssertEqual(fake.fetchCalls.last?.page, 2)
    }

    // MARK: - F-7 / R-6 / R-8 删除

    func test_unblock_success_removesFromItems() async {
        let items = (1...3).map { BlocklistItem.fixture(userId: "\($0)") }
        let (vm, fake) = makeVM(items: items)
        await vm.loadFirstPage()
        let target = vm.items[1]   // userId="2"
        await vm.unblock(target)
        XCTAssertEqual(vm.items.map(\.userId), ["1", "3"])
        XCTAssertEqual(fake.removeCalls.count, 1)
        XCTAssertEqual(fake.removeCalls.first?.userId, 2)
        XCTAssertEqual(fake.removeCalls.first?.type, 1)   // 硬编 1
    }

    func test_unblock_failure_rollsBackToOriginalIndex_andSetsTransientError() async {
        let items = (1...3).map { BlocklistItem.fixture(userId: "\($0)") }
        let fake = FakeBlocklistService()
        fake.fetchResult = .success(items)
        fake.removeResult = .failure(StubNetworkError(kind: "rm-fail"))
        // 显式注入 stub fallback，断言 ViewModel 走「非 APIError → fallback」分支
        let vm = BlocklistViewModel(service: fake, pageSize: 20,
                                    networkErrorFallback: "stub-network",
                                    badUserIdFallback: "stub-baduid")
        await vm.loadFirstPage()
        let target = vm.items[1]   // userId="2"
        await vm.unblock(target)
        // 失败回滚：列表应恢复原状（顺序不变）
        XCTAssertEqual(vm.items.map(\.userId), ["1", "2", "3"])
        XCTAssertEqual(vm.transientError, "stub-network")
        XCTAssertFalse(vm.pendingRemoveIds.contains("2"))   // pending 释放
    }

    func test_unblock_failureWithAPIError_usesAPIErrorMessage() async {
        let items = [BlocklistItem.fixture(userId: "1")]
        let fake = FakeBlocklistService()
        fake.fetchResult = .success(items)
        fake.removeResult = .failure(APIError(code: "1080", message: "余额不足"))
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        await vm.unblock(vm.items[0])
        XCTAssertEqual(vm.transientError, "余额不足")
    }

    func test_unblock_concurrentSameUserId_secondCallNoop() async {
        let items = [BlocklistItem.fixture(userId: "1")]
        let fake = FakeBlocklistService()
        fake.fetchResult = .success(items)
        fake.delaySeconds = 0.05   // 让第一次 unblock 还在飞
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        let target = vm.items[0]

        async let r1: Void = vm.unblock(target)
        // 等 pending 被设上
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let r2: Void = vm.unblock(target)
        _ = await (r1, r2)

        // 仅一次 service 调用（第二次被 pending 守卫拦截）
        XCTAssertEqual(fake.removeCalls.count, 1)
    }

    // MARK: - R-10 userId 转 Int 失败

    func test_unblock_badUserId_setsTransientError_doesNotCallService() async {
        let items = [BlocklistItem.fixture(userId: "abc")]   // 非数字
        let (vm, fake) = makeVM(items: items)
        await vm.loadFirstPage()
        await vm.unblock(vm.items[0])
        XCTAssertEqual(vm.transientError, "stub-baduid")
        XCTAssertEqual(fake.removeCalls.count, 0)
        // 列表不变
        XCTAssertEqual(vm.items.count, 1)
    }

    // MARK: - R-14 不去重（fail-loud）

    func test_items_withDuplicateIds_keptAsIs() async {
        let items = [
            BlocklistItem.fixture(userId: "1"),
            BlocklistItem.fixture(userId: "1"),
            BlocklistItem.fixture(userId: "2"),
        ]
        let (vm, _) = makeVM(items: items)
        await vm.loadFirstPage()
        XCTAssertEqual(vm.items.count, 3)   // 不去重
    }

    // MARK: - 不变量 #4 代际 token 隔离

    func test_unblock_failureAfterRefresh_dropsRollback() async {
        let items = (1...3).map { BlocklistItem.fixture(userId: "\($0)") }
        let fake = FakeBlocklistService()
        fake.fetchResult = .success(items)
        fake.removeResult = .failure(StubNetworkError(kind: "rm-fail"))
        fake.delaySeconds = 0.05   // 让 remove 在飞
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        let target = vm.items[1]
        async let removing: Void = vm.unblock(target)
        try? await Task.sleep(nanoseconds: 5_000_000)
        // 期间用户下拉刷新（生成 token 漂移）
        fake.fetchResult = .success([BlocklistItem.fixture(userId: "9")])
        await vm.loadFirstPage()
        _ = await removing

        // 漂移后：不回滚到旧 items；新 items 是刷新结果
        XCTAssertEqual(vm.items.map(\.userId), ["9"])
        // 漂移路径不设 transientError（避免给已离开的视图弹 toast）
        XCTAssertNil(vm.transientError)
    }

    // MARK: - 真分页 fallback 检测

    func test_loadMore_serverReturnsSameItems_setsHasMoreFalse() async {
        let page1 = (1...20).map { BlocklistItem.fixture(userId: "\($0)") }
        let fake = FakeBlocklistService()
        // 服务端不支持分页：page=2 仍返 page=1 末 20 条同样数据
        fake.fetchPageResults = [1: .success(page1), 2: .success(page1)]
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        await vm.loadMore()
        // hasMore 强制 false，items 仍是 page1（未追加重复）
        XCTAssertFalse(vm.hasMore)
        XCTAssertEqual(vm.items.count, 20)
    }

    // MARK: - 不变量 #5 items 非空守卫

    func test_unblock_emptyItems_isNoop() async {
        let fake = FakeBlocklistService()
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        // 没 loadFirstPage，items 空
        let phantom = BlocklistItem.fixture(userId: "1")
        await vm.unblock(phantom)
        XCTAssertEqual(fake.removeCalls.count, 0)
        XCTAssertNil(vm.transientError)
    }

    // MARK: - 不变量 #1 loading 中再触发被守卫

    func test_loadFirstPage_whileLoading_isNoop() async {
        let fake = FakeBlocklistService()
        fake.fetchResult = .success([BlocklistItem.fixture(userId: "1")])
        fake.delaySeconds = 0.05
        let vm = BlocklistViewModel(service: fake, pageSize: 20)

        async let r1: Void = vm.loadFirstPage()
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let r2: Void = vm.loadFirstPage()
        _ = await (r1, r2)

        XCTAssertEqual(fake.fetchCalls.count, 1)   // 第二次被 isLoading 守卫
    }

    // MARK: - transientError 清除

    func test_clearTransientError_setsNil() async {
        let items = [BlocklistItem.fixture(userId: "1")]
        let fake = FakeBlocklistService()
        fake.fetchResult = .success(items)
        fake.removeResult = .failure(StubNetworkError(kind: "fail"))
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        await vm.unblock(vm.items[0])
        XCTAssertNotNil(vm.transientError)
        vm.clearTransientError()
        XCTAssertNil(vm.transientError)
    }

    // MARK: - 状态机不分 loadingFirst vs loadingMore 验证（不变量 #1 拆分）

    func test_loadState_isLoadingFirstPage_duringFirstLoad() async {
        let fake = FakeBlocklistService()
        fake.fetchResult = .success([])
        fake.delaySeconds = 0.05
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        async let run: Void = vm.loadFirstPage()
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(vm.loadState, .loadingFirstPage)
        _ = await run
    }

    func test_loadState_isLoadingMore_duringMoreLoad() async {
        let page1 = (1...20).map { BlocklistItem.fixture(userId: "\($0)") }
        let fake = FakeBlocklistService()
        fake.fetchPageResults = [1: .success(page1), 2: .success([])]
        fake.delaySeconds = 0
        let vm = BlocklistViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        XCTAssertTrue(vm.hasMore)

        // 让 page 2 慢
        fake.delaySeconds = 0.05
        async let run: Void = vm.loadMore()
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(vm.loadState, .loadingMore)
        _ = await run
    }
}
