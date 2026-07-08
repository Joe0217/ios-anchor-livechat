import XCTest

/// EditProfileStore SWR（stale-while-revalidate）加载优化单测。
///
/// 覆盖点：
/// - `hydrate(from:)` 缓存命中 / 缺失分支
/// - `refreshInBackground` 成功合并 / 失败降级
/// - `mergeRefreshResult` 用户未编辑 / 已编辑字段的合并策略
/// - `awaitPendingRefresh` 超时兜底
@MainActor
final class EditProfileStoreSWRTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(service: FakeEditProfileService = FakeEditProfileService()) -> EditProfileStore {
        EditProfileStore(service: service)
    }

    /// 等 predicate 为 true 或超时 XCTFail
    private func waitUntil(
        timeout: TimeInterval = 1.0,
        _ predicate: @escaping () -> Bool,
        _ label: String = ""
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timeout waiting: \(label)")
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - hydrate(from:) 分支

    /// hydrate 命中缓存 → 秒开 4 基础字段 + phase=editing
    func test_hydrate_hitsCache_populates4BasicFieldsAndEditingPhase() {
        let store = makeStore()
        let info = FakeEditProfileService.populatedAnchorInfo(
            nickname: "Alice",
            icon: "https://cdn/a.jpg",
            signature: "hi world",
            greetMsgs: [FakeEditProfileService.greetMsg(id: 10, content: "hey")]
        )

        let ok = store.hydrate(from: info)

        XCTAssertTrue(ok)
        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.draft.nickname, "Alice")
        XCTAssertEqual(store.draft.avatarUrl, "https://cdn/a.jpg")
        XCTAssertEqual(store.draft.signature, "hi world")
        XCTAssertEqual(store.draft.greetMsgs.count, 1)
        XCTAssertEqual(store.draft.greetMsgs.first?.content, "hey")
        // photos/videos/callVideo 不 hydrate
        XCTAssertTrue(store.draft.photos.isEmpty)
        XCTAssertTrue(store.draft.videos.isEmpty)
        XCTAssertNil(store.draft.callVideo)
        // review 全 false 等待 refresh
        XCTAssertEqual(store.review, .none)
    }

    /// hydrate nil 缓存 → 返 false + phase 保持 loading（View 层走冷启动 load）
    func test_hydrate_nilCache_returnsFalseAndKeepsLoading() {
        let store = makeStore()
        let ok = store.hydrate(from: nil)

        XCTAssertFalse(ok)
        XCTAssertEqual(store.phase, .loading)
        XCTAssertEqual(store.originalSnapshot, .empty)
    }

    /// hydrate 已 hydrated（originalSnapshot 非空）时不重复 hydrate
    func test_hydrate_alreadyHydrated_returnsFalse() {
        let store = makeStore()
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(nickname: "First"))
        // 二次 hydrate 不应改变状态
        let ok = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(nickname: "Second"))

        XCTAssertFalse(ok)
        XCTAssertEqual(store.draft.nickname, "First")
    }

    // MARK: - refreshInBackground 成功 / 失败

    /// refresh 成功 → mergeRefreshResult 补 review + photos + videos + callVideo
    func test_refreshInBackground_success_mergesReviewAndMedia() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(
            nickname: "PendingNickname", signature: nil, greetMsgs: nil
        ))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(
                nickname: "ServerName",
                signature: "ServerBio"
            ),
            latestIconAndCallVideo: nil,
            picList: [
                UserInfoWithReviewResponse.PicListItem(
                    id: 100, mediaUrl: "https://cdn/p.jpg", mediaType: 1, vaild: 1, coverUrl: nil
                ),
                UserInfoWithReviewResponse.PicListItem(
                    id: 200, mediaUrl: "https://cdn/v.mp4", mediaType: 2, vaild: 1, coverUrl: "https://cdn/c.jpg"
                ),
            ]
        ))
        let store = makeStore(service: svc)
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(
            nickname: "CachedName", signature: "CachedBio"
        ))
        store.refreshInBackground()
        await waitUntil { store.isRefreshing == false }

        // review 全覆盖：nickname 审核中
        XCTAssertTrue(store.review.nickname)
        // 审核中字段（nickname）→ draft 用审核值（2026-07-08 对齐 H5：编辑页显示"提交审核的新值"）
        XCTAssertEqual(store.draft.nickname, "PendingNickname")
        // signature 非审核中 → draft 与 snapshot 同步为 anchor 老值
        XCTAssertEqual(store.draft.signature, "ServerBio")
        // photos/videos 从 picList 填充
        XCTAssertEqual(store.draft.photos.count, 1)
        XCTAssertEqual(store.draft.photos.first?.url, "https://cdn/p.jpg")
        XCTAssertEqual(store.draft.videos.count, 1)
        XCTAssertEqual(store.draft.videos.first?.coverUrl, "https://cdn/c.jpg")
    }

    /// refresh 失败 → 不切 loadError，phase 保持 editing（用户已可编辑）
    func test_refreshInBackground_failure_doesNotSwitchToLoadError() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .failure(APIError(code: "9999", message: "network"))
        let store = makeStore(service: svc)
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(nickname: "Cached"))
        store.refreshInBackground()
        await waitUntil { store.isRefreshing == false }

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.draft.nickname, "Cached")
    }

    // MARK: - mergeRefreshResult 合并策略（透过 refreshInBackground 验证）

    /// 用户 hydrate 后编辑了 nickname → refresh 回来 draft.nickname 保留用户输入
    func test_merge_userEditedNickname_preservesUserInput() async {
        let svc = FakeEditProfileService()
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(
                nickname: "ServerName", signature: "ServerBio"
            ),
            latestIconAndCallVideo: nil,
            picList: nil
        ))
        let store = makeStore(service: svc)
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(
            nickname: "CachedName", signature: "CachedBio"
        ))
        // 用户已编辑 nickname 为 "UserTyped"
        store.editNickname("UserTyped")

        store.refreshInBackground()
        await waitUntil { store.isRefreshing == false }

        // nickname 保留用户输入
        XCTAssertEqual(store.draft.nickname, "UserTyped")
        // signature 未编辑 → 同步服务端
        XCTAssertEqual(store.draft.signature, "ServerBio")
        // originalSnapshot 更新为服务端最新（供 diff 使用）
        XCTAssertEqual(store.originalSnapshot.nickname, "ServerName")
    }

    /// 用户 hydrate 后 addGreetMsg → refresh 回来 draft.greetMsgs 保留 local 新增
    func test_merge_userAddedGreetMsg_preservesLocalGreet() async {
        let svc = FakeEditProfileService()
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(
                greetMsgs: [FakeEditProfileService.greetMsg(id: 1, content: "Server-1")]
            ),
            latestIconAndCallVideo: nil,
            picList: nil
        ))
        let store = makeStore(service: svc)
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(
            greetMsgs: [FakeEditProfileService.greetMsg(id: 1, content: "Server-1")]
        ))
        store.addGreetMsg(content: "UserLocal")

        store.refreshInBackground()
        await waitUntil { store.isRefreshing == false }

        // draft 保留用户新增（未编辑就同步覆盖策略被判 dirty → 只更 snapshot）
        let hasUserLocal = store.draft.greetMsgs.contains { $0.serverId == nil && $0.content == "UserLocal" }
        XCTAssertTrue(hasUserLocal, "user's addGreetMsg must survive merge")
    }

    /// 用户 hydrate 后未编辑 → refresh 后 draft/snapshot 同步；photos 从 picList 补齐
    func test_merge_userNotEdited_synchronizesDraftAndSnapshot() async {
        let svc = FakeEditProfileService()
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(
                nickname: "ServerName",
                signature: "ServerBio",
                greetMsgs: [FakeEditProfileService.greetMsg(id: 1, content: "S1")]
            ),
            latestIconAndCallVideo: nil,
            picList: [
                UserInfoWithReviewResponse.PicListItem(
                    id: 300, mediaUrl: "https://cdn/x.jpg", mediaType: 1, vaild: 1, coverUrl: nil
                ),
            ]
        ))
        let store = makeStore(service: svc)
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(
            nickname: "CachedName",
            signature: "CachedBio",
            greetMsgs: [FakeEditProfileService.greetMsg(id: 1, content: "S1")]
        ))
        store.refreshInBackground()
        await waitUntil { store.isRefreshing == false }

        XCTAssertEqual(store.draft.nickname, "ServerName")
        XCTAssertEqual(store.draft.signature, "ServerBio")
        XCTAssertEqual(store.draft.photos.count, 1)
        XCTAssertEqual(store.originalSnapshot.nickname, "ServerName")
        XCTAssertEqual(store.originalSnapshot.photos.count, 1)
    }

    // MARK: - awaitPendingRefresh 超时

    /// refreshingTask 未启动时立即返
    func test_awaitPendingRefresh_noTask_returnsImmediately() async {
        let store = makeStore()
        let start = Date()
        await store.awaitPendingRefresh(timeout: 2.0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.1, "must return immediately when no task pending")
    }

    /// refresh 中调用 awaitPendingRefresh → 等它完成
    func test_awaitPendingRefresh_waitsForOngoingRefresh() async {
        let svc = FakeEditProfileService()
        svc.delaySeconds = 0.2
        let store = makeStore(service: svc)
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(nickname: "Cached"))
        store.refreshInBackground()

        // refresh 正在进行
        XCTAssertTrue(store.isRefreshing)
        await store.awaitPendingRefresh(timeout: 2.0)
        // await 返回后 refresh 应完成
        XCTAssertFalse(store.isRefreshing)
    }

    /// awaitPendingRefresh 超时兜底 → refresh 未完成也放行
    func test_awaitPendingRefresh_timeout_returnsBeforeTaskFinishes() async {
        let svc = FakeEditProfileService()
        svc.delaySeconds = 1.0
        let store = makeStore(service: svc)
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(nickname: "Cached"))
        store.refreshInBackground()

        let start = Date()
        await store.awaitPendingRefresh(timeout: 0.1)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.5, "timeout must trigger before refresh finishes")
        // refresh 仍在跑（超时不 cancel task）
        XCTAssertTrue(store.isRefreshing)
    }

    // MARK: - Confirm 保存竞态防御

    /// handleConfirm 会 await pending refresh，避免用 stale review 提交
    func test_handleConfirm_awaitsPendingRefresh_beforeDiff() async {
        let svc = FakeEditProfileService()
        svc.delaySeconds = 0.15
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(
            nickname: "InReview", signature: nil, greetMsgs: nil
        ))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(nickname: "ServerName"),
            latestIconAndCallVideo: nil,
            picList: nil
        ))
        let store = makeStore(service: svc)
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(nickname: "CachedName"))
        // 用户改了名字
        store.editNickname("UserTyped")
        store.refreshInBackground()

        // Confirm：refresh 未完，await 会等 refresh 完成后再走 diff
        await store.handleConfirm()

        // await 后 review.nickname 已从服务端刷回 true → buildUpdateRequest 会过滤 nickname 不提交
        XCTAssertTrue(store.review.nickname)
        // updateUserInfo 调用记录：nickname 字段应被过滤（review 中）
        if let call = svc.updateCalls.first {
            XCTAssertNil(call.nickname, "nickname must be filtered when review true")
        } else {
            // 若无变更（refresh 后 draft.nickname 仍 == "UserTyped" 但 review 拦截），可能走 terminated 分支
            // 只要 phase != saving 且不是空 saving 死循环即通过
            XCTAssertNotEqual(store.phase, .saving)
        }
    }
}
