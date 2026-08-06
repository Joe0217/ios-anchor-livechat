import XCTest
import Combine

/// H-1 spec §3.3 反向 R-1/R-3/R-4 + 正向状态机 Store 层单测。
@MainActor
final class MessageSessionStoreTests: XCTestCase {

    // MARK: - Test factory

    private func makeStore(sessions: [MessageSession] = [],
                           prime: Set<String> = [],
                           fetchError: Error? = nil,
                           stickTopError: Error? = nil,
                           deleteError: Error? = nil)
        -> (MessageSessionStore, FakeMessageSessionProvider, FakePrimeLevelProvider) {
        let provider = FakeMessageSessionProvider()
        provider.stubSessions = fetchError.map { .failure($0) } ?? .success(sessions)
        if let err = stickTopError { provider.stubStickTop = .failure(err) }
        if let err = deleteError { provider.stubDelete = .failure(err) }

        let primeProvider = FakePrimeLevelProvider()
        primeProvider.stubPrime = prime

        let store = MessageSessionStore(
            provider: provider,
            primeProvider: primeProvider,
            stationProvider: FakeStationListProvider(),
            customerServiceStore: FakeCustomerServiceIdStore(),
            profileProvider: FakeConversationProfileProvider(),
            followProvider: FakeFollowUserListProvider()
        )
        return (store, provider, primeProvider)
    }

    // MARK: - 正向状态机

    func test_initial_state_idle() {
        let (store, _, _) = makeStore()
        XCTAssertEqual(store.state, .idle)
    }

    func test_load_success_transitions_to_loaded() async {
        let s = MessageSessionFactory.make(id: "u1")
        let (store, _, _) = makeStore(sessions: [s])
        await store.load()
        guard case .loaded(let all) = store.state else { return XCTFail("expect loaded") }
        XCTAssertEqual(all.map(\.id), ["u1"])
    }

    func test_load_success_empty_stays_loaded_with_empty_array() async {
        let (store, _, _) = makeStore(sessions: [])
        await store.load()
        XCTAssertEqual(store.state, .loaded([]))
    }

    func test_load_failure_transitions_to_error() async {
        let (store, _, _) = makeStore(fetchError: FakeError.network)
        await store.load()
        guard case .error = store.state else { return XCTFail("expect error") }
    }

    func test_retry_recovers_after_error() async {
        let (store, provider, _) = makeStore(fetchError: FakeError.network)
        await store.load()
        guard case .error = store.state else { return XCTFail("expect error") }

        provider.stubSessions = .success([MessageSessionFactory.make(id: "u1")])
        await store.retry()
        guard case .loaded = store.state else { return XCTFail("expect loaded after retry") }
    }

    // MARK: - R-1: Prime 拉取失败仅 Prime tab 空，Flame/Stranger 不受影响

    func test_prime_fetch_failure_prime_empty_flame_stranger_intact() async {
        let flame = MessageSessionFactory.make(id: "flame", ext: MessageSessionExt(
            receivedGift: true, called: false, received: false, sended: false))
        let str = MessageSessionFactory.make(id: "str", ext: .empty)
        // FakePrimeLevelProvider stubPrime 为空 → 模拟 Prime 全失败降级
        let (store, _, _) = makeStore(sessions: [flame, str], prime: [])
        await store.load()

        XCTAssertEqual(store.primeUidSet, [], "Prime uid 集合应为空")
        XCTAssertEqual(store.sessions(in: .flame).map(\.id), ["flame"], "Flame 不受影响")
        XCTAssertEqual(store.sessions(in: .stranger).map(\.id), ["str"], "Stranger 不受影响")
        XCTAssertEqual(store.sessions(in: .prime), [], "Prime tab 空")
    }

    // MARK: - R-3-a: NIM delegate 与 loading 并发（入队 + loaded 后合并）

    func test_delegate_update_during_loading_enqueued_and_merged() async {
        let (store, provider, _) = makeStore(sessions: [])
        // fetchAll 挂起等 resumeFetch，精确复现 loading 期间窗口
        provider.fetchSuspends = true

        let loadTask = Task { await store.load() }
        // 让 loadTask 跑到 fetchAll 内部挂起点
        await Task.yield()

        // 此刻 state 应为 .loading，emit 的事件应入 pendingUpdates
        XCTAssertEqual(store.state, .loading)
        let s = MessageSessionFactory.make(id: "u1")
        provider.emit(.add(s))

        // 释放 fetch，loaded 后应合并 pendingUpdates
        provider.resumeFetch()
        await loadTask.value

        guard case .loaded(let all) = store.state else { return XCTFail("expect loaded") }
        XCTAssertTrue(all.contains(where: { $0.id == "u1" }),
                      "loading 期间入队的 .add 事件应在 loaded 后合并到列表")
    }

    func test_delegate_event_after_loaded_applies_directly() async {
        let (store, provider, _) = makeStore(sessions: [MessageSessionFactory.make(id: "u1")])
        await store.load()

        let updated = MessageSessionFactory.make(id: "u1", nickname: "new-name")
        provider.emit(.update(updated))

        guard case .loaded(let all) = store.state else { return XCTFail("expect loaded") }
        XCTAssertEqual(all.first(where: { $0.id == "u1" })?.peerNickname, "new-name")
    }

    func test_delegate_remove_after_loaded_removes_from_list() async {
        let (store, provider, _) = makeStore(sessions: [MessageSessionFactory.make(id: "u1")])
        await store.load()

        provider.emit(.remove(sessionId: "u1"))
        guard case .loaded(let all) = store.state else { return XCTFail("expect loaded") }
        XCTAssertFalse(all.contains(where: { $0.id == "u1" }))
    }

    // MARK: - 107: P2P 权限热撤销

    func test_suspended_p2p_store_ignores_nim_reconnect_and_delegate_events() async {
        let provider = FakeMessageSessionProvider()
        provider.stubSessions = .success([MessageSessionFactory.make(id: "u1")])
        let store = MessageSessionStore(
            provider: provider,
            primeProvider: FakePrimeLevelProvider(),
            stationProvider: FakeStationListProvider(),
            customerServiceStore: FakeCustomerServiceIdStore(),
            profileProvider: FakeConversationProfileProvider(),
            followProvider: FakeFollowUserListProvider()
        )

        // 先复现请求已发出、但结果尚未返回的窗口。107 热撤权后不能由迟到结果写回会话。
        provider.fetchSuspends = true
        let loadTask = Task { await store.load() }
        await Task.yield()
        XCTAssertEqual(store.state, .loading)

        store.setDirectMessagesCapabilityEnabled(false)
        XCTAssertEqual(store.state, .idle, "撤销 P2P 权限应立即清空会话数据")
        provider.resumeFetch()
        await loadTask.value
        XCTAssertEqual(store.state, .idle, "撤权前已发出的请求也不能把会话重新写回")

        provider.emit(.add(MessageSessionFactory.make(id: "u2")))
        provider.connectionStateSubject.value = true
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(store.state, .idle, "撤权后 NIM 增量和重连均不可重新加载 P2P 会话")

        store.setDirectMessagesCapabilityEnabled(true)
        for _ in 0..<6 { await Task.yield() }
        guard case .loaded(let sessions) = store.state else {
            return XCTFail("恢复 P2P 权限且 IM 已同步后应重新加载")
        }
        XCTAssertEqual(sessions.map(\.id), ["u1"])
    }

    // MARK: - R-8: IM 未登录时 fetch 空 → 登录后自动重试（Step 3 反悔 #1）

    func test_load_deferred_when_im_not_connected_and_auto_loads_after_connect() async {
        let provider = FakeMessageSessionProvider()
        // 初始未连接
        provider.connectionStateSubject.value = false
        provider.stubSessions = .success([MessageSessionFactory.make(id: "u1")])

        let primeProvider = FakePrimeLevelProvider()
        let store = MessageSessionStore(
            provider: provider,
            primeProvider: primeProvider,
            stationProvider: FakeStationListProvider(),
            customerServiceStore: FakeCustomerServiceIdStore(),
            profileProvider: FakeConversationProfileProvider(),
            followProvider: FakeFollowUserListProvider()
        )

        // 初始 idle
        XCTAssertEqual(store.state, .idle)

        // 触发连接建立
        provider.connectionStateSubject.value = true
        // 让 sink → Task { await load() } 跑起来（v4 引入 async let prime/profile 并发，需多次 yield）
        for _ in 0..<6 { await Task.yield() }

        guard case .loaded(let all) = store.state else {
            return XCTFail("expect loaded after connectionState=true, got \(store.state)")
        }
        XCTAssertEqual(all.map(\.id), ["u1"])
    }

    /// v4f 反悔 #5：切账号/重连 syncOK 到达时**无条件 reload**，覆盖 stale cache
    /// （原 v3 skip 逻辑导致切账号 store 单例残留旧 sessions + 陈旧 online 状态，重启 App 才 fresh）。
    func test_load_retriggers_on_reconnect_to_avoid_stale_cache() async {
        let provider = FakeMessageSessionProvider()
        provider.connectionStateSubject.value = true
        provider.stubSessions = .success([MessageSessionFactory.make(id: "u1")])

        let store = MessageSessionStore(
            provider: provider,
            primeProvider: FakePrimeLevelProvider(),
            stationProvider: FakeStationListProvider(),
            customerServiceStore: FakeCustomerServiceIdStore(),
            profileProvider: FakeConversationProfileProvider(),
            followProvider: FakeFollowUserListProvider()
        )
        await store.load()
        guard case .loaded(let first) = store.state, first.map(\.id) == ["u1"] else {
            return XCTFail("expect initial loaded [u1]")
        }

        // 模拟切账号 / 重连：disconnect → syncOK
        provider.connectionStateSubject.value = false
        provider.stubSessions = .success([
            MessageSessionFactory.make(id: "u1"),
            MessageSessionFactory.make(id: "u2"),
        ])
        provider.connectionStateSubject.value = true

        // sink 里 Task { @MainActor await load() } 需要多次 yield 推动 async let 并发点
        for _ in 0..<6 { await Task.yield() }

        // syncOK 到达无条件 reload → 应看到新数据 [u1, u2]
        guard case .loaded(let updated) = store.state else { return XCTFail() }
        XCTAssertEqual(Set(updated.map(\.id)), Set(["u1", "u2"]), "重连应触发 reload 拉到新数据（v4f 反悔 #5 修复）")
    }

    /// v5.3 修复（Q4 Prime 分类丢失）：primeUidSet 从非空 → 拉空时应保留旧值，
    /// 避免下拉刷新时 Prime API 拉失败（PrimeLevelService 失败降级为空 Set）→
    /// 之前分类 Prime 的 sessions 全部落 Stranger（Stranger 是分类兜底）。
    func test_load_preserves_prime_set_when_prime_fetch_returns_empty() async {
        let provider = FakeMessageSessionProvider()
        provider.connectionStateSubject.value = true
        let sessions = [
            MessageSessionFactory.make(id: "u1"),
            MessageSessionFactory.make(id: "u2"),
        ]
        provider.stubSessions = .success(sessions)

        let prime = FakePrimeLevelProvider()
        prime.stubPrime = ["u1"]   // u1 是 Prime

        let store = MessageSessionStore(
            provider: provider,
            primeProvider: prime,
            stationProvider: FakeStationListProvider(),
            customerServiceStore: FakeCustomerServiceIdStore(),
            profileProvider: FakeConversationProfileProvider(),
            followProvider: FakeFollowUserListProvider()
        )
        await store.load()
        XCTAssertEqual(store.primeUidSet, ["u1"], "初始 primeUidSet 应含 u1")

        // 模拟下拉刷新时 Prime API 失败 → fetchPrime 返空
        prime.stubPrime = []
        await store.load()

        // 期望：primeUidSet 保留 ["u1"] 不被空覆盖 → u1 仍归 Prime tab 不落 Stranger
        XCTAssertEqual(store.primeUidSet, ["u1"], "Prime 拉空时应保留缓存不覆盖（Q4 修复）")
    }

    /// v5.2 修复（Q3 IM 断连保护）：fetchAll 返空数组时应保留 loaded 非空的旧数据，
    /// 视为"IM 未就绪的假空"（allRecentSessions() 在 SDK 未登录时返空）；不覆盖清空 UI。
    func test_load_preserves_cache_when_fetch_returns_empty() async {
        let provider = FakeMessageSessionProvider()
        provider.connectionStateSubject.value = true
        provider.stubSessions = .success([MessageSessionFactory.make(id: "u1")])

        let store = MessageSessionStore(
            provider: provider,
            primeProvider: FakePrimeLevelProvider(),
            stationProvider: FakeStationListProvider(),
            customerServiceStore: FakeCustomerServiceIdStore(),
            profileProvider: FakeConversationProfileProvider(),
            followProvider: FakeFollowUserListProvider()
        )
        await store.load()
        guard case .loaded(let first) = store.state, first.map(\.id) == ["u1"] else {
            return XCTFail("expect initial loaded [u1]")
        }

        // 模拟 IM 断连 → fetchAll 返空
        provider.stubSessions = .success([])
        await store.load()

        // 期望：state 仍是 [u1]，未被空覆盖（下拉刷新在断连时不清空 UI）
        guard case .loaded(let preserved) = store.state else { return XCTFail("state 不再是 loaded") }
        XCTAssertEqual(preserved.map(\.id), ["u1"], "fetch 返空时应保留旧数据不覆盖")
    }

    /// v5.4 缓存审计补漏 G4：delete 联动清 conversationProfiles + primeUidSet 避免孤儿累积。
    /// applyEvents 里的 .remove case 也走同款处理（SDK 端 delegate 推 remove）。
    func test_delete_cleans_orphan_profile_and_prime() async {
        let provider = FakeMessageSessionProvider()
        provider.connectionStateSubject.value = true
        provider.stubSessions = .success([
            MessageSessionFactory.make(id: "u1"),
            MessageSessionFactory.make(id: "u2"),
        ])

        let prime = FakePrimeLevelProvider()
        prime.stubPrime = ["u1", "u2"]

        let profile = FakeConversationProfileProvider()
        profile.stubProfiles = [
            "u1": ConversationProfile(nickname: "Alice", icon: nil, onlineGroupStatus: 1),
            "u2": ConversationProfile(nickname: "Bob", icon: nil, onlineGroupStatus: 1),
        ]

        let store = MessageSessionStore(
            provider: provider,
            primeProvider: prime,
            stationProvider: FakeStationListProvider(),
            customerServiceStore: FakeCustomerServiceIdStore(),
            profileProvider: profile,
            followProvider: FakeFollowUserListProvider()
        )
        await store.load()
        // 前置断言：u1 的 profile + prime 都在
        XCTAssertNotNil(store.profile(for: "u1"))
        XCTAssertTrue(store.primeUidSet.contains("u1"))

        // 主动 delete u1
        await store.delete(sessionId: "u1")

        // 关键断言：u1 的孤儿 profile + prime 已联动清空
        XCTAssertNil(store.profile(for: "u1"), "delete 后 u1 profile 应被清")
        XCTAssertFalse(store.primeUidSet.contains("u1"), "delete 后 u1 应从 primeUidSet 剔除")
        // 未被删的 u2 不受影响
        XCTAssertNotNil(store.profile(for: "u2"))
        XCTAssertTrue(store.primeUidSet.contains("u2"))

        // SDK delegate .remove u2（走 applyEvents .remove 路径）—— 同款联动清
        // 关闭 IM 连接避免 sink 触发的 load() 重新拉回 u2 profile 干扰断言
        provider.connectionStateSubject.value = false
        provider.emit(.remove(sessionId: "u2"))
        // emit 是同步的（Fake handler 同步调 handleEvent），不需要 yield
        XCTAssertNil(store.profile(for: "u2"), "applyEvents .remove 后 u2 profile 应被清")
        XCTAssertFalse(store.primeUidSet.contains("u2"), "applyEvents .remove 后 u2 应从 primeUidSet 剔除")
    }

    // MARK: - R-4: 置顶失败回滚

    func test_pin_sdk_failure_rollback() async {
        let s = MessageSessionFactory.make(id: "u1", isTop: false)
        let (store, _, _) = makeStore(sessions: [s], stickTopError: FakeError.sdk)
        await store.load()

        await store.setStickTop(sessionId: "u1", isTop: true)

        guard case .loaded(let all) = store.state else { return XCTFail() }
        XCTAssertEqual(all.first?.isTop, false, "SDK 失败应回滚到原 isTop=false")
    }

    func test_pin_success_persists() async {
        let s = MessageSessionFactory.make(id: "u1", isTop: false)
        let (store, provider, _) = makeStore(sessions: [s])
        await store.load()

        await store.setStickTop(sessionId: "u1", isTop: true)

        guard case .loaded(let all) = store.state else { return XCTFail() }
        XCTAssertEqual(all.first?.isTop, true)
        XCTAssertEqual(provider.stickTopCalls.count, 1)
        XCTAssertEqual(provider.stickTopCalls.first?.sessionId, "u1")
        XCTAssertEqual(provider.stickTopCalls.first?.isTop, true)
    }

    // MARK: - 删除

    func test_delete_success_removes_from_list() async {
        let s = MessageSessionFactory.make(id: "u1")
        let (store, provider, _) = makeStore(sessions: [s])
        await store.load()

        await store.delete(sessionId: "u1")

        guard case .loaded(let all) = store.state else { return XCTFail() }
        XCTAssertTrue(all.isEmpty)
        XCTAssertEqual(provider.deleteCalls, ["u1"])
    }

    func test_delete_sdk_failure_rollback() async {
        let s = MessageSessionFactory.make(id: "u1")
        let (store, _, _) = makeStore(sessions: [s], deleteError: FakeError.sdk)
        await store.load()

        await store.delete(sessionId: "u1")

        guard case .loaded(let all) = store.state else { return XCTFail() }
        XCTAssertEqual(all.map(\.id), ["u1"], "SDK 失败应回滚保留 session")
    }

    // MARK: - 分类过滤 + 排序

    func test_sessions_in_category_sorted_by_isTop_then_timestamp() async {
        let s1 = MessageSessionFactory.make(id: "s1", timestamp: 100,
            ext: MessageSessionExt(receivedGift: true, called: false, received: false, sended: false))
        let s2Top = MessageSessionFactory.make(id: "s2", timestamp: 50, isTop: true,
            ext: MessageSessionExt(receivedGift: true, called: false, received: false, sended: false))
        let s3 = MessageSessionFactory.make(id: "s3", timestamp: 200,
            ext: MessageSessionExt(receivedGift: true, called: false, received: false, sended: false))

        let (store, _, _) = makeStore(sessions: [s1, s2Top, s3])
        await store.load()

        let flame = store.sessions(in: .flame)
        XCTAssertEqual(flame.map(\.id), ["s2", "s3", "s1"], "isTop 先，然后时间戳降序")
    }

    // MARK: - v5.5 空闲清理机制（bubbly-leaping-comet plan）

    /// 规则 A：30 天陈旧清理（含"unread > 0 但超 30 天照清"）
    func test_cleanup_removes_stale_sessions_older_than_30d() async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day: Int64 = 24 * 3600 * 1000

        let old1 = MessageSessionFactory.make(id: "old1", timestamp: now - 40 * day)
        let old2 = MessageSessionFactory.make(id: "old2", timestamp: now - 40 * day)
        // unread=1 但超 30 天 → 照清（用户明示"看不完就清"）
        let old3Unread = MessageSessionFactory.make(id: "old3", timestamp: now - 40 * day, unread: 1)
        let new1 = MessageSessionFactory.make(id: "new1", timestamp: now)
        let new2 = MessageSessionFactory.make(id: "new2", timestamp: now)

        let provider = FakeMessageSessionProvider()
        provider.connectionStateSubject.value = true
        provider.stubSessions = .success([old1, old2, old3Unread, new1, new2])
        let store = MessageSessionStore(
            provider: provider,
            primeProvider: FakePrimeLevelProvider(),
            stationProvider: FakeStationListProvider(),
            customerServiceStore: FakeCustomerServiceIdStore(),
            profileProvider: FakeConversationProfileProvider(),
            followProvider: FakeFollowUserListProvider()
        )
        await store.load()

        await store.performIdleCleanupWithProtection(activeCallPeerId: nil)

        guard case .loaded(let final) = store.state else { return XCTFail("state 不再是 loaded") }
        XCTAssertEqual(Set(final.map(\.id)), Set(["new1", "new2"]), "3 条超 30 天的应被清（含 unread=1 那条）")
        XCTAssertEqual(Set(provider.deleteCalls), Set(["old1", "old2", "old3"]), "SDK 层 delete 应被调 3 次")
    }

    /// 保护清单 6 条全命中的 40 天老会话应全部保留
    func test_cleanup_protects_top_system_prime_flame_call() async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day: Int64 = 24 * 3600 * 1000
        let old = now - 40 * day

        let topSession = MessageSessionFactory.make(id: "top1", timestamp: old, isTop: true)
        let primeSession = MessageSessionFactory.make(id: "prime1", timestamp: old)
        let notifSession = MessageSessionFactory.make(id: AppConfig.notificationYxAccId, timestamp: old)
        let customerSession = MessageSessionFactory.make(id: "customer1", timestamp: old)
        let flameSession = MessageSessionFactory.make(
            id: "flame1", timestamp: old,
            ext: MessageSessionExt(receivedGift: true, called: false, received: false, sended: false)
        )
        let callPeerSession = MessageSessionFactory.make(id: "callpeer1", timestamp: old)

        let provider = FakeMessageSessionProvider()
        provider.connectionStateSubject.value = true
        provider.stubSessions = .success([
            topSession, primeSession, notifSession, customerSession, flameSession, callPeerSession,
        ])
        let prime = FakePrimeLevelProvider()
        prime.stubPrime = ["prime1"]
        let customerStore = FakeCustomerServiceIdStore()
        customerStore.set("customer1")
        let store = MessageSessionStore(
            provider: provider,
            primeProvider: prime,
            stationProvider: FakeStationListProvider(),
            customerServiceStore: customerStore,
            profileProvider: FakeConversationProfileProvider(),
            followProvider: FakeFollowUserListProvider()
        )
        await store.load()

        await store.performIdleCleanupWithProtection(activeCallPeerId: "callpeer1")

        guard case .loaded(let final) = store.state else { return XCTFail("state 不再是 loaded") }
        let expected: Set<String> = [
            "top1", "prime1", AppConfig.notificationYxAccId, "customer1", "flame1", "callpeer1",
        ]
        XCTAssertEqual(Set(final.map(\.id)), expected, "6 条保护会话全部保留")
        XCTAssertTrue(provider.deleteCalls.isEmpty, "无 session 应被清")
    }

    /// 规则 B：250 条全部 10 天前（都未命中 A）→ B 因最旧 < 15 天 skip
    func test_cleanup_rule_b_skips_when_oldest_within_15d() async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day: Int64 = 24 * 3600 * 1000
        let sessions = (0..<250).map { i in
            MessageSessionFactory.make(id: "u\(i)", timestamp: now - 10 * day)
        }
        let provider = FakeMessageSessionProvider()
        provider.connectionStateSubject.value = true
        provider.stubSessions = .success(sessions)
        let store = MessageSessionStore(
            provider: provider,
            primeProvider: FakePrimeLevelProvider(),
            stationProvider: FakeStationListProvider(),
            customerServiceStore: FakeCustomerServiceIdStore(),
            profileProvider: FakeConversationProfileProvider(),
            followProvider: FakeFollowUserListProvider()
        )
        await store.load()

        await store.performIdleCleanupWithProtection(activeCallPeerId: nil)

        guard case .loaded(let final) = store.state else { return XCTFail("state 不再是 loaded") }
        XCTAssertEqual(final.count, 250, "全 10 天前不清（规则 A 不命中 + 规则 B 因最旧 <15d skip）")
        XCTAssertTrue(provider.deleteCalls.isEmpty, "无 SDK delete 调用")
    }

    func test_stationService_deniedAccessDoesNotInvokeLatestFetcher() async throws {
        var fetchCount = 0
        let service = StationListService(
            fetcher: {
                fetchCount += 1
                return [StationMail(id: "mail-1", mailTitle: "Notice", effectiveDate: "")]
            },
            accessGate: { false }
        )

        let latest = await service.fetchLatest()
        let list = try await service.fetchList(page: 1)
        XCTAssertNil(latest)
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(list, [])
    }

    func test_stationService_dropsLatestResultWhenAccessIsRevokedInFlight() async {
        var isAllowed = true
        let service = StationListService(
            fetcher: {
                isAllowed = false
                return [StationMail(id: "mail-1", mailTitle: "Notice", effectiveDate: "")]
            },
            accessGate: { isAllowed }
        )

        let latest = await service.fetchLatest()
        XCTAssertNil(latest)
    }
}
