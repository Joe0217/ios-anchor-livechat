import XCTest

/// H-2 GiftMessageStore 单测（spec §3 不变量 + §4 关键反向）。
@MainActor
final class GiftMessageStoreTests: XCTestCase {

    // MARK: - LoadAll

    func test_loadAll_success_setsLoaded() async {
        let svc = FakeGiftMessageService()
        svc.limitResult = .success(PrivateMediaLimit(privateNum: 3, privateVedioNum: 3))
        svc.listResult = .success([
            .fixture(id: "img1", iconType: 1),
            .fixture(id: "vid1", iconType: 2, originalUrl: "https://oss.test/v.mp4"),
        ])
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())

        await store.loadAll()

        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertEqual(store.imagesEdit.count, 1)
        XCTAssertEqual(store.videosEdit.count, 1)
        XCTAssertEqual(store.limit.privateNum, 3)
    }

    func test_loadAll_limitFails_defaultsFallback() async {
        let svc = FakeGiftMessageService()
        svc.limitResult = .failure(GiftMessageStubError(kind: "limit-fail"))
        svc.listResult = .success([])
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())

        await store.loadAll()

        XCTAssertEqual(store.limit, .default, "限额失败走默认 3/3（spec R-1）")
        XCTAssertEqual(store.loadState, .loaded)
    }

    func test_loadAll_listFails_setsError() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .failure(APIError(code: "1080", message: "list-error"))
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())

        await store.loadAll()

        guard case .error(let msg) = store.loadState else {
            return XCTFail("expected error, got \(store.loadState)")
        }
        XCTAssertEqual(msg, "list-error")
    }

    func test_loadAll_whileLoading_isNoop() async {
        let svc = FakeGiftMessageService()
        svc.delaySeconds = 0.1
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())

        async let first: Void = store.loadAll()
        try? await Task.sleep(nanoseconds: 10_000_000)
        await store.loadAll()
        await first

        XCTAssertEqual(svc.fetchListCallCount, 1, "loading 中再触发 noop（不变量 #1）")
    }

    // MARK: - Video 解密

    func test_loadAll_videoDecrypted() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .success([
            .fixture(id: "v1", iconType: 2, originalUrl: "https://oss.test/v1.mp4"),
        ])
        svc.decryptResult = .success("https://cdn.test/v1.mp4?token=abc")
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())

        await store.loadAll()

        XCTAssertEqual(store.videosEdit.first?.signedUrl, "https://cdn.test/v1.mp4?token=abc")
        XCTAssertNotNil(store.videosEdit.first?.signedAt)
    }

    func test_loadAll_videoDecryptFails_signedUrlNil() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .success([.fixture(id: "v1", iconType: 2)])
        svc.decryptResult = .failure(GiftMessageStubError(kind: "decrypt-fail"))
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())

        await store.loadAll()

        XCTAssertNil(store.videosEdit.first?.signedUrl, "解密失败 signedUrl 保 nil，页面级不报错（R-3）")
        XCTAssertEqual(store.loadState, .loaded)
    }

    // MARK: - Upload Image

    func test_uploadImage_success_appendsAndOpensGiftPicker() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .success([])
        let upl = FakePrivateMediaUploadService()
        upl.uploadImageResult = .success("https://oss.test/new.jpg")
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: upl)
        await store.loadAll()

        await store.uploadImage(data: Data([1, 2, 3]))

        XCTAssertEqual(store.imagesEdit.count, 1)
        XCTAssertTrue(store.imagesEdit.first?.isNew ?? false, "新增项应为 local_ 前缀")
        XCTAssertEqual(store.imagesEdit.first?.originalUrl, "https://oss.test/new.jpg")
        XCTAssertTrue(store.showingGiftPicker, "上传成功自动弹礼物 sheet")
        XCTAssertEqual(store.pendingCategory, 1)
    }

    func test_uploadImage_reachedLimit_noop() async {
        let svc = FakeGiftMessageService()
        svc.limitResult = .success(PrivateMediaLimit(privateNum: 1, privateVedioNum: 3))
        svc.listResult = .success([.fixture(id: "img1", iconType: 1)])
        let upl = FakePrivateMediaUploadService()
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: upl)
        await store.loadAll()

        await store.uploadImage(data: Data([1, 2, 3]))

        XCTAssertEqual(store.imagesEdit.count, 1, "已达上限，新上传拒绝")
        XCTAssertNotNil(store.transientError)
        XCTAssertEqual(upl.uploadImageCalls.count, 0, "upload service 不调用")
    }

    func test_uploadImage_failure_showsTransientError() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .success([])
        let upl = FakePrivateMediaUploadService()
        upl.uploadImageResult = .failure(APIError(code: "x", message: "upload-fail"))
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: upl)
        await store.loadAll()

        await store.uploadImage(data: Data([1, 2, 3]))

        XCTAssertEqual(store.imagesEdit.count, 0, "失败不加项")
        XCTAssertEqual(store.transientError, "upload-fail")
    }

    // MARK: - GiftBinding（v2 修 H5 bug）

    func test_bindGift_updatesCorrectCategory() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .success([])
        let upl = FakePrivateMediaUploadService()
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: upl)
        await store.loadAll()
        await store.uploadImage(data: Data([1]))

        store.bindGift(.fixture(id: "50", name: "Diamond", price: 500))

        XCTAssertEqual(store.imagesEdit.first?.giftId, "50")
        XCTAssertEqual(store.imagesEdit.first?.giftName, "Diamond")
        XCTAssertEqual(store.imagesEdit.first?.giftPrice, 500)
        XCTAssertFalse(store.showingGiftPicker)
        XCTAssertNil(store.pendingBindId)
    }

    func test_cancelGiftBinding_image_popsImagesOnly() async {
        // v2 修 H5 bug：pop 应按 pendingCategory 定位，非无差别 pop 图片
        let svc = FakeGiftMessageService()
        svc.listResult = .success([])
        let upl = FakePrivateMediaUploadService()
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: upl)
        await store.loadAll()
        await store.uploadImage(data: Data([1]))
        XCTAssertEqual(store.imagesEdit.count, 1)

        store.cancelGiftBinding()

        XCTAssertEqual(store.imagesEdit.count, 0, "关闭未选 → pop 图片")
        XCTAssertFalse(store.showingGiftPicker)
    }

    func test_cancelGiftBinding_video_popsVideosOnly() async {
        // v2 关键测试：视频取消不应误删图片（修 H5 giftCloseOverlay bug）
        let svc = FakeGiftMessageService()
        svc.listResult = .success([.fixture(id: "img_pre", iconType: 1)])
        let upl = FakePrivateMediaUploadService()
        upl.uploadVideoResult = .success("https://oss.test/new.mp4")
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: upl)
        await store.loadAll()
        XCTAssertEqual(store.imagesEdit.count, 1, "原图片保留")

        // 模拟视频上传中
        await store.uploadVideo(fileURL: URL(string: "file:///tmp/v.mp4")!)
        XCTAssertEqual(store.pendingCategory, 2)

        store.cancelGiftBinding()

        XCTAssertEqual(store.imagesEdit.count, 1, "原图片不受视频取消影响（修 H5 bug）")
        XCTAssertEqual(store.videosEdit.count, 0, "视频被 pop")
    }

    // MARK: - Remove

    func test_remove_image() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .success([
            .fixture(id: "img1", iconType: 1),
            .fixture(id: "img2", iconType: 1),
        ])
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())
        await store.loadAll()

        store.remove(itemId: "img1", category: 1)

        XCTAssertEqual(store.imagesEdit.count, 1)
        XCTAssertEqual(store.imagesEdit.first?.id, "img2")
    }

    // MARK: - Submit + Diff

    func test_submit_success_computesDiff() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .success([.fixture(id: "img1", iconType: 1, giftId: "100")])
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())
        await store.loadAll()

        // 删除 img1 + 添加新的（模拟：修改 imagesEdit）
        store.remove(itemId: "img1", category: 1)

        let ok = await store.submit()

        XCTAssertTrue(ok)
        XCTAssertEqual(svc.saveCalls.count, 1)
        let ops = svc.saveCalls.first!
        // 删除项 removePrivate=true
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.removePrivate, true)
        XCTAssertEqual(ops.first?.id, "img1")
    }

    func test_submit_pendingItemWithoutGift_fails() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .success([])
        let upl = FakePrivateMediaUploadService()
        upl.uploadImageResult = .success("https://oss.test/new.jpg")
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: upl)
        await store.loadAll()
        await store.uploadImage(data: Data([1]))
        // 不 bindGift 直接 submit

        let ok = await store.submit()

        XCTAssertFalse(ok, "有未绑礼物项拒绝 submit（不变量 #3 变体）")
        XCTAssertNotNil(store.transientError)
        XCTAssertEqual(svc.saveCalls.count, 0)
    }

    func test_submit_failure_showsError() async {
        let svc = FakeGiftMessageService()
        svc.listResult = .success([])
        svc.saveResult = .failure(APIError(code: "x", message: "save-fail"))
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())
        await store.loadAll()

        let ok = await store.submit()

        XCTAssertFalse(ok)
        XCTAssertEqual(store.transientError, "save-fail")
    }

    // MARK: - canSubmit / canAddImage / canAddVideo 派生

    func test_canAddImage_truthTable() async {
        let svc = FakeGiftMessageService()
        svc.limitResult = .success(PrivateMediaLimit(privateNum: 2, privateVedioNum: 2))
        svc.listResult = .success([.fixture(id: "img1", iconType: 1)])
        let store = GiftMessageStore(userId: 100, service: svc, uploadService: FakePrivateMediaUploadService())
        await store.loadAll()

        XCTAssertTrue(store.canAddImage, "1/2 可加")

        // 模拟已达上限
        await store.uploadImage(data: Data([1]))
        XCTAssertFalse(store.canAddImage, "2/2 达上限")
    }
}
