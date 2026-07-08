import XCTest

/// 审核中字段展示审核值单测（2026-07-08 对齐 H5 profile/index.vue:107-118 + L80-85）。
///
/// 用户需求：若资料某字段（昵称/简介/头像）在审核中，编辑页要显示"提交审核的新值"，
/// 不能显示"审核前的老值"或空。
///
/// 覆盖点：
/// - buildLoadArtifacts：nickname/signature/avatar 审核中时 draft.X = check.X（审核值），
///   非审核中时 draft.X = anchor.X（老值）
/// - originalSnapshot 始终保留 anchor.X（老值）用于 diff
/// - buildUpdateRequest：审核中字段不会被误提交（`!review.X` guard 拦截）
/// - mergeRefreshResult：SWR 后 refresh 回来能切换到审核值
@MainActor
final class EditProfileReviewingDisplayTests: XCTestCase {

    // MARK: - load 分支：初次进入

    /// nickname 审核中 → draft.nickname = check.nickname（审核值），snapshot 仍是 anchor.nickname（老值）
    func test_load_nicknameReviewing_draftShowsCheckValueSnapshotKeepsOldValue() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(
            nickname: "NewSubmittedName",     // ← 提交审核的新值
            signature: nil, greetMsgs: nil
        ))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(
                nickname: "OldApprovedName"    // ← 当前通过审核的老值
            ),
            latestIconAndCallVideo: nil,
            picList: nil
        ))
        let store = EditProfileStore(service: svc)
        await store.load()

        XCTAssertTrue(store.review.nickname, "review.nickname 应为 true")
        XCTAssertEqual(store.draft.nickname, "NewSubmittedName",
                       "draft.nickname 应显示审核值（用户看到自己提交的内容）")
        XCTAssertEqual(store.originalSnapshot.nickname, "OldApprovedName",
                       "originalSnapshot.nickname 应保留老值（diff 基线）")
    }

    /// signature 审核中 → 同 nickname 语义
    func test_load_signatureReviewing_draftShowsCheckValueSnapshotKeepsOldValue() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(
            nickname: nil, signature: "New bio in review", greetMsgs: nil
        ))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(signature: "Old approved bio"),
            latestIconAndCallVideo: nil,
            picList: nil
        ))
        let store = EditProfileStore(service: svc)
        await store.load()

        XCTAssertTrue(store.review.signature)
        XCTAssertEqual(store.draft.signature, "New bio in review")
        XCTAssertEqual(store.originalSnapshot.signature, "Old approved bio")
    }

    /// avatar 审核中 → draft.avatarUrl = latestMedia[businessType=2, vaild=2].mediaUrl
    func test_load_avatarReviewing_draftShowsReviewingMediaUrl() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(nickname: nil, signature: nil, greetMsgs: nil))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(icon: "https://cdn/old-approved.jpg"),
            latestIconAndCallVideo: [
                LatestIconAndCallVideo(id: 88, businessType: 2, mediaUrl: "https://cdn/new-in-review.jpg", vaild: 2),
            ],
            picList: nil
        ))
        let store = EditProfileStore(service: svc)
        await store.load()

        XCTAssertTrue(store.review.avatar)
        XCTAssertEqual(store.draft.avatarUrl, "https://cdn/new-in-review.jpg",
                       "draft.avatarUrl 应显示审核中头像图")
        XCTAssertEqual(store.originalSnapshot.avatarUrl, "https://cdn/old-approved.jpg",
                       "originalSnapshot.avatarUrl 应保留老头像 URL（diff 基线）")
    }

    /// avatar 被拒（vaild=3）→ draft.avatarUrl 显示老 anchor.icon（对齐 H5 L85）
    func test_load_avatarRejected_draftFallsBackToOldIcon() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(nickname: nil, signature: nil, greetMsgs: nil))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(icon: "https://cdn/old.jpg"),
            latestIconAndCallVideo: [
                LatestIconAndCallVideo(id: 88, businessType: 2, mediaUrl: "https://cdn/rejected.jpg", vaild: 3),
            ],
            picList: nil
        ))
        let store = EditProfileStore(service: svc)
        await store.load()

        XCTAssertFalse(store.review.avatar, "vaild=3 不算审核中")
        XCTAssertTrue(store.review.avatarRejected, "vaild=3 应标 avatarRejected")
        XCTAssertEqual(store.draft.avatarUrl, "https://cdn/old.jpg",
                       "被拒时应显示老头像（H5 L85 fallback）")
    }

    /// 非审核中的字段 → draft = snapshot = anchor 老值（老逻辑不变）
    func test_load_noneReviewing_draftEqualsSnapshotEqualsAnchor() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(nickname: nil, signature: nil, greetMsgs: nil))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(
                nickname: "Alice", icon: "https://cdn/a.jpg", signature: "Hi"
            ),
            latestIconAndCallVideo: nil,
            picList: nil
        ))
        let store = EditProfileStore(service: svc)
        await store.load()

        XCTAssertFalse(store.review.nickname)
        XCTAssertFalse(store.review.signature)
        XCTAssertFalse(store.review.avatar)
        XCTAssertEqual(store.draft.nickname, "Alice")
        XCTAssertEqual(store.draft.signature, "Hi")
        XCTAssertEqual(store.draft.avatarUrl, "https://cdn/a.jpg")
        XCTAssertEqual(store.originalSnapshot.nickname, "Alice")
    }

    // MARK: - buildUpdateRequest：审核中字段不会误提交

    /// 审核中 nickname 的审核值 != snapshot 老值，diff 不能因此误提交
    func test_diff_nicknameReviewingWithDifferentValue_notSubmitted() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(
            nickname: "SubmittedForReview", signature: nil, greetMsgs: nil
        ))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(nickname: "OldApproved"),
            latestIconAndCallVideo: nil,
            picList: nil
        ))
        let store = EditProfileStore(service: svc)
        await store.load()

        // draft.nickname != snapshot.nickname 但 review.nickname=true 应拦截
        XCTAssertNotEqual(store.draft.nickname, store.originalSnapshot.nickname)
        let req = store.buildUpdateRequest()
        XCTAssertNil(req?.nickname, "review.nickname=true 时 nickname 字段不应进 update request")
    }

    /// 审核中 avatar：mediaUrl 差异不导致误提交
    func test_diff_avatarReviewingWithDifferentUrl_notSubmitted() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(nickname: nil, signature: nil, greetMsgs: nil))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(icon: "https://cdn/old.jpg"),
            latestIconAndCallVideo: [
                LatestIconAndCallVideo(id: 1, businessType: 2, mediaUrl: "https://cdn/new-in-review.jpg", vaild: 2),
            ],
            picList: nil
        ))
        let store = EditProfileStore(service: svc)
        await store.load()

        XCTAssertNotEqual(store.draft.avatarUrl, store.originalSnapshot.avatarUrl)
        let req = store.buildUpdateRequest()
        XCTAssertNil(req?.icon, "review.avatar=true 时 icon 字段不应进 update request")
    }

    // MARK: - SWR refresh 合并：审核中字段强制覆盖

    /// hydrate 用老值填 draft → refresh 后审核中字段切到审核值（无 dirty 保护，因为用户不能编辑审核字段）
    func test_mergeRefresh_reviewingFields_forceOverwriteEvenIfDraftMatchedOldValue() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(
            nickname: "NewInReview", signature: nil, greetMsgs: nil
        ))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(nickname: "Old"),
            latestIconAndCallVideo: nil,
            picList: nil
        ))
        let store = EditProfileStore(service: svc)
        // hydrate 用老值（AnchorInfo）填 draft.nickname = "Old"
        _ = store.hydrate(from: FakeEditProfileService.populatedAnchorInfo(nickname: "Old"))
        XCTAssertEqual(store.draft.nickname, "Old")

        store.refreshInBackground()
        // 等 refresh 完成
        let deadline = Date().addingTimeInterval(1.0)
        while store.isRefreshing, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(store.review.nickname)
        XCTAssertEqual(store.draft.nickname, "NewInReview",
                       "refresh 后审核中字段应强制覆盖为审核值")
        XCTAssertEqual(store.originalSnapshot.nickname, "Old",
                       "snapshot 保留老值")
    }
}
