import XCTest

/// PartyListStore 状态机单测（E-spec §2 / §5 反向清单驱动）。
///
/// 覆盖对应表：
/// - F-1 startInitial → loaded → test_startInitial_success_setsLoaded
/// - F-2 refresh → loading → loaded → test_refresh_success_replacesRooms
/// - F-3 loadMore → loadingMore → loaded(append) → test_loadMore_success_appends
/// - R-1 首屏网络失败 → .error → test_startInitial_networkError_setsError
/// - R-3 首屏返空 → .loaded([], false) → test_startInitial_empty_setsLoadedEmpty
/// - R-3a 空态下拉刷新 → test_refresh_fromEmpty_triggersLoading
/// - R-3b 空态 sentinel 不渲染 → hasMore==false（由 loaded 断言保证）
/// - R-4 分页失败 → .pageError → test_loadMore_failure_setsPageError
/// - R-5 分页 retry → loaded 追加 → test_retryPage_appends
/// - R-6 loading 中 loadMore → 忽略 → test_loading_ignoresLoadMore
/// - R-6a loadingMore 中 refresh 强夺 → test_refresh_preemptsLoadingMore
/// - R-6b error state double-tap retry → 忽略重复 → test_error_doubleTapRetry_singleCall
/// - error → refresh 语义等价 retry → test_refresh_fromError_triggersLoading
/// - pageError → refresh 从头拉 → test_refresh_fromPageError_resetsAndReloads
/// - 参数透传 languageCode → test_serviceCall_transmitsLanguageCode
/// - Cancel identity 不改 state（避免 dismount race）→ test_cancel_doesNotOverwriteState（隐含在 R-6a）

@MainActor
final class PartyListStoreTests: XCTestCase {

    // MARK: - 正向路径

    /// F-1: 冷启动 startInitial → loading → loaded 20 条 hasMore=true
    func test_startInitial_success_setsLoaded() async {
        let fake = FakePartyListService()
        let rooms = (0..<20).map { PartyRoomInfo.mock(id: "\($0)") }
        fake.responses = [.success(rooms)]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        guard case .loaded(let items, let hasMore) = store.state else {
            return XCTFail("expected loaded, got \(store.state)")
        }
        XCTAssertEqual(items.count, 20)
        XCTAssertTrue(hasMore) // page.count == pageSize → hasMore
    }

    /// F-1 不足一页：page.count < pageSize → hasMore=false
    func test_startInitial_partialPage_setsHasMoreFalse() async {
        let fake = FakePartyListService()
        fake.responses = [.success([.mock(id: "1"), .mock(id: "2")])]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        guard case .loaded(let items, let hasMore) = store.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(hasMore)
    }

    /// F-2: refresh 覆盖已有 rooms（清 + 重拉）
    func test_refresh_success_replacesRooms() async {
        let fake = FakePartyListService()
        fake.responses = [
            .success((0..<20).map { .mock(id: "old-\($0)") }),
            .success((0..<3).map { .mock(id: "new-\($0)") })  // 刷新后不足一页
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        store.refresh()
        await waitForState(store)

        guard case .loaded(let items, let hasMore) = store.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map { $0.stableListId }, ["id_new-0", "id_new-1", "id_new-2"])
        XCTAssertFalse(hasMore)
        XCTAssertEqual(fake.calls.count, 2)
    }

    /// F-3: loadMore 追加分页
    func test_loadMore_success_appends() async {
        let fake = FakePartyListService()
        fake.responses = [
            .success((0..<20).map { .mock(id: "p1-\($0)") }),
            .success((0..<5).map { .mock(id: "p2-\($0)") })  // 第二页不足 pageSize
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        store.loadMore()
        await waitForState(store)

        guard case .loaded(let items, let hasMore) = store.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertEqual(items.count, 25)
        XCTAssertFalse(hasMore)
        // 第二次调用 offset=pageSize
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertNil(fake.calls[0].offset)
        XCTAssertEqual(fake.calls[1].offset, 20)
    }

    // MARK: - 反向 / 边界

    /// R-1: 首屏网络失败 → .error(canRetry: true)
    func test_startInitial_networkError_setsError() async {
        let fake = FakePartyListService()
        fake.responses = [.throwing(PartyListServicePreviewFakeError.networkError)]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        guard case .error(_, let canRetry) = store.state else {
            return XCTFail("expected error, got \(store.state)")
        }
        XCTAssertTrue(canRetry)
    }

    /// R-3: 首屏返空 → .loaded([], hasMore=false)（非错误）
    func test_startInitial_empty_setsLoadedEmpty() async {
        let fake = FakePartyListService()
        fake.responses = [.success([])]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        guard case .loaded(let items, let hasMore) = store.state else {
            return XCTFail("expected loaded empty, got \(store.state)")
        }
        XCTAssertEqual(items.count, 0)
        XCTAssertFalse(hasMore)
    }

    /// R-3a: 空态下拉刷新 → refreshing(空 rooms) → 拉到数据
    ///
    /// list-refresh-preserve-items rule：refresh 保留已有 rooms 视觉。
    /// 空态（loaded([])）refresh 时 rooms 为空，语义上"保留空视觉"仍走 refreshing 分支。
    func test_refresh_fromEmpty_triggersRefreshing() async {
        let fake = FakePartyListService()
        fake.responses = [
            .success([]),
            .success([.mock(id: "1"), .mock(id: "2")])
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)
        XCTAssertEqual(store.state, .loaded(rooms: [], hasMore: false))

        store.refresh()
        // refresh 从 loaded 空态进入 refreshing(空 rooms) 而非 loading（保留空视觉，避免 full-screen loading 覆盖）
        XCTAssertEqual(store.state, .refreshing(rooms: []))

        await waitForState(store)
        guard case .loaded(let items, _) = store.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertEqual(items.count, 2)
    }

    /// R-4: 分页失败 → .pageError(保留 rooms + message)
    func test_loadMore_failure_setsPageError() async {
        let fake = FakePartyListService()
        fake.responses = [
            .success((0..<20).map { .mock(id: "p1-\($0)") }),
            .throwing(PartyListServicePreviewFakeError.networkError)
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        store.loadMore()
        await waitForState(store)

        guard case .pageError(let rooms, _) = store.state else {
            return XCTFail("expected pageError, got \(store.state)")
        }
        XCTAssertEqual(rooms.count, 20) // 保留已有
    }

    /// R-5: retryPage 从 .pageError → loadingMore → loaded 追加
    func test_retryPage_appends() async {
        let fake = FakePartyListService()
        fake.responses = [
            .success((0..<20).map { .mock(id: "p1-\($0)") }),
            .throwing(PartyListServicePreviewFakeError.networkError),
            .success((0..<3).map { .mock(id: "p2-\($0)") })
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        store.loadMore()
        await waitForState(store)
        guard case .pageError = store.state else {
            return XCTFail("expected pageError")
        }

        store.retryPage()
        await waitForState(store)

        guard case .loaded(let items, let hasMore) = store.state else {
            return XCTFail("expected loaded, got \(store.state)")
        }
        XCTAssertEqual(items.count, 23)
        XCTAssertFalse(hasMore)
        // 重试用相同 offset（loadedPageCount 未推进）
        XCTAssertEqual(fake.calls.map { $0.offset }, [nil, 20, 20])
    }

    /// R-6: loading 中 loadMore → 忽略 no-op（无第二次调用）
    func test_loading_ignoresLoadMore() async {
        let fake = FakePartyListService()
        fake.responses = [
            .delayThenSuccess([.mock(id: "1")], delayNanos: 100_000_000),
            .success([.mock(id: "2")])
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        // loading 时立即 loadMore
        XCTAssertEqual(store.state, .loading)
        store.loadMore()
        // loadMore 应 no-op（state 仍 loading）
        XCTAssertEqual(store.state, .loading)

        await waitForState(store)
        // 只调 1 次 service
        XCTAssertEqual(fake.calls.count, 1)
    }

    /// R-6a: loadingMore 中 refresh 强夺（cancel 旧 task + 重置）
    ///
    /// 竞态说明：Task.cancel() 在 checkCancellation 之前设置 flag。若 loadMore 后立即 refresh
    /// 而 2 号 task 还没跑到 Fake body（未 append call），3 号 task 在 Fake 内会拿"下一个 response"
    /// 而错过 delayThenSuccess。测试用 `await Task.yield()` 强制让 2 号 task 先入 Fake body 完成
    /// call 记录，再 refresh 触发 cancel。
    func test_refresh_preemptsLoadingMore() async {
        let fake = FakePartyListService()
        fake.responses = [
            .success((0..<20).map { .mock(id: "p1-\($0)") }),   // startInitial
            .delayThenSuccess((0..<5).map { .mock(id: "p2-\($0)") }, delayNanos: 500_000_000),  // 慢分页
            .success([.mock(id: "refreshed")])                    // refresh 拉到新首页
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        store.loadMore()
        XCTAssertEqual(store.state, .loadingMore(rooms: (0..<20).map { .mock(id: "p1-\($0)") }))

        // 关键：让 2 号 task 有机会进入 Fake body 完成 call append + 开始 sleep
        // 否则 3 号 task 在 Fake 里会 idx=1 而不是 idx=2（见测试注释）
        for _ in 0..<5 { await Task.yield() }

        // 立即强夺 —— refresh 应 cancel 分页 task
        store.refresh()
        // list-refresh-preserve-items rule：从 loadingMore(rooms) 走 refresh 应进入 refreshing(rooms) 保留视觉
        XCTAssertEqual(store.state, .refreshing(rooms: (0..<20).map { .mock(id: "p1-\($0)") }))

        await waitForState(store)
        guard case .loaded(let items, _) = store.state else {
            return XCTFail("expected loaded after refresh")
        }
        // 应看到 refresh 拉到的数据（不是分页拉到的）
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].stableListId, "id_refreshed")
    }

    /// R-6b: error 状态 double-tap retry → 忽略重复调用
    func test_error_doubleTapRetry_singleCall() async {
        let fake = FakePartyListService()
        fake.responses = [
            .throwing(PartyListServicePreviewFakeError.networkError),
            .delayThenSuccess([.mock(id: "1")], delayNanos: 200_000_000),
            .success([.mock(id: "2")])  // 兜底
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)
        guard case .error = store.state else {
            return XCTFail("expected error")
        }

        // 第一次 retry 触发新 task；第二次立刻打点应因 state 已切 .loading → guard 拒绝
        store.retry()
        XCTAssertEqual(store.state, .loading)
        store.retry() // guard case .error 拒绝
        XCTAssertEqual(store.state, .loading)

        await waitForState(store)
        // 只应有 2 次调用（首拉 + 一次 retry）
        XCTAssertEqual(fake.calls.count, 2)
    }

    /// error → refresh：语义等价 retry；因 error 态无 rooms 可保留，仍走 loading
    func test_refresh_fromError_triggersLoading() async {
        let fake = FakePartyListService()
        fake.responses = [
            .throwing(PartyListServicePreviewFakeError.networkError),
            .success([.mock(id: "1")])
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)
        guard case .error = store.state else {
            return XCTFail("expected error")
        }

        store.refresh()
        // error 态无 rooms → refresh 走 loading 合理（list-refresh-preserve-items rule 例外）
        XCTAssertEqual(store.state, .loading)
        await waitForState(store)

        guard case .loaded(let items, _) = store.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertEqual(items.count, 1)
    }

    /// pageError → refresh 重新从首页拉（弃已有 rooms）
    func test_refresh_fromPageError_resetsAndReloads() async {
        let fake = FakePartyListService()
        fake.responses = [
            .success((0..<20).map { .mock(id: "p1-\($0)") }),
            .throwing(PartyListServicePreviewFakeError.networkError),
            .success([.mock(id: "fresh")])
        ]

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        store.loadMore()
        await waitForState(store)
        guard case .pageError = store.state else {
            return XCTFail("expected pageError")
        }

        store.refresh()
        // list-refresh-preserve-items rule：pageError(rooms) → refresh 应保留 rooms 视觉走 refreshing
        XCTAssertEqual(store.state, .refreshing(rooms: (0..<20).map { .mock(id: "p1-\($0)") }))
        await waitForState(store)

        guard case .loaded(let items, _) = store.state else {
            return XCTFail("expected loaded, got \(store.state)")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].stableListId, "id_fresh")
    }

    // MARK: - 参数透传

    /// languageCode provider 值应传给 service
    func test_serviceCall_transmitsLanguageCode() async {
        let fake = FakePartyListService()
        fake.responses = [.success([])]

        let store = PartyListStore(
            service: fake,
            pageSize: 20,
            languageCodeProvider: { "ar" }
        )
        store.startInitial()
        await waitForState(store)

        XCTAssertEqual(fake.calls.first?.languageCode, "ar")
        XCTAssertEqual(fake.calls.first?.pageSize, 20)
        XCTAssertEqual(fake.calls.first?.version, "v2")
    }

    // MARK: - 边界：hasMore=false 时 loadMore 忽略

    /// loaded 且 hasMore=false 时 loadMore → no-op
    func test_loadMore_whenNoMore_ignored() async {
        let fake = FakePartyListService()
        fake.responses = [.success([.mock(id: "1")])]  // 一页只 1 条 → hasMore=false

        let store = PartyListStore(service: fake, pageSize: 20)
        store.startInitial()
        await waitForState(store)

        store.loadMore()
        // 应仍 loaded，不进 loadingMore
        guard case .loaded = store.state else {
            return XCTFail("expected loaded still")
        }
        XCTAssertEqual(fake.calls.count, 1) // 无第二次调用
    }

    // MARK: - Test Helpers

    /// 等待 async 任务完成。策略：轮询直到 state 稳定（不再变化）。
    /// 因每个测试都是短序列，最长等 3s。
    private func waitForState(_ store: PartyListStore, timeout: TimeInterval = 3.0) async {
        // 让 Store 内部 Task 至少调度一次
        for _ in 0..<300 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            // state 不再是 loading/loadingMore → 认为稳定
            switch store.state {
            case .idle, .loaded, .error, .pageError:
                return
            case .loading, .loadingMore, .refreshing:
                continue
            }
        }
    }
}
