import XCTest

/// trial #1 (A-spec §3.3 + §4/§5) — MomentFeedStore 状态机单测。
///
/// 覆盖 spec §4/§5 标"单测"项：
/// - §4.6 enterMoment 触发 .loadingFirst → .loaded
/// - §4.7a/b 加载成功 (数据流层面)
/// - §4.8 loadMore hasMore=true 触发翻页
/// - §4.9 / §4.10 tapLike 乐观更新双向
/// - §5.1 loadingFirst 失败 → .error
/// - §5.2 loadingFirst 空 → .loaded([], false)
/// - §5.3a hasMore=false 不重发
/// - §5.4 loadMore 失败 → .loadMoreError (posts 不抹掉)
/// - §5.9 切走 cancel inflight (结果丢弃)
/// - §5.10 切走 + 立即切回 (enterMoment idempotent，仅一次请求)
/// - §5.11 error 后 enterMoment 不自动 retry
/// - tapLike 按 postId 查表 (不按 index)
@MainActor
final class MomentFeedStoreTests: XCTestCase {

    // MARK: - Helpers

    /// 等待 state 满足条件，超时返回 false (调用方 XCTFail)
    private func waitFor(_ store: MomentFeedStore,
                         matching predicate: @escaping (MomentFeedStore.State) -> Bool,
                         timeout: TimeInterval = 1.0) async -> Bool {
        let start = Date()
        while !predicate(store.state) {
            if Date().timeIntervalSince(start) > timeout { return false }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms 轮询
        }
        return true
    }

    private func isLoaded(_ state: MomentFeedStore.State) -> Bool {
        if case .loaded = state { return true }
        return false
    }
    private func isError(_ state: MomentFeedStore.State) -> Bool {
        if case .error = state { return true }
        return false
    }
    private func isLoadMoreError(_ state: MomentFeedStore.State) -> Bool {
        if case .loadMoreError = state { return true }
        return false
    }

    // MARK: - §4.6 / §4.7 enterMoment 正向

    func test_enterMoment_fromIdle_transitionsToLoadingFirstThenLoaded() async {
        let fake = FakeCircleService()
        let post = TestPostFactory.make(postId: 1, likeFlag: 0, likeCount: 3)
        fake.getAllMomentsResult = .success(MomentPage(posts: [post], currentPage: 1, hasMore: true))
        let store = MomentFeedStore(service: fake, pageSize: 20)

        XCTAssertEqual(store.state, .idle)
        store.enterMoment()
        // .loadingFirst 立即出现 (state 设置在 await 前)
        if case .loadingFirst = store.state {} else { XCTFail("Expected .loadingFirst, got \(store.state)") }

        let ok = await waitFor(store, matching: isLoaded)
        XCTAssertTrue(ok, "Expected .loaded within timeout, got \(store.state)")
        XCTAssertEqual(store.state.posts.count, 1)
        XCTAssertTrue(store.state.hasMore)
        XCTAssertEqual(fake.getAllMomentsCalls.count, 1)
        XCTAssertEqual(fake.getAllMomentsCalls.first?.currentPage, 1)
    }

    // MARK: - §5.2 loadingFirst 空 → .loaded([], false)

    func test_enterMoment_emptyResponse_resultsInLoadedEmpty() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .success(MomentPage(posts: [], currentPage: 1, hasMore: false))
        let store = MomentFeedStore(service: fake, pageSize: 20)

        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)
        XCTAssertEqual(store.state.posts.count, 0)
        XCTAssertFalse(store.state.hasMore)
    }

    // MARK: - §5.1 loadingFirst 失败 → .error

    func test_enterMoment_apiError_transitionsToError() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .failure(TestError.timeout)
        let store = MomentFeedStore(service: fake, pageSize: 20)

        store.enterMoment()
        let ok = await waitFor(store, matching: isError)
        XCTAssertTrue(ok, "Expected .error within timeout, got \(store.state)")
    }

    // MARK: - §5.11 error 后 enterMoment 不自动 retry

    func test_enterMoment_whenError_doesNotAutoRetry() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .failure(TestError.offline)
        let store = MomentFeedStore(service: fake, pageSize: 20)

        store.enterMoment()
        _ = await waitFor(store, matching: isError)
        let callsAfterFirst = fake.getAllMomentsCalls.count

        // 切走再切回 (= 再次 enterMoment)
        store.cancelInflight()
        store.enterMoment()
        // 给一点时间看是否触发新请求
        try? await Task.sleep(nanoseconds: 50_000_000)

        if case .error = store.state {} else { XCTFail("Expected to stay .error, got \(store.state)") }
        XCTAssertEqual(fake.getAllMomentsCalls.count, callsAfterFirst, "enterMoment 在 .error 态不应触发新请求")
    }

    // MARK: - §4.8 loadMore hasMore=true 触发翻页

    func test_loadMore_whenHasMoreTrue_appendsPosts() async {
        let fake = FakeCircleService()
        let firstPage = MomentPage(
            posts: [TestPostFactory.make(postId: 1), TestPostFactory.make(postId: 2)],
            currentPage: 1, hasMore: true
        )
        fake.getAllMomentsResult = .success(firstPage)
        let store = MomentFeedStore(service: fake, pageSize: 2)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)
        XCTAssertEqual(store.state.posts.count, 2)

        // 切第二页结果再触底
        let secondPage = MomentPage(
            posts: [TestPostFactory.make(postId: 3), TestPostFactory.make(postId: 4)],
            currentPage: 2, hasMore: false
        )
        fake.getAllMomentsResult = .success(secondPage)
        store.loadMore()
        _ = await waitFor(store, matching: { state in
            if case .loaded(let posts, _) = state { return posts.count == 4 }
            return false
        })

        XCTAssertEqual(store.state.posts.count, 4)
        XCTAssertFalse(store.state.hasMore)
        XCTAssertEqual(fake.getAllMomentsCalls.count, 2)
        XCTAssertEqual(fake.getAllMomentsCalls[1].currentPage, 2)
    }

    // MARK: - §5.3a hasMore=false 不重发

    func test_loadMore_whenHasMoreFalse_doesNotSendRequest() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .success(MomentPage(posts: [TestPostFactory.make(postId: 1)],
                                                       currentPage: 1, hasMore: false))
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)
        let countBefore = fake.getAllMomentsCalls.count

        // 触底
        store.loadMore()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.getAllMomentsCalls.count, countBefore, "hasMore=false 时 loadMore 不应发请求")
    }

    // MARK: - §5.4 loadMore 失败 → .loadMoreError (posts 不抹掉)

    func test_loadMore_failure_keepsExistingPosts() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .success(MomentPage(
            posts: [TestPostFactory.make(postId: 1), TestPostFactory.make(postId: 2)],
            currentPage: 1, hasMore: true
        ))
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        fake.getAllMomentsResult = .failure(TestError.server(code: "9999"))
        store.loadMore()
        let ok = await waitFor(store, matching: isLoadMoreError)
        XCTAssertTrue(ok, "Expected .loadMoreError, got \(store.state)")
        XCTAssertEqual(store.state.posts.count, 2, "已加载的 posts 不应被抹掉")
    }

    // MARK: - retry from .error → .loadingFirst → .loaded

    func test_retry_fromError_resetsAndReloads() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .failure(TestError.timeout)
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isError)

        fake.getAllMomentsResult = .success(MomentPage(posts: [TestPostFactory.make(postId: 1)],
                                                       currentPage: 1, hasMore: false))
        store.retry()
        let ok = await waitFor(store, matching: isLoaded)
        XCTAssertTrue(ok, "retry 后应进入 .loaded, got \(store.state)")
        XCTAssertEqual(store.state.posts.count, 1)
    }

    // MARK: - retry from .loadMoreError → .loadingMore → .loaded (posts 拼接)

    func test_retry_fromLoadMoreError_appendsPosts() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .success(MomentPage(
            posts: [TestPostFactory.make(postId: 1)],
            currentPage: 1, hasMore: true
        ))
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        // loadMore 失败
        fake.getAllMomentsResult = .failure(TestError.server(code: "1"))
        store.loadMore()
        _ = await waitFor(store, matching: isLoadMoreError)
        XCTAssertEqual(store.state.posts.count, 1)

        // retry 成功
        fake.getAllMomentsResult = .success(MomentPage(
            posts: [TestPostFactory.make(postId: 2)],
            currentPage: 2, hasMore: false
        ))
        store.retry()
        _ = await waitFor(store, matching: { state in
            if case .loaded(let posts, _) = state { return posts.count == 2 }
            return false
        })
        XCTAssertEqual(store.state.posts.count, 2)
    }

    // MARK: - §4.9 / §4.10 tapLike 乐观更新

    func test_tapLike_unlikedToLiked_incrementsCount() async {
        let fake = FakeCircleService()
        let post = TestPostFactory.make(postId: 1, likeFlag: 0, likeCount: 5)
        fake.getAllMomentsResult = .success(MomentPage(posts: [post], currentPage: 1, hasMore: false))
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        store.tapLike(postId: 1)
        XCTAssertEqual(store.state.posts.first?.likeFlag, 1)
        XCTAssertEqual(store.state.posts.first?.likeCount, 6)

        // 等待 like API 调用完成 (fire-and-forget)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.likeCalls.first?.postId, 1)
        XCTAssertEqual(fake.likeCalls.first?.optionType, 1)
    }

    func test_tapLike_likedToUnliked_decrementsCount() async {
        let fake = FakeCircleService()
        let post = TestPostFactory.make(postId: 1, likeFlag: 1, likeCount: 5)
        fake.getAllMomentsResult = .success(MomentPage(posts: [post], currentPage: 1, hasMore: false))
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        store.tapLike(postId: 1)
        XCTAssertEqual(store.state.posts.first?.likeFlag, 0)
        XCTAssertEqual(store.state.posts.first?.likeCount, 4)

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.likeCalls.first?.optionType, 0)
    }

    // MARK: - tapLike 按 postId 查表 (不按 index)

    func test_tapLike_byPostId_findsRightPostAcrossPages() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .success(MomentPage(
            posts: [
                TestPostFactory.make(postId: 100, likeFlag: 0, likeCount: 1),
                TestPostFactory.make(postId: 101, likeFlag: 0, likeCount: 1),
            ],
            currentPage: 1, hasMore: true
        ))
        let store = MomentFeedStore(service: fake, pageSize: 2)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        // 翻页 → posts 拼接 → 第二页插在最后
        fake.getAllMomentsResult = .success(MomentPage(
            posts: [
                TestPostFactory.make(postId: 200, likeFlag: 0, likeCount: 1),
                TestPostFactory.make(postId: 201, likeFlag: 0, likeCount: 1),
            ],
            currentPage: 2, hasMore: false
        ))
        store.loadMore()
        _ = await waitFor(store, matching: { state in
            if case .loaded(let posts, _) = state { return posts.count == 4 }
            return false
        })

        // 点赞 postId=200 — 按 index 找会改错 (200 实际 index 2，但按 postId 不依赖 index)
        store.tapLike(postId: 200)
        let liked = store.state.posts.first { $0.postId == 200 }
        XCTAssertEqual(liked?.likeFlag, 1)
        XCTAssertEqual(liked?.likeCount, 2)
        // 其他 posts 不变
        XCTAssertEqual(store.state.posts.first { $0.postId == 100 }?.likeFlag, 0)
        XCTAssertEqual(store.state.posts.first { $0.postId == 101 }?.likeFlag, 0)
        XCTAssertEqual(store.state.posts.first { $0.postId == 201 }?.likeFlag, 0)
    }

    // MARK: - §5.9 切走 cancel inflight (结果丢弃)

    func test_cancelInflight_duringLoadingFirst_resetsToIdle() async {
        // 2026-07-02 修正：原实现 cancelInflight 卡在 .loadingFirst 不清 → 用户切回 sub 时 UI 一直转圈。
        // 修复后 cancelInflight 会把 .loadingFirst 转回 .idle，切回时 enterMoment 能重新触发。
        let fake = FakeCircleService()
        fake.delaySeconds = 0.2 // 让 service 挂起 200ms
        fake.getAllMomentsResult = .success(MomentPage(posts: [TestPostFactory.make(postId: 1)],
                                                       currentPage: 1, hasMore: false))
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        if case .loadingFirst = store.state {} else { XCTFail("Expected .loadingFirst") }

        // 立即 cancel (模拟用户切走)
        store.cancelInflight()

        // state 立即转回 .idle（不等 delay 结束；Task 内部还会跑但 Task.isCancelled 守卫后 return）
        if case .idle = store.state {} else {
            XCTFail("Expected .idle after cancelInflight in loadingFirst, got \(store.state)")
        }

        // 等过原本的延迟期 + 余量：验证被 cancel 的 Task 结果不会污染 state
        try? await Task.sleep(nanoseconds: 300_000_000)
        if case .idle = store.state {} else {
            XCTFail("Expected to stay .idle after cancelled Task's fetch completes, got \(store.state)")
        }
    }

    // MARK: - §5.10 切走 + 立即切回 (enterMoment idempotent，仅一次请求)

    func test_enterMoment_repeatedDuringLoadingFirst_isIdempotent() async {
        let fake = FakeCircleService()
        fake.delaySeconds = 0.2
        fake.getAllMomentsResult = .success(MomentPage(posts: [TestPostFactory.make(postId: 1)],
                                                       currentPage: 1, hasMore: false))
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        // 极快切回 (再次调 enterMoment)
        store.enterMoment()
        store.enterMoment()

        _ = await waitFor(store, matching: isLoaded)
        XCTAssertEqual(fake.getAllMomentsCalls.count, 1, "enterMoment 在 .loadingFirst 态应 idempotent，只发一次请求")
    }

    func test_enterMoment_repeatedWhenLoaded_isIdempotent() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .success(MomentPage(posts: [TestPostFactory.make(postId: 1)],
                                                       currentPage: 1, hasMore: false))
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)
        let countAfterFirst = fake.getAllMomentsCalls.count

        // §5.7/§5.8 外/内层切回保留：store 视角是再次 enterMoment 应不重发
        store.enterMoment()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.getAllMomentsCalls.count, countAfterFirst, "切回 .loaded 态时不应重发")
        XCTAssertEqual(store.state.posts.count, 1, "已加载内容应保留")
    }

    // MARK: - 内存上限保护（trim：方案 A 简单截断）

    func test_loadMore_belowLimit_doesNotTrim() async {
        // pageSize=2, maxPostsInMemory=5：page1=[1,2] → loadMore → page2=[3,4] = 4 条 < 5，不 trim
        let fake = FakeCircleService()
        let p1 = [TestPostFactory.make(postId: 1), TestPostFactory.make(postId: 2)]
        let p2 = [TestPostFactory.make(postId: 3), TestPostFactory.make(postId: 4)]
        fake.getAllMomentsResult = .success(MomentPage(posts: p1, currentPage: 1, hasMore: true))
        let store = MomentFeedStore(service: fake, pageSize: 2, maxPostsInMemory: 5)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        fake.getAllMomentsResult = .success(MomentPage(posts: p2, currentPage: 2, hasMore: true))
        store.loadMore()
        _ = await waitFor(store, matching: isLoaded)

        XCTAssertEqual(store.state.posts.map(\.postId), [1, 2, 3, 4], "未达上限，不应 trim，保留全部条目")
    }

    func test_loadMore_overLimit_trimsTopOldest() async {
        // pageSize=3, maxPostsInMemory=4：page1=[1,2,3] → loadMore → page2=[4,5,6] = 6 条 > 4
        // 期望 trim 后 = [3,4,5,6]（保留最新 4 条，丢顶部最旧的 [1,2]）
        let fake = FakeCircleService()
        let p1 = [TestPostFactory.make(postId: 1),
                  TestPostFactory.make(postId: 2),
                  TestPostFactory.make(postId: 3)]
        let p2 = [TestPostFactory.make(postId: 4),
                  TestPostFactory.make(postId: 5),
                  TestPostFactory.make(postId: 6)]
        fake.getAllMomentsResult = .success(MomentPage(posts: p1, currentPage: 1, hasMore: true))
        let store = MomentFeedStore(service: fake, pageSize: 3, maxPostsInMemory: 4)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        fake.getAllMomentsResult = .success(MomentPage(posts: p2, currentPage: 2, hasMore: true))
        store.loadMore()
        _ = await waitFor(store, matching: isLoaded)

        XCTAssertEqual(store.state.posts.map(\.postId), [3, 4, 5, 6],
                       "超过上限应 suffix(N)：保留最新 4 条，丢顶部 [1,2]")
    }

    func test_loadMore_overLimit_currentPageNotAffectedByTrim() async {
        // trim 不影响 currentPage 推进：连续 loadMore 多次仍能正确请求 next page
        let fake = FakeCircleService()
        let p1 = [TestPostFactory.make(postId: 1), TestPostFactory.make(postId: 2)]
        fake.getAllMomentsResult = .success(MomentPage(posts: p1, currentPage: 1, hasMore: true))
        let store = MomentFeedStore(service: fake, pageSize: 2, maxPostsInMemory: 3)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        let p2 = [TestPostFactory.make(postId: 3), TestPostFactory.make(postId: 4)]
        fake.getAllMomentsResult = .success(MomentPage(posts: p2, currentPage: 2, hasMore: true))
        store.loadMore()
        _ = await waitFor(store, matching: isLoaded)
        // 此时 posts trim 到 [2,3,4]，但 currentPage 应是 2

        let p3 = [TestPostFactory.make(postId: 5), TestPostFactory.make(postId: 6)]
        fake.getAllMomentsResult = .success(MomentPage(posts: p3, currentPage: 3, hasMore: true))
        store.loadMore()
        _ = await waitFor(store, matching: isLoaded)
        // currentPage 推进为 3，请求 page=3

        XCTAssertEqual(fake.getAllMomentsCalls.map(\.currentPage), [1, 2, 3],
                       "三次请求应分别为 page 1/2/3——trim 不应影响 currentPage 计数")
        XCTAssertEqual(store.state.posts.map(\.postId), [4, 5, 6],
                       "最终保留最新 3 条（maxPostsInMemory=3）")
    }

    func test_tapLike_onTrimmedPostId_silentlyReturns() async {
        // postId 被 trim 出 store 后，tapLike 应安全 return 不崩
        let fake = FakeCircleService()
        let p1 = [TestPostFactory.make(postId: 1),
                  TestPostFactory.make(postId: 2)]
        let p2 = [TestPostFactory.make(postId: 3),
                  TestPostFactory.make(postId: 4)]
        fake.getAllMomentsResult = .success(MomentPage(posts: p1, currentPage: 1, hasMore: true))
        let store = MomentFeedStore(service: fake, pageSize: 2, maxPostsInMemory: 2)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        fake.getAllMomentsResult = .success(MomentPage(posts: p2, currentPage: 2, hasMore: true))
        store.loadMore()
        _ = await waitFor(store, matching: isLoaded)
        // posts = [3,4]（trim 后），postId=1 已被丢

        let likeCallsBefore = fake.likeCalls.count
        store.tapLike(postId: 1)  // 不存在的 postId
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(fake.likeCalls.count, likeCallsBefore, "对 trim 出 store 的 postId tapLike 应 no-op")
        XCTAssertEqual(store.state.posts.map(\.postId), [3, 4], "state 不应被 tapLike 改动")
    }

    // MARK: - source 路由（official / moment / me）

    func test_source_official_callsGetOfficialMoments() async {
        let fake = FakeCircleService()
        fake.getOfficialMomentsResult = .success(MomentPage(posts: [TestPostFactory.make(postId: 100)],
                                                            currentPage: 1, hasMore: false))
        let store = MomentFeedStore(source: .official, service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        XCTAssertEqual(fake.getOfficialMomentsCalls.count, 1, "source=.official 应走 getOfficialMoments")
        XCTAssertEqual(fake.getAllMomentsCalls.count, 0, "不应走 getAllMoments")
        XCTAssertEqual(fake.getMyMomentsCalls.count, 0, "不应走 getMyMoments")
    }

    func test_source_moment_callsGetAllMoments() async {
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .success(MomentPage(posts: [TestPostFactory.make(postId: 200)],
                                                       currentPage: 1, hasMore: false))
        let store = MomentFeedStore(source: .moment, service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        XCTAssertEqual(fake.getAllMomentsCalls.count, 1)
        XCTAssertEqual(fake.getOfficialMomentsCalls.count, 0)
        XCTAssertEqual(fake.getMyMomentsCalls.count, 0)
    }

    func test_source_me_callsGetMyMomentsWithUserId() async {
        let fake = FakeCircleService()
        fake.getMyMomentsResult = .success(MomentPage(posts: [TestPostFactory.make(postId: 300)],
                                                      currentPage: 1, hasMore: false))
        let store = MomentFeedStore(source: .me(userId: 42), service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        XCTAssertEqual(fake.getMyMomentsCalls.first?.userId, 42, ".me(uid) 应把 uid 透传到 getMyMoments")
        XCTAssertEqual(fake.getAllMomentsCalls.count, 0)
        XCTAssertEqual(fake.getOfficialMomentsCalls.count, 0)
    }

    func test_source_defaultMoment_doesNotBreakExistingCallers() async {
        // 不传 source 走默认 .moment，确保已有调用方（默认参数）行为不变
        let fake = FakeCircleService()
        fake.getAllMomentsResult = .success(MomentPage(posts: [], currentPage: 1, hasMore: false))
        let store = MomentFeedStore(service: fake, pageSize: 20)
        store.enterMoment()
        _ = await waitFor(store, matching: isLoaded)

        XCTAssertEqual(fake.getAllMomentsCalls.count, 1, "默认 source=.moment 应走 getAllMoments")
    }
}
