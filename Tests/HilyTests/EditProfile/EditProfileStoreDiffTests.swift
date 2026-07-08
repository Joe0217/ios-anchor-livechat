import XCTest

/// EditProfileStore 智能字段检测 diff 逻辑单测（spec §2.4 / §5 P-5/P-7/P-8/N-21）。
/// 每个 test 直接构造 store + snapshot + draft，绕过 load，聚焦 buildUpdateRequest。
@MainActor
final class EditProfileStoreDiffTests: XCTestCase {

    // MARK: - Helper: 一步造好 store 并进 editing 态

    private func makeLoadedStore(
        anchor: AnchorInfo = FakeEditProfileService.emptyAnchorInfo,
        review: CheckUserInfoResponse = CheckUserInfoResponse(nickname: nil, signature: nil, greetMsgs: nil),
        media: [LatestIconAndCallVideo]? = nil
    ) async -> EditProfileStore {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(review)
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: anchor,
            latestIconAndCallVideo: media,
            picList: nil
        ))
        let store = EditProfileStore(service: svc)
        await store.load()
        return store
    }

    // MARK: - Diff: 无变更

    /// P-9: 全空 draft = original → buildUpdateRequest 返回 nil
    func test_diff_noChanges_returnsNil() async {
        let store = await makeLoadedStore(anchor: FakeEditProfileService.populatedAnchorInfo())
        XCTAssertNil(store.buildUpdateRequest())
    }

    // MARK: - Diff: 单字段变更

    func test_diff_onlyNicknameChanged() async {
        let store = await makeLoadedStore(anchor: FakeEditProfileService.populatedAnchorInfo(nickname: "Old"))
        store.editNickname("New")
        let req = store.buildUpdateRequest()
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.nickname, "New")
        XCTAssertNil(req?.icon)
        XCTAssertNil(req?.signature)
        XCTAssertNil(req?.pics)
    }

    /// N-1 派生: 昵称审核中不参与 diff
    ///
    /// 2026-07-08 行为更新：审核中时 draft.nickname 显示"提交审核的值"（对齐 H5），
    /// 不再是"老通过审核的值"。但 editNickname 内 guard review.nickname 阻止用户改，
    /// 所以 draft.nickname 保持为审核值 "Pending"，与 originalSnapshot.nickname "Old" 不等；
    /// buildUpdateRequest 依赖 `!review.nickname` guard 拦截 nickname 字段不进 request。
    func test_diff_nicknameChangeWhileReviewing_excludedFromRequest() async {
        let store = await makeLoadedStore(
            anchor: FakeEditProfileService.populatedAnchorInfo(nickname: "Old"),
            review: CheckUserInfoResponse(nickname: "Pending", signature: nil, greetMsgs: nil)
        )
        // draft 显示审核值（审核中字段用审核值 for UI，不是老值）
        XCTAssertEqual(store.draft.nickname, "Pending")
        // editNickname 被 review.nickname guard 阻止
        store.editNickname("UserAttemptedNew")
        XCTAssertEqual(store.draft.nickname, "Pending", "review.nickname=true 时用户改不动")
        // buildUpdateRequest：draft.nickname != orig.nickname 但 review.nickname=true 应拦截整个 nickname 字段
        let req = store.buildUpdateRequest()
        XCTAssertNil(req?.nickname, "review 中 nickname 不进 request")
        // 其他字段也无变更 → buildUpdateRequest 返 nil
        XCTAssertNil(req)
    }

    // MARK: - Diff: Photos (P-5 / N-21)

    /// P-5: 新增 3 + 删除 1 原图
    func test_P5_diff_photos_addAndRemove() async {
        let orig = [
            FakeEditProfileService.mediaAsset(id: 100, url: "orig-a"),
            FakeEditProfileService.mediaAsset(id: 101, url: "orig-b"),
        ]
        let store = await makeLoadedStore(
            anchor: FakeEditProfileService.populatedAnchorInfo(pictures: orig)
        )

        // 新增 3 张
        let n1 = store.addPhotoPlaceholder()!
        store.markPhotoUploaded(id: n1, url: "new-1")
        let n2 = store.addPhotoPlaceholder()!
        store.markPhotoUploaded(id: n2, url: "new-2")
        let n3 = store.addPhotoPlaceholder()!
        store.markPhotoUploaded(id: n3, url: "new-3")

        // 删除原图 id=100
        let toRemove = store.draft.photos.first { $0.serverId == 100 }!.id
        store.removePhoto(id: toRemove)

        let req = store.buildUpdateRequest()!
        XCTAssertEqual(req.pics?.sorted(), ["new-1", "new-2", "new-3"])
        XCTAssertEqual(req.picsDel, [100])
    }

    /// N-21: 原图 vaild=3 被拒 → 用户不见 → diff 强制加入 picsDel
    func test_N21_diff_rejectedPhoto_forcedIntoDelList() async {
        let orig = [
            FakeEditProfileService.mediaAsset(id: 200, url: "ok"),
            FakeEditProfileService.mediaAsset(id: 300, url: "rejected", vaild: 3),
        ]
        let store = await makeLoadedStore(
            anchor: FakeEditProfileService.populatedAnchorInfo(pictures: orig)
        )

        // 用户看到的 draft 只含 id=200（vaild=3 被过滤）
        XCTAssertEqual(store.draft.photos.count, 1)
        XCTAssertEqual(store.draft.photos.first?.serverId, 200)

        // 加一张新图（触发 diff 非空）
        let n = store.addPhotoPlaceholder()!
        store.markPhotoUploaded(id: n, url: "new")
        let req = store.buildUpdateRequest()!

        // picsDel 强制含 300（rejected 强制清）
        XCTAssertEqual(req.picsDel?.sorted(), [300])
    }

    // MARK: - Diff: Videos

    func test_diff_videos_addOnly() async {
        let store = await makeLoadedStore(anchor: FakeEditProfileService.populatedAnchorInfo())
        let v = store.addVideoPlaceholder()!
        store.markVideoUploaded(id: v, url: "video-1", coverUrl: "cover-1")

        let req = store.buildUpdateRequest()!
        XCTAssertEqual(req.videos, ["video-1"])
        XCTAssertNil(req.videosDel)
    }

    // MARK: - Diff: Call Video (P-7)

    /// P-7: 原有来电视频替换 → callVideoUrl=new + callVideosDel=[原id]
    func test_P7_diff_callVideoReplace() async {
        let store = await makeLoadedStore(
            media: [LatestIconAndCallVideo(id: 42, businessType: 3, mediaUrl: "orig-call", vaild: 1)]
        )
        XCTAssertEqual(store.originalSnapshot.callVideo?.assetId, 42)

        // 清掉原有 + 加新的（模拟用户替换：先删 tile 再选新）
        store.clearCallVideo()
        _ = store.setCallVideoPlaceholder()
        let newId = store.draft.callVideo!.id
        store.markCallVideoUploaded(id: newId, url: "new-call", coverUrl: nil)

        let req = store.buildUpdateRequest()!
        XCTAssertEqual(req.callVideoUrl, "new-call")
        XCTAssertEqual(req.callVideosDel, [42])
    }

    /// 用户清空来电视频（原有 → 无）
    func test_diff_callVideoClear() async {
        let store = await makeLoadedStore(
            media: [LatestIconAndCallVideo(id: 42, businessType: 3, mediaUrl: "orig", vaild: 1)]
        )
        store.clearCallVideo()

        let req = store.buildUpdateRequest()!
        XCTAssertNil(req.callVideoUrl)
        XCTAssertEqual(req.callVideosDel, [42])
    }

    // MARK: - Diff: Greet Messages (P-8)

    /// P-8: 新增 2 + 删除 1 原有
    func test_P8_diff_greetMsgs_addAndRemove() async {
        let orig = [
            FakeEditProfileService.greetMsg(id: 500, content: "Hi"),
            FakeEditProfileService.greetMsg(id: 501, content: "Hello"),
        ]
        let store = await makeLoadedStore(
            anchor: FakeEditProfileService.populatedAnchorInfo(greetMsgs: orig)
        )

        // 新增 "Bonjour", "Hola"
        store.addGreetMsg(content: "Bonjour")
        store.addGreetMsg(content: "Hola")

        // 删除原有 id=500
        let toRemove = store.draft.greetMsgs.first { $0.serverId == 500 }!.id
        store.removeGreetMsg(id: toRemove)

        let req = store.buildUpdateRequest()!
        XCTAssertEqual(req.addGreetList?.sorted(), ["Bonjour", "Hola"])
        XCTAssertEqual(req.delGreetList, [500])
    }

    // MARK: - Diff: 全字段变更

    func test_diff_allFieldsChanged_fullRequestFormed() async {
        let orig = FakeEditProfileService.populatedAnchorInfo(
            nickname: "OldName",
            icon: "old-icon",
            signature: "old-bio",
            pictures: [FakeEditProfileService.mediaAsset(id: 1)],
            greetMsgs: [FakeEditProfileService.greetMsg(id: 501, content: "Hi")]
        )
        let store = await makeLoadedStore(anchor: orig)

        store.editNickname("NewName")
        store.markAvatarUploaded(url: "new-icon")
        store.editSignature("new-bio")
        let n = store.addPhotoPlaceholder()!
        store.markPhotoUploaded(id: n, url: "new-photo")
        store.addGreetMsg(content: "Bonjour")

        let req = store.buildUpdateRequest()!
        XCTAssertEqual(req.nickname, "NewName")
        XCTAssertEqual(req.icon, "new-icon")
        XCTAssertEqual(req.signature, "new-bio")
        XCTAssertEqual(req.pics, ["new-photo"])
        XCTAssertNil(req.picsDel)  // id=1 仍在 draft
        XCTAssertEqual(req.addGreetList, ["Bonjour"])
        XCTAssertNil(req.delGreetList)  // 501 仍在 draft
    }
}
