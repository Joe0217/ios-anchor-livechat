import XCTest

/// EditProfileStore 上传前置校验单测（spec §5 N-11 / N-12 / N-13）。
///
/// 覆盖：
/// - 图片 > 2MB 拒绝 + toast + 不发上传请求
/// - 视频 > 20MB 拒绝 + toast + 不发上传请求
/// - 视频扩展名非 .mp4/.mov 拒绝 + toast
@MainActor
final class EditProfileUploadValidationTests: XCTestCase {

    // MARK: - Helper

    private func makeLoadedStore(service: FakeEditProfileService = FakeEditProfileService()) async -> (EditProfileStore, FakeEditProfileService) {
        let store = EditProfileStore(service: service)
        await store.load()
        return (store, service)
    }

    private func bytes(_ count: Int) -> Data {
        Data(count: count)
    }

    // MARK: - N-11: 图片 > 5MB（2026-07-07 用户产品决策：H5 是 2MB，iOS 放宽到 5MB）

    /// N-11: 单张图片 > 5MB → 拒绝 + toast，不调 uploadImage
    func test_N11_uploadPhoto_over5MB_rejectsAndShowsToast() async {
        let (store, svc) = await makeLoadedStore()

        // 6 MB
        await store.uploadPhoto(data: bytes(6 * 1024 * 1024))

        XCTAssertNotNil(store.transientToast)
        XCTAssertEqual(store.draft.photos.count, 0, "no placeholder added when validation fails")
        XCTAssertEqual(svc.uploadImageCalls.count, 0, "uploadImage should not be called")
    }

    /// N-11 反向：正好 5MB → 允许
    func test_N11_uploadPhoto_exactly5MB_accepted() async {
        let (store, svc) = await makeLoadedStore()

        await store.uploadPhoto(data: bytes(5 * 1024 * 1024))

        XCTAssertEqual(svc.uploadImageCalls.count, 1)
    }

    /// N-11 头像：> 5MB 也拒绝
    func test_N11_uploadAvatar_over5MB_rejects() async {
        let (store, svc) = await makeLoadedStore()

        await store.uploadAvatar(data: bytes(6 * 1024 * 1024))

        XCTAssertNotNil(store.transientToast)
        XCTAssertEqual(svc.uploadImageCalls.count, 0)
    }

    // MARK: - N-12: 视频 > 20MB

    /// N-12: 单个视频 > 20MB → 拒绝 + toast，不调 uploadVideo
    func test_N12_uploadVideo_over20MB_rejectsAndShowsToast() async {
        let (store, svc) = await makeLoadedStore()

        // 21 MB
        await store.uploadVideo(data: bytes(21 * 1024 * 1024), fileExtension: "mp4")

        XCTAssertNotNil(store.transientToast)
        XCTAssertEqual(store.draft.videos.count, 0)
        XCTAssertEqual(svc.uploadVideoCalls.count, 0)
    }

    /// N-12 反向：正好 20MB → 允许
    func test_N12_uploadVideo_exactly20MB_accepted() async {
        let (store, svc) = await makeLoadedStore()

        await store.uploadVideo(data: bytes(20 * 1024 * 1024), fileExtension: "mp4")

        XCTAssertEqual(svc.uploadVideoCalls.count, 1)
    }

    /// N-12 来电视频：> 20MB 同样拒绝
    func test_N12_uploadCallVideo_over20MB_rejects() async {
        let (store, svc) = await makeLoadedStore()

        await store.uploadCallVideo(data: bytes(21 * 1024 * 1024), fileExtension: "mp4")

        XCTAssertNil(store.draft.callVideo)
        XCTAssertEqual(svc.uploadVideoCalls.count, 0)
    }

    // MARK: - N-13: 视频扩展名不支持

    /// N-13: .avi 视频扩展名 → 拒绝 + toast
    func test_N13_uploadVideo_aviExtension_rejected() async {
        let (store, svc) = await makeLoadedStore()

        await store.uploadVideo(data: bytes(1024), fileExtension: "avi")

        XCTAssertNotNil(store.transientToast)
        XCTAssertEqual(svc.uploadVideoCalls.count, 0)
    }

    /// N-13 反向：.mp4 允许
    func test_N13_uploadVideo_mp4Extension_accepted() async {
        let (store, svc) = await makeLoadedStore()

        await store.uploadVideo(data: bytes(1024), fileExtension: "mp4")

        XCTAssertEqual(svc.uploadVideoCalls.count, 1)
    }

    /// N-13 反向：.mov 允许（大小写不敏感）
    func test_N13_uploadVideo_movExtension_caseInsensitive() async {
        let (store, svc) = await makeLoadedStore()

        await store.uploadVideo(data: bytes(1024), fileExtension: "MOV")

        XCTAssertEqual(svc.uploadVideoCalls.count, 1)
    }

    // MARK: - Upload success/failure integration (Store→Service 完整流)

    /// 上传成功 → draft.photos 有 tile + uploadState=.idle + url 填入
    func test_uploadPhoto_success_setsTileUploaded() async {
        let (store, svc) = await makeLoadedStore()
        svc.uploadImageResult = .success("https://cdn.example.com/new.jpg")

        await store.uploadPhoto(data: bytes(1024))

        XCTAssertEqual(store.draft.photos.count, 1)
        XCTAssertEqual(store.draft.photos.first?.url, "https://cdn.example.com/new.jpg")
        if case .idle = store.draft.photos.first?.uploadState {
            // ok
        } else {
            XCTFail("expected .idle after success")
        }
    }

    /// 上传失败 → tile 转 .failed
    func test_uploadPhoto_failure_setsTileFailed() async {
        let (store, svc) = await makeLoadedStore()
        svc.uploadImageResult = .failure(URLError(.notConnectedToInternet))

        await store.uploadPhoto(data: bytes(1024))

        XCTAssertEqual(store.draft.photos.count, 1)
        if case .failed = store.draft.photos.first?.uploadState {
            // ok
        } else {
            XCTFail("expected .failed after failure")
        }
    }

    // MARK: - Upload Epoch: dispose 让 stale callback 被丢弃

    /// dispose 期间 upload 完成 → 结果被丢弃（tile 保持 uploading，不 markUploaded）
    func test_uploadPhoto_disposedDuringUpload_dropsResult() async {
        let (store, svc) = await makeLoadedStore()
        svc.delaySeconds = 0.1
        svc.uploadImageResult = .success("https://cdn.example.com/late.jpg")

        let uploadTask = Task { await store.uploadPhoto(data: bytes(1024)) }
        // 等 addPlaceholder 已加，upload 还在飞
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(store.draft.photos.count, 1)

        // dispose：epoch += 1；老 task 完成时 guard 丢弃
        store.dispose()

        await uploadTask.value

        // draft.photos.first.uploadState 应仍是 .uploading（未被 markUploaded 覆盖）
        if case .uploading = store.draft.photos.first?.uploadState {
            // ok
        } else {
            XCTFail("expected uploadState remain .uploading after dispose stale")
        }
    }
}
