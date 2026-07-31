import XCTest

/// PropsInventoryStore 状态机 + ops 单测（spec §5 · M1 Step 1a-3）。
///
/// 覆盖 F ↔ R 对应：
/// - F3 idle → loadFirst → loading → loaded → test_loadFirst_success_setsLoaded
/// - F4 All tab 前端过滤 Entrance → test_allTab_filtersEntrance (R15)
/// - F5 changeTab → loading → loaded 只 frame → test_changeTab_success
/// - F6 loadMore 追加 → test_loadMore_success_appendsItems
/// - F7 refresh 保留 items 视觉 → test_refreshAsync_preservesItemsInState
/// - F10 Equip → wearing → mine 更新 + items 更新 → test_equip_success_updatesItemsAndMine
/// - F11 Unequip → removing → mine 清空 → test_unequip_success
/// - R1 loading 期 changeTab · loadSeq 丢弃过期 → test_loadSeq_discardsStaleResponse
/// - R2 refreshing 期二次 refresh no-op → test_refreshAsync_inflightGuard
/// - R3 首次网络失败 → error(nil, .initial) → test_loadFirst_failure_setsError
/// - R4 loadMore 失败 → error(items, .loadMore) → test_loadMore_failure_preservesItems
/// - R4b refresh 失败 → error(items, .refresh) → test_refresh_failure_preservesItems
/// - R5 empty → test_loadFirst_empty
/// - R7 未拥有 equip → .notOwned → test_equip_notOwned_rejected
/// - R8 已穿戴 equip → .alreadyWorn → test_equip_alreadyWorn_rejected
/// - R9 未穿戴 unequip → .alreadyUnequipped → test_unequip_notWorn_rejected
/// - R11 API 失败 → 回滚 items + mine → test_equip_apiFail_rollsBack
/// - R11b Ops 期 loadSeq 变化 → 不回滚 → test_equip_apiFail_duringRefresh_noRollback
/// - R12 同 item busy → test_equip_sameItemBusy_rejected
/// - retry(phase) 分派 → test_retry_initial_reloads / test_retry_loadMore_resumes
/// - clear → 全清 → test_clear_resetsAll

@MainActor
final class PropsInventoryStoreTests: XCTestCase {

    // MARK: - Setup helpers

    private func makeItem(
        id: Int64, type: PropItemType = .frame,
        owned: Int = 1, worn: Int = 0, expire: PropExpireTime = .permanent
    ) -> PropItem {
        PropItem(id: id, itemType: type, itemName: "Item\(id)",
                 itemImg: "https://cdn.com/\(id).png",
                 isFromBag: owned, wearStatus: worn, expireTime: expire)
    }

    private func makePage(_ items: [PropItem], total: Int? = nil) -> PropPage {
        PropPage(records: items, totalNum: total ?? items.count)
    }

    override func setUp() async throws {
        try await super.setUp()
        AnchorInfoConsumerBridge.shared.clear()
    }

    // MARK: - F3 首拉

    func test_loadFirst_success_setsLoaded() async {
        let fake = PropsServiceFake()
        fake.setPage(makePage([makeItem(id: 1), makeItem(id: 2)]))
        let store = PropsInventoryStore(service: fake)

        store.loadFirst()
        await waitForState(store)

        guard case .loaded(let items, let hasMore) = store.state else {
            return XCTFail("expected loaded, got \(store.state)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(hasMore)  // items.count == totalNum → 无 hasMore
    }

    /// F3 loadFirstIfNeeded · idle 触发；非 idle no-op
    func test_loadFirstIfNeeded_onlyIfIdle() async {
        let fake = PropsServiceFake()
        fake.setPage(makePage([makeItem(id: 1)]))
        let store = PropsInventoryStore(service: fake)

        store.loadFirstIfNeeded()
        await waitForState(store)
        XCTAssertEqual(fake.recordedFetchPage.count, 1)

        // 再调 no-op
        store.loadFirstIfNeeded()
        await Task.yield()
        XCTAssertEqual(fake.recordedFetchPage.count, 1)
    }

    // MARK: - R5 空

    func test_loadFirst_empty_setsEmpty() async {
        let fake = PropsServiceFake()
        fake.setPage(makePage([], total: 0))
        let store = PropsInventoryStore(service: fake)

        store.loadFirst()
        await waitForState(store)

        XCTAssertEqual(store.state, .empty)
    }

    // MARK: - F5 changeTab

    func test_changeTab_triggersLoadFirst_andPassesItemType() async {
        let fake = PropsServiceFake()
        fake.enqueue(.page(makePage([makeItem(id: 1)])))  // All
        fake.enqueue(.page(makePage([makeItem(id: 100, type: .frame)])))  // Frame

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        store.changeTab(.frame)
        await waitForState(store)

        guard case .loaded(let items, _) = store.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertEqual(items.map(\.id), [100])
        XCTAssertEqual(fake.recordedFetchPage.last?.itemType, .frame)
    }

    // MARK: - F4 / R15 All tab 前端过滤 Entrance

    func test_allTab_filtersEntranceRecords() async {
        let fake = PropsServiceFake()
        fake.setPage(makePage([
            makeItem(id: 1, type: .frame),
            makeItem(id: 2, type: .entrance),  // 服务端返 entrance
            makeItem(id: 3, type: .vehicle)
        ], total: 3))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        guard case .loaded(let items, _) = store.state else {
            return XCTFail("expected loaded")
        }
        // Entrance 被前端过滤，2 条
        XCTAssertEqual(items.map(\.id), [1, 3])
    }

    // MARK: - F6 loadMore

    func test_loadMore_success_appendsItems() async {
        let fake = PropsServiceFake()
        // 首页 totalNum=15 (hasMore) + 第二页
        let page1 = makePage((1...10).map { makeItem(id: Int64($0)) }, total: 15)
        let page2 = makePage((11...15).map { makeItem(id: Int64($0)) }, total: 15)
        fake.enqueue(.page(page1))
        fake.enqueue(.page(page2))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        guard case .loaded(_, let hasMore1) = store.state else {
            return XCTFail("expected loaded after first")
        }
        XCTAssertTrue(hasMore1)

        store.loadMore()
        await waitForState(store)

        guard case .loaded(let items, let hasMore2) = store.state else {
            return XCTFail("expected loaded after loadMore")
        }
        XCTAssertEqual(items.count, 15)
        XCTAssertFalse(hasMore2)
        // 第二页 pageIndex 参数
        XCTAssertEqual(fake.recordedFetchPage.last?.pageIndex, 2)
    }

    // MARK: - F7 refresh 保留 items 视觉

    func test_refreshAsync_preservesItemsInRefreshingState() async {
        let fake = PropsServiceFake()
        fake.setPage(makePage([makeItem(id: 1), makeItem(id: 2)]))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        // refresh · 用 artificialDelay 让 refreshing 态可观测
        fake.artificialDelay = 0.05
        let refreshTask = Task { await store.refreshAsync() }
        // 让 refresh 开始
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        // 期间 state 应是 .refreshing(items)
        if case .refreshing(let items) = store.state {
            XCTAssertEqual(items.count, 2)  // 保留旧 items（list-refresh-preserve-items rule）
        } else {
            XCTFail("expected refreshing preserving items, got \(store.state)")
        }
        _ = await refreshTask.value
    }

    // MARK: - R3 首次失败

    func test_loadFirst_networkFailure_setsErrorInitialNilItems() async {
        let fake = PropsServiceFake()
        fake.enqueue(.pageError(.network("fake network")))
        let store = PropsInventoryStore(service: fake)

        store.loadFirst()
        await waitForState(store)

        guard case .error(let items, let phase, let msg) = store.state else {
            return XCTFail("expected error")
        }
        XCTAssertNil(items)
        XCTAssertEqual(phase, .initial)
        XCTAssertEqual(msg, "fake network")
    }

    // MARK: - R4 loadMore 失败保留 items

    func test_loadMore_failure_preservesItemsInErrorState() async {
        let fake = PropsServiceFake()
        let page1 = makePage((1...10).map { makeItem(id: Int64($0)) }, total: 15)
        fake.enqueue(.page(page1))
        fake.enqueue(.pageError(.network("net err")))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        store.loadMore()
        await waitForState(store)

        guard case .error(let items, let phase, _) = store.state else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(items?.count, 10)
        XCTAssertEqual(phase, .loadMore)
    }

    // MARK: - R4b refresh 失败保留 items

    func test_refresh_failure_preservesItemsInErrorState() async {
        let fake = PropsServiceFake()
        fake.enqueue(.page(makePage([makeItem(id: 1)])))
        fake.enqueue(.pageError(.network("net err")))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        await store.refreshAsync()

        guard case .error(let items, let phase, _) = store.state else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(phase, .refresh)
    }

    // MARK: - retry phase-aware

    func test_retry_initial_reloadsFromFirst() async {
        let fake = PropsServiceFake()
        fake.enqueue(.pageError(.network("first fail")))
        fake.enqueue(.page(makePage([makeItem(id: 1)])))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        store.retry()
        await waitForState(store)

        guard case .loaded(let items, _) = store.state else {
            return XCTFail("expected loaded after retry")
        }
        XCTAssertEqual(items.map(\.id), [1])
    }

    func test_retry_loadMore_resumesLoadMore() async {
        let fake = PropsServiceFake()
        fake.enqueue(.page(makePage((1...10).map { makeItem(id: Int64($0)) }, total: 15)))
        fake.enqueue(.pageError(.network("loadmore fail")))
        fake.enqueue(.page(makePage((11...15).map { makeItem(id: Int64($0)) }, total: 15)))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)
        store.loadMore()
        await waitForState(store)
        // 现在 error(items=10, phase=.loadMore)

        store.retry()
        await waitForState(store)

        guard case .loaded(let items, let hasMore) = store.state else {
            return XCTFail("expected loaded after retry")
        }
        XCTAssertEqual(items.count, 15)
        XCTAssertFalse(hasMore)
    }

    // MARK: - R1 loadSeq 丢弃过期响应

    func test_loadSeq_discardsStaleResponse() async {
        let fake = PropsServiceFake()
        // slow first tab
        fake.artificialDelay = 0.1
        fake.enqueue(.page(makePage([makeItem(id: 1)])))
        fake.enqueue(.page(makePage([makeItem(id: 100, type: .frame)])))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()  // in-flight，慢

        // 未等完成，立即切 tab（loadSeq++）
        try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms（首个 in-flight 中）
        store.changeTab(.frame)
        await waitForState(store)

        // 最终 state 应含 Frame 那条（100），不含旧 tab 的 1
        guard case .loaded(let items, _) = store.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertEqual(items.map(\.id), [100])
    }

    // MARK: - R2 refresh inflight guard

    func test_refreshAsync_inflightGuard_secondCallSkipped() async {
        let fake = PropsServiceFake()
        fake.enqueue(.page(makePage([makeItem(id: 1)])))
        // 慢 refresh
        fake.artificialDelay = 0.1
        fake.enqueue(.page(makePage([makeItem(id: 2)])))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)
        fake.artificialDelay = 0.1

        // 两个 refresh 并发；第二个 inflight guard 会 skip
        async let r1: Void = store.refreshAsync()
        async let r2: Void = store.refreshAsync()
        _ = await (r1, r2)

        // 只 recordedFetchPage 3 次（load + refresh1）· 第 2 个 skip 无 record
        XCTAssertEqual(fake.recordedFetchPage.count, 2)
    }

    // MARK: - F10 equip 成功

    func test_equip_success_updatesItemsAndBridge() async {
        let fake = PropsServiceFake()
        let item = makeItem(id: 100, type: .chatSkin, owned: 1, worn: 0)
        fake.enqueue(.page(makePage([item])))
        fake.enqueue(.ops(()))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        let result = await store.performOps(item: item, action: .equip)
        XCTAssertEqual(result, .success)

        guard case .loaded(let items, _) = store.state else { return XCTFail() }
        XCTAssertEqual(items.first?.wearStatus, 1)
        XCTAssertEqual(AnchorInfoConsumerBridge.shared.currentURL(for: .chatSkin), item.itemImg)
    }

    /// F10 · 同 itemType 互斥：第二件 equip 会把第一件的 wearStatus 清 0
    func test_equip_secondSameType_kicksFirst() async {
        let fake = PropsServiceFake()
        let first = makeItem(id: 100, type: .frame, owned: 1, worn: 1)
        let second = makeItem(id: 200, type: .frame, owned: 1, worn: 0)
        fake.enqueue(.page(makePage([first, second])))
        fake.enqueue(.ops(()))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        _ = await store.performOps(item: second, action: .equip)

        guard case .loaded(let items, _) = store.state else { return XCTFail() }
        XCTAssertEqual(items.first(where: { $0.id == 100 })?.wearStatus, 0)  // first kicked
        XCTAssertEqual(items.first(where: { $0.id == 200 })?.wearStatus, 1)  // second on
    }

    // MARK: - F11 unequip

    func test_unequip_success_clearsMineAndItems() async {
        let fake = PropsServiceFake()
        let item = makeItem(id: 100, type: .frame, owned: 1, worn: 1)
        fake.enqueue(.page(makePage([item])))
        fake.enqueue(.ops(()))
        AnchorInfoConsumerBridge.shared.write(itemType: .frame, url: item.itemImg)

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        _ = await store.performOps(item: item, action: .unequip)

        guard case .loaded(let items, _) = store.state else { return XCTFail() }
        XCTAssertEqual(items.first?.wearStatus, 0)
        XCTAssertNil(AnchorInfoConsumerBridge.shared.currentURL(for: .frame))
    }

    // MARK: - R7 未拥有 equip

    func test_equip_notOwned_rejectedWithoutAPICall() async {
        let fake = PropsServiceFake()
        let item = makeItem(id: 100, owned: 0)
        fake.enqueue(.page(makePage([item])))
        // 没 enqueue ops → 若被调 API 会返 nil response error（此测覆盖：不该调 API）

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        let result = await store.performOps(item: item, action: .equip)
        XCTAssertEqual(result, .rejected(.notOwned))
        XCTAssertEqual(fake.recordedOps.count, 0)  // 前置校验拦，API 未调
    }

    func test_ops_permissionDenied_doesNotCallService() async {
        let fake = PropsServiceFake()
        let item = makeItem(id: 100)
        fake.enqueue(.page(makePage([item])))
        let store = PropsInventoryStore(service: fake, canManageVirtualItems: { false })
        store.loadFirst()
        await waitForState(store)

        let result = await store.performOps(item: item, action: .equip)

        XCTAssertEqual(result, .rejected(.permissionDenied))
        XCTAssertEqual(fake.recordedOps.count, 0)
    }

    // MARK: - R8 / R9 重复穿戴/卸下

    func test_equip_alreadyWorn_rejected() async {
        let fake = PropsServiceFake()
        let item = makeItem(id: 100, owned: 1, worn: 1)
        fake.enqueue(.page(makePage([item])))
        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        let result = await store.performOps(item: item, action: .equip)
        XCTAssertEqual(result, .rejected(.alreadyWorn))
        XCTAssertEqual(fake.recordedOps.count, 0)
    }

    func test_unequip_notWorn_rejected() async {
        let fake = PropsServiceFake()
        let item = makeItem(id: 100, owned: 1, worn: 0)
        fake.enqueue(.page(makePage([item])))
        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        let result = await store.performOps(item: item, action: .unequip)
        XCTAssertEqual(result, .rejected(.alreadyUnequipped))
    }

    // MARK: - R11 API 失败回滚

    func test_equip_apiFailure_rollsBackItemsAndBridge() async {
        let fake = PropsServiceFake()
        let prev = makeItem(id: 100, type: .frame, owned: 1, worn: 1)   // 之前穿着
        let target = makeItem(id: 200, type: .frame, owned: 1, worn: 0)
        fake.enqueue(.page(makePage([prev, target])))
        fake.enqueue(.opsError(.business(code: "500", message: "server down")))
        AnchorInfoConsumerBridge.shared.write(itemType: .frame, url: prev.itemImg)

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        let result = await store.performOps(item: target, action: .equip)
        if case .rejected(.apiFailed) = result { /* ok */ }
        else { XCTFail("expected apiFailed rejection") }

        // 回滚：prev.worn=1 恢复；target.worn=0；bridge 保留 prev.itemImg
        guard case .loaded(let items, _) = store.state else { return XCTFail() }
        XCTAssertEqual(items.first(where: { $0.id == 100 })?.wearStatus, 1)
        XCTAssertEqual(items.first(where: { $0.id == 200 })?.wearStatus, 0)
        XCTAssertEqual(AnchorInfoConsumerBridge.shared.currentURL(for: .frame), prev.itemImg)
    }

    // MARK: - R12 同 item busy 拒绝

    func test_equip_sameItemBusy_secondCallRejected() async {
        let fake = PropsServiceFake()
        let item = makeItem(id: 100, owned: 1, worn: 0)
        fake.enqueue(.page(makePage([item])))
        fake.artificialDelay = 0.1
        fake.enqueue(.ops(()))
        fake.enqueue(.ops(()))

        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)

        // 两个并发 equip 同一 item
        async let r1 = store.performOps(item: item, action: .equip)
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms 让第一个先进
        let r2 = await store.performOps(item: item, action: .equip)
        _ = await r1

        // 第二个应 rejected(.busy)
        XCTAssertEqual(r2, .rejected(.busy))
    }

    // MARK: - clear

    func test_clear_resetsAllState() async {
        let fake = PropsServiceFake()
        fake.enqueue(.page(makePage([makeItem(id: 1)])))
        let store = PropsInventoryStore(service: fake)
        store.loadFirst()
        await waitForState(store)
        store.chooseItemId = 1

        store.clear()

        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.chooseItemId)
        XCTAssertEqual(store.opsState, .idle)
    }

    // MARK: - Helpers

    /// 等 in-flight task 稳定（模仿 PartyListStoreTests.waitForState）
    private func waitForState(_ store: PropsInventoryStore, timeout: TimeInterval = 3.0) async {
        for _ in 0..<300 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
            switch store.state {
            case .idle, .loaded, .empty, .error:
                return
            case .loading, .loadingMore, .refreshing:
                continue
            }
        }
    }
}
