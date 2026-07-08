import XCTest

// 决策：项目现有 pattern 全部用 XCTest（Tests/HilyTests/ 无一处 Swift Testing 案例）；
// 用户 pref Swift Testing 是基于"HilyTests 已实践"的假设，实际项目内不含。
// 沿用 XCTest 保持项目一致性（对齐 CLAUDE.md "Follow existing code patterns"）。

/// EditProfileStore 状态机 + 编辑操作 + Confirm 分支单测。
/// 覆盖 spec §5 反向清单（P-*/N-*）单测项。
@MainActor
final class EditProfileStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(service: FakeEditProfileService = FakeEditProfileService()) -> EditProfileStore {
        EditProfileStore(service: service)
    }

    /// 等 phase 变到指定态（timeout 后 XCTFail）
    private func waitPhase(
        _ store: EditProfileStore,
        equals expected: EditProfilePhase,
        timeout: TimeInterval = 1.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.phase != expected {
            if Date() > deadline {
                XCTFail("expected phase \(expected) got \(store.phase)")
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Loading (P-1 / N-4 / N-5 / N-6)

    /// P-1: 冷启动 → loading → editing；draft 反射原始数据
    func test_P1_load_success_transitionsToEditing() async {
        let svc = FakeEditProfileService()
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(
                nickname: "Alice", signature: "hi"
            ),
            latestIconAndCallVideo: nil,
            picList: nil
        ))
        let store = makeStore(service: svc)
        await store.load()

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.draft.nickname, "Alice")
        XCTAssertEqual(store.draft.signature, "hi")
        XCTAssertEqual(store.review, .none)
    }

    /// N-4: 3 字段同时审核中 → canEdit* 全 false + reviewing greetMsgs 展示
    func test_N4_loadWithAllReviewing_locksAllFields() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(
            nickname: "PendingName",
            signature: "PendingBio",
            greetMsgs: [FakeEditProfileService.greetMsg(id: 99, content: "Reviewing greet")]
        ))
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(),
            latestIconAndCallVideo: [LatestIconAndCallVideo(id: 1, businessType: 2, mediaUrl: "u", vaild: 2)],
            picList: nil
        ))
        let store = makeStore(service: svc)
        await store.load()

        XCTAssertEqual(store.phase, .editing)
        XCTAssertTrue(store.review.nickname)
        XCTAssertTrue(store.review.signature)
        XCTAssertTrue(store.review.avatar)
        XCTAssertEqual(store.review.reviewingGreetMsgs.count, 1)
        XCTAssertFalse(store.canEditNickname)
        XCTAssertFalse(store.canEditSignature)
        XCTAssertFalse(store.canEditAvatar)
    }

    /// N-5: checkUserInfo 失败 → loadError banner + Retry；不 fallback 到 no-review
    func test_N5_checkUserInfoFailed_entersLoadError() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .failure(APIError(code: "9999", message: "check failed"))
        let store = makeStore(service: svc)
        await store.load()

        guard case .loadError = store.phase else {
            return XCTFail("expected .loadError, got \(store.phase)")
        }
        XCTAssertNotNil(store.loadErrorMessage)
    }

    /// N-6: userInfo 失败 → 同 N-5
    func test_N6_userInfoFailed_entersLoadError() async {
        let svc = FakeEditProfileService()
        svc.userInfoResult = .failure(APIError(code: "9999", message: "userInfo failed"))
        let store = makeStore(service: svc)
        await store.load()

        guard case .loadError = store.phase else {
            return XCTFail("expected .loadError")
        }
    }

    // MARK: - Field Editing (N-1 / N-7 / N-8 / N-22)

    /// N-1: 昵称审核中，editNickname 无效
    func test_N1_editNickname_whenReviewing_isNoOp() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .success(CheckUserInfoResponse(nickname: "Pending", signature: nil, greetMsgs: nil))
        let store = makeStore(service: svc)
        await store.load()

        store.editNickname("NewName")
        XCTAssertNotEqual(store.draft.nickname, "NewName", "reviewing nickname must not be editable")
    }

    /// N-7: 昵称超 15 字截断
    func test_N7_editNickname_truncatesAt15Chars() async {
        let store = makeStore()
        await store.load()

        store.editNickname("aaaaaaaaaaaaaaaaaaaaaa")  // 22 chars
        XCTAssertEqual(store.draft.nickname.count, 15)
    }

    /// N-8: 简介超 200 字截断
    func test_N8_editSignature_truncatesAt200Chars() async {
        let store = makeStore()
        await store.load()

        let longText = String(repeating: "a", count: 250)
        store.editSignature(longText)
        XCTAssertEqual(store.draft.signature.count, 200)
    }

    /// N-22: 问候语超 50 字截断
    func test_N22_addGreetMsg_truncatesAt50Chars() async {
        let store = makeStore()
        await store.load()

        let longMsg = String(repeating: "a", count: 60)
        store.addGreetMsg(content: longMsg)
        XCTAssertEqual(store.draft.greetMsgs.count, 1)
        XCTAssertEqual(store.draft.greetMsgs.first?.content.count, 50)
    }

    /// N-23: 问候语允许重复添加（H5 一致）
    func test_N23_addGreetMsg_allowsDuplicates() async {
        let store = makeStore()
        await store.load()

        store.addGreetMsg(content: "Hi")
        store.addGreetMsg(content: "Hi")
        XCTAssertEqual(store.draft.greetMsgs.count, 2)
    }

    // MARK: - Media Placeholder & Limits (N-9 / N-10 / N-14 / N-15)

    /// N-9: 相册满 9 张 → addPhoto 拒绝 + toast
    func test_N9_addPhoto_whenAt9_returnsNilAndSetsToast() async {
        let svc = FakeEditProfileService()
        let existing = (1...9).map { FakeEditProfileService.mediaAsset(id: $0) }
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(pictures: existing),
            latestIconAndCallVideo: nil, picList: nil
        ))
        let store = makeStore(service: svc)
        await store.load()

        XCTAssertEqual(store.draft.photos.count, 9)
        let newId = store.addPhotoPlaceholder()
        XCTAssertNil(newId)
        XCTAssertNotNil(store.transientToast)
    }

    /// N-10: 视频满 6 个 → addVideo 拒绝
    func test_N10_addVideo_whenAt6_returnsNil() async {
        let svc = FakeEditProfileService()
        let existing = (1...6).map { FakeEditProfileService.mediaAsset(id: $0) }
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(videos: existing),
            latestIconAndCallVideo: nil, picList: nil
        ))
        let store = makeStore(service: svc)
        await store.load()

        XCTAssertEqual(store.draft.videos.count, 6)
        XCTAssertNil(store.addVideoPlaceholder())
    }

    /// N-14: 相册上传中 → 删除 → tile 消失
    func test_N14_removePhotoDuringUpload_removesTile() async {
        let store = makeStore()
        await store.load()

        let id = store.addPhotoPlaceholder()!
        XCTAssertEqual(store.draft.photos.count, 1)
        XCTAssertTrue(store.hasUploadingTile)

        store.removePhoto(id: id)
        XCTAssertEqual(store.draft.photos.count, 0)
        XCTAssertFalse(store.hasUploadingTile)
    }

    /// N-15: 相册上传失败 → tile.failed → retry → 恢复 uploading
    func test_N15_retryPhotoAfterFailure_backToUploading() async {
        let store = makeStore()
        await store.load()

        let id = store.addPhotoPlaceholder()!
        store.markPhotoFailed(id: id, message: "network")
        XCTAssertTrue(store.hasFailedTile)

        store.retryPhoto(id: id)
        XCTAssertFalse(store.hasFailedTile)
        XCTAssertTrue(store.hasUploadingTile)
    }

    // MARK: - Confirm Guards (N-16 / N-17)

    /// N-16: 有 uploading tile 时点 Confirm → 保持 editing + toast
    func test_N16_handleConfirm_withUploadingTile_showsToastAndStaysEditing() async {
        let store = makeStore()
        await store.load()

        _ = store.addPhotoPlaceholder()  // uploading
        XCTAssertFalse(store.canConfirm)

        await store.handleConfirm()
        XCTAssertEqual(store.phase, .editing)
        XCTAssertNotNil(store.transientToast)
    }

    /// N-17: 有 failed tile 时点 Confirm → 保持 editing + toast
    func test_N17_handleConfirm_withFailedTile_showsToastAndStaysEditing() async {
        let store = makeStore()
        await store.load()

        let id = store.addPhotoPlaceholder()!
        store.markPhotoFailed(id: id, message: "err")
        XCTAssertFalse(store.canConfirm)

        await store.handleConfirm()
        XCTAssertEqual(store.phase, .editing)
    }

    // MARK: - Confirm Result Branches (P-2 / P-9 / N-18 / N-19 / N-26)

    /// P-9: 无变更点 Confirm → phase .terminated（对齐 H5 直接 back 无 dialog）+ 不发接口
    /// Step 3 反悔 #3-4：原实现转 .success 弹 alert 与 spec §5 P-9 及 H5 行为不一致
    func test_P9_handleConfirm_noChanges_terminatesWithoutRequest() async {
        let svc = FakeEditProfileService()
        let store = makeStore(service: svc)
        await store.load()

        await store.handleConfirm()
        XCTAssertEqual(store.phase, .terminated)
        XCTAssertEqual(svc.updateCalls.count, 0, "no request should fire when no changes")
    }

    /// Step 3 反悔 #3-4：alert 死循环修复 —— acknowledgeSuccess 把 .success 转 .terminated
    func test_acknowledgeSuccess_transitionsSuccessToTerminated() async {
        let svc = FakeEditProfileService()
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(nickname: "Old"),
            latestIconAndCallVideo: nil, picList: nil
        ))
        let store = makeStore(service: svc)
        await store.load()

        // 触发一次真 saving 成功让 phase 进 .success
        store.editNickname("New")
        await store.handleConfirm()
        XCTAssertEqual(store.phase, .success)

        // ack → .terminated
        store.acknowledgeSuccess()
        XCTAssertEqual(store.phase, .terminated)
    }

    /// acknowledgeSuccess 非 .success 状态调用 no-op（防误用）
    func test_acknowledgeSuccess_whenNotInSuccess_isNoOp() async {
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.phase, .editing)

        store.acknowledgeSuccess()
        XCTAssertEqual(store.phase, .editing)
    }

    /// P-2: 昵称改动 + Confirm 成功 → phase .success + request 含 nickname
    func test_P2_handleConfirm_withNicknameChange_success() async {
        let svc = FakeEditProfileService()
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(nickname: "Old"),
            latestIconAndCallVideo: nil, picList: nil
        ))
        let store = makeStore(service: svc)
        await store.load()

        store.editNickname("New")
        await store.handleConfirm()

        XCTAssertEqual(store.phase, .success)
        XCTAssertEqual(svc.updateCalls.count, 1)
        XCTAssertEqual(svc.updateCalls.first?.nickname, "New")
    }

    /// N-18: updateUserInfo 返回业务错误 → phase 回 .editing + toast(code+message)
    func test_N18_handleConfirm_apiError_returnsToEditingWithToast() async {
        let svc = FakeEditProfileService()
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(nickname: "Old"),
            latestIconAndCallVideo: nil, picList: nil
        ))
        svc.updateUserInfoResult = .failure(APIError(code: "1080", message: "conflict"))
        let store = makeStore(service: svc)
        await store.load()

        store.editNickname("New")
        await store.handleConfirm()

        XCTAssertEqual(store.phase, .editing)
        if case .apiError(let code, _) = store.transientToast {
            XCTAssertEqual(code, "1080")
        } else {
            XCTFail("expected .apiError toast, got \(String(describing: store.transientToast))")
        }
        XCTAssertEqual(store.draft.nickname, "New", "draft preserved after failure")
    }

    /// N-19 / N-26 / N-32: 网络错误 → phase 回 .editing + toast + draft 不丢
    func test_N19_handleConfirm_networkError_preservesDraft() async {
        let svc = FakeEditProfileService()
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(nickname: "Old"),
            latestIconAndCallVideo: nil, picList: nil
        ))
        svc.updateUserInfoResult = .failure(URLError(.notConnectedToInternet))
        let store = makeStore(service: svc)
        await store.load()

        store.editNickname("New")
        await store.handleConfirm()

        XCTAssertEqual(store.phase, .editing)
        XCTAssertNotNil(store.transientToast)
        XCTAssertEqual(store.draft.nickname, "New")
    }

    // MARK: - Upload Epoch (N-20 / N-31)

    /// N-31: 覆盖上传 - Upload Epoch 递增让老 task 结果被丢弃
    func test_N31_invalidateOngoingUploads_incrementsEpoch() async {
        let store = makeStore()
        await store.load()

        let e0 = store.beginUpload()
        store.invalidateOngoingUploads()
        let e1 = store.beginUpload()
        XCTAssertNotEqual(e0, e1)
        XCTAssertFalse(store.isUploadCurrent(epoch: e0), "old epoch should be stale")
        XCTAssertTrue(store.isUploadCurrent(epoch: e1))
    }

    /// N-20: dismiss (dispose) 时 Upload Epoch 递增，未来老 task 完成时被守
    func test_N20_dispose_incrementsEpochAndStaleGuard() async {
        let store = makeStore()
        await store.load()

        let epochBefore = store.beginUpload()
        store.dispose()
        XCTAssertFalse(store.isUploadCurrent(epoch: epochBefore))
    }

    // MARK: - Session Terminated (N-27 / N-33)

    /// N-27 / N-33: 挤下线 → phase .terminated + Upload Epoch 递增
    func test_N33_sessionInvalidated_transitionsToTerminated() async {
        let store = makeStore()
        await store.load()

        let epochBefore = store.beginUpload()
        store.handleSessionInvalidated()

        XCTAssertEqual(store.phase, .terminated)
        XCTAssertFalse(store.isUploadCurrent(epoch: epochBefore))
    }

    /// N-33 变体：saving 中挤下线 → 后续 updateUserInfo 完成不覆盖 .terminated
    func test_N33_savingInterruptedByTerminate_doesNotOverwrite() async {
        let svc = FakeEditProfileService()
        svc.delaySeconds = 0.1
        svc.userInfoResult = .success(UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.populatedAnchorInfo(nickname: "Old"),
            latestIconAndCallVideo: nil, picList: nil
        ))
        let store = makeStore(service: svc)
        await store.load()

        store.editNickname("New")
        let confirmTask = Task { await store.handleConfirm() }
        try? await Task.sleep(nanoseconds: 20_000_000)  // 让 confirm 进入 saving
        store.handleSessionInvalidated()
        await confirmTask.value

        XCTAssertEqual(store.phase, .terminated, "terminated should not be overwritten by saving completion")
    }

    // MARK: - Loading Retry (loadError → loading)

    func test_retry_fromLoadError_reloadsSuccessfully() async {
        let svc = FakeEditProfileService()
        svc.checkUserInfoResult = .failure(APIError(code: "9999", message: "boom"))
        let store = makeStore(service: svc)
        await store.load()
        guard case .loadError = store.phase else { return XCTFail() }

        svc.checkUserInfoResult = .success(CheckUserInfoResponse(nickname: nil, signature: nil, greetMsgs: nil))
        await store.retry()
        XCTAssertEqual(store.phase, .editing)
    }
}
