import XCTest

/// PostPublishViewModel 状态机单测（spec §5 反向用例一一对应）。
///
/// 覆盖：R1/R2/R3/R4/R6/R8/R9/R10/R13/R18/R19/R20/INV4
@MainActor
final class PostPublishViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeVM(service: FakePostPublishService = FakePostPublishService(),
                        credentialService: FakeOssCredentialService = FakeOssCredentialService(),
                        ossService: FakeOssUploadService = FakeOssUploadService(),
                        compressImage: @escaping (Data) throws -> Data = { $0 },
                        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 })
                       -> PostPublishViewModel {
        PostPublishViewModel(
            service: service,
            credentialService: credentialService,
            ossService: ossService,
            compressImage: compressImage,
            nowEpoch: now,
            strings: .englishFallback
        )
    }

    private func waitFor(_ vm: PostPublishViewModel,
                         matching predicate: @escaping (PostingState) -> Bool,
                         timeout: TimeInterval = 1.0) async -> Bool {
        let start = Date()
        while !predicate(vm.state) {
            if Date().timeIntervalSince(start) > timeout { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    private func bytes(_ n: Int) -> Data { Data(repeating: 0x00, count: n) }

    // MARK: - R1: 文本空 + 有图

    func test_R1_publish_emptyText_setsTextEmpty() {
        let vm = makeVM()
        vm.text = ""
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        guard case .failed(let reason, _) = vm.state else {
            XCTFail("expected .failed, got \(vm.state)"); return
        }
        XCTAssertEqual(reason, .textEmpty)
        XCTAssertEqual(vm.transientError, "Please enter content")
    }

    // MARK: - R2: 文本非空 + 无图

    func test_R2_publish_noImages_setsNoImages() {
        let vm = makeVM()
        vm.text = "hello"
        vm.publish()
        guard case .failed(let reason, _) = vm.state else {
            XCTFail("expected .failed, got \(vm.state)"); return
        }
        XCTAssertEqual(reason, .noImages)
    }

    // MARK: - R3: 500 字精确

    func test_R3_publish_text500_accepted() async {
        let vm = makeVM()
        vm.text = String(repeating: "a", count: 500)
        vm.appendImage(rawData: bytes(100))
        XCTAssertTrue(vm.canPublish)
        XCTAssertEqual(vm.text.count, 500)
    }

    // MARK: - R4: 501 字截断

    func test_R4_publish_text501_truncatedTo500() {
        let vm = makeVM()
        vm.text = String(repeating: "a", count: 501)
        XCTAssertEqual(vm.text.count, 500, "粘贴超长应被截断到 500（didSet 守）")
    }

    // MARK: - R6: STS 失败

    func test_R6_publish_credentialFailed_setsFailed() async {
        let credSvc = FakeOssCredentialService()
        credSvc.results = [.failure(APIError(code: "9999", message: "STS down"))]
        let vm = makeVM(credentialService: credSvc)
        vm.text = "hi"
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        _ = await waitFor(vm) { if case .failed(.credentialFailed, _) = $0 { return true }; return false }
        if case .failed(let reason, _) = vm.state {
            XCTAssertEqual(reason, .credentialFailed)
        } else {
            XCTFail("expected .failed(.credentialFailed)")
        }
    }

    // MARK: - R8: 第 3 张失败，保留前 2 个 url

    func test_R8_uploadFailed_atThirdImage_keepsFirstTwoUrls() async {
        let oss = FakeOssUploadService()
        oss.results = [
            .success("url-0"),
            .success("url-1"),
            .failure(OssUploadError.network),  // 第 3 张失败
        ]
        let vm = makeVM(ossService: oss)
        vm.text = "hi"
        for _ in 0..<5 { vm.appendImage(rawData: bytes(100)) }
        vm.publish()

        _ = await waitFor(vm) { if case .failed(.uploadFailed, _) = $0 { return true }; return false }
        guard case .failed(let reason, let uploaded) = vm.state else {
            XCTFail("expected .failed"); return
        }
        XCTAssertEqual(reason, .uploadFailed(idx: 2))
        XCTAssertEqual(uploaded[0], "url-0", "已成功的 idx 0 应保留")
        XCTAssertEqual(uploaded[1], "url-1", "已成功的 idx 1 应保留")
        XCTAssertNil(uploaded[2], "失败的 idx 不应在 uploadedUrls")
        XCTAssertEqual(oss.uploadCalls.count, 3, "失败后不应继续上传后续 idx（顺序上传天然 break）")
    }

    // MARK: - R8 续：retry 跳过已成功 idx，仅传剩余

    func test_R8_retry_afterUploadFailed_skipsAlreadyUploaded() async {
        let oss = FakeOssUploadService()
        oss.results = [
            .success("url-0"),
            .failure(OssUploadError.network),
            // retry 时只剩 idx 1+，重试用新的 results
        ]
        let vm = makeVM(ossService: oss)
        vm.text = "hi"
        for _ in 0..<3 { vm.appendImage(rawData: bytes(100)) }
        vm.publish()
        _ = await waitFor(vm) { if case .failed = $0 { return true }; return false }

        // 调整 fake：剩下两张成功
        oss.results.append(.success("url-1"))
        oss.results.append(.success("url-2"))
        vm.retry()
        _ = await waitFor(vm) { if case .success = $0 { return true }; return false }

        // upload 调用总数：3（初次 0/1/2 失败 idx 1）+ 2（retry idx 1/2）= 5? 不对——
        // 实际：初次 0 成功 + 1 失败 = 2 次；retry 跳过 0 (uploaded[0] 已有)，上传 1/2 = 2 次。共 4 次
        XCTAssertEqual(oss.uploadCalls.count, 4,
                       "retry 应跳过 idx 0（已成功），仅传 idx 1/2")
        XCTAssertEqual(vm.state, .success)
    }

    // MARK: - R9: create 失败保留 uploadedUrls

    func test_R9_createFailed_keepsAllUploadedUrls() async {
        let svc = FakePostPublishService()
        svc.createResult = .failure(APIError(code: "9999", message: "create down"))
        let oss = FakeOssUploadService()
        oss.results = [.success("u0"), .success("u1")]
        let vm = makeVM(service: svc, ossService: oss)
        vm.text = "hi"
        vm.appendImage(rawData: bytes(100))
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        _ = await waitFor(vm) { if case .failed(.createFailed, _) = $0 { return true }; return false }
        guard case .failed(let reason, let uploaded) = vm.state else {
            XCTFail("expected .failed"); return
        }
        if case .createFailed(let msg) = reason {
            XCTAssertEqual(msg, "create down")
        } else {
            XCTFail("expected .createFailed, got \(reason)")
        }
        XCTAssertEqual(uploaded.count, 2, "create 失败时 uploadedUrls 全保留")
    }

    // MARK: - R9 续：retry create 不重传图

    func test_R9_retry_afterCreateFailed_doesNotReupload() async {
        let svc = FakePostPublishService()
        svc.createResult = .failure(APIError(code: "9999", message: "down"))
        let oss = FakeOssUploadService()
        oss.results = [.success("u0"), .success("u1")]
        let vm = makeVM(service: svc, ossService: oss)
        vm.text = "hi"
        vm.appendImage(rawData: bytes(100))
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        _ = await waitFor(vm) { if case .failed(.createFailed, _) = $0 { return true }; return false }

        // retry：create 这次成功
        svc.createResult = .success(())
        vm.retry()
        _ = await waitFor(vm) { if case .success = $0 { return true }; return false }

        XCTAssertEqual(oss.uploadCalls.count, 2, "retry create 不应再传图")
        XCTAssertEqual(svc.createCalls.count, 2, "create 被调 2 次（首次失败 + retry 成功）")
        XCTAssertEqual(svc.createCalls.last?.imgUrls, ["u0", "u1"])
    }

    // MARK: - R10: 业务码非 0000 + R22 不区分审核拒绝

    func test_R10_createBusinessError_setsFailed_withMessage() async {
        let svc = FakePostPublishService()
        svc.createResult = .failure(APIError(code: "2002", message: "内容违规"))
        let oss = FakeOssUploadService()
        oss.results = [.success("u")]
        let vm = makeVM(service: svc, ossService: oss)
        vm.text = "x"
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        _ = await waitFor(vm) { if case .failed(.createFailed, _) = $0 { return true }; return false }
        guard case .failed(.createFailed(let msg), let uploaded) = vm.state else {
            XCTFail(); return
        }
        XCTAssertEqual(msg, "内容违规", "审核拒绝走通用 createFailed 按 message（v3）")
        XCTAssertEqual(vm.transientError, "内容违规")
        XCTAssertEqual(uploaded.count, 1, "v3：审核拒绝不清 uploadedUrls")
    }

    // MARK: - R13: 防双发布

    func test_R13_publish_alreadySuccess_secondCallIgnored() async {
        let svc = FakePostPublishService()
        let oss = FakeOssUploadService()
        oss.results = [.success("u")]
        let vm = makeVM(service: svc, ossService: oss)
        vm.text = "x"
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        _ = await waitFor(vm) { if case .success = $0 { return true }; return false }

        vm.publish()  // 第二次
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(svc.createCalls.count, 1, "second publish 应被 R13 守住")
        XCTAssertEqual(oss.uploadCalls.count, 1)
    }

    // MARK: - R18: STS 凭证过期预检

    func test_R18_credentialNearExpiry_refetchesBeforeUpload() async {
        let credSvc = FakeOssCredentialService()
        // 第一次返还剩 100s 的凭证（< 300s 安全边际 → 不应被用，应触发重拉，但 fake 第 0 个返）
        let nearExpiry = OssCredential.fixture(future: 100)  // 100s 后过期
        let fresh = OssCredential.fixture(future: 7200)
        credSvc.results = [.success(nearExpiry), .success(fresh)]
        let oss = FakeOssUploadService()
        oss.results = [.success("u")]
        let vm = makeVM(credentialService: credSvc, ossService: oss)
        vm.text = "x"
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        _ = await waitFor(vm) { if case .success = $0 { return true }; return false }

        XCTAssertGreaterThanOrEqual(credSvc.calls, 2,
            "近过期凭证应触发预检重拉")
    }

    // MARK: - R19: OSS SecurityTokenExpired 自动重拉

    func test_R19_ossExpiredToken_autoRefetchUpTo2Times() async {
        let credSvc = FakeOssCredentialService()
        // 3 次 STS 凭证（够 2 次重拉）
        credSvc.results = [
            .success(OssCredential.fixture()),
            .success(OssCredential.fixture()),
            .success(OssCredential.fixture()),
        ]
        let oss = FakeOssUploadService()
        // 第 1 次返 token expired，第 2 次成功
        oss.results = [
            .failure(OssUploadError.http(statusCode: 403, body: "SecurityTokenExpired")),
            .success("u"),
        ]
        let vm = makeVM(credentialService: credSvc, ossService: oss)
        vm.text = "x"
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        _ = await waitFor(vm) { if case .success = $0 { return true }; return false }

        XCTAssertGreaterThanOrEqual(credSvc.calls, 2, "应重拉 STS")
        XCTAssertEqual(vm.state, .success)
    }

    func test_R19_credentialRefreshExceedsLimit_setsCredentialFailed() async {
        let credSvc = FakeOssCredentialService()
        // STS 总能成功
        credSvc.results = [
            .success(OssCredential.fixture()),
            .success(OssCredential.fixture()),
            .success(OssCredential.fixture()),
            .success(OssCredential.fixture()),
        ]
        let oss = FakeOssUploadService()
        // 一直 SecurityTokenExpired → 触发重拉
        oss.results = [
            .failure(OssUploadError.http(statusCode: 403, body: "SecurityTokenExpired")),
            .failure(OssUploadError.http(statusCode: 403, body: "SecurityTokenExpired")),
            .failure(OssUploadError.http(statusCode: 403, body: "SecurityTokenExpired")),
        ]
        oss.fallbackResult = .failure(OssUploadError.http(statusCode: 403, body: "SecurityTokenExpired"))
        let vm = makeVM(credentialService: credSvc, ossService: oss)
        vm.text = "x"
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        _ = await waitFor(vm) { if case .failed(.credentialFailed, _) = $0 { return true }; return false }

        guard case .failed(let reason, _) = vm.state else {
            XCTFail(); return
        }
        XCTAssertEqual(reason, .credentialFailed, "超出 2 次重拉应转 credentialFailed")
    }

    // MARK: - INV4: 发布成功广播 .momentPublished

    func test_INV4_publish_success_postsMomentPublishedNotification() async {
        let svc = FakePostPublishService()
        let oss = FakeOssUploadService()
        oss.results = [.success("u")]
        let vm = makeVM(service: svc, ossService: oss)

        var observed = false
        let observer = NotificationCenter.default.addObserver(
            forName: .momentPublished, object: nil, queue: nil
        ) { _ in observed = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        vm.text = "x"
        vm.appendImage(rawData: bytes(100))
        vm.publish()
        _ = await waitFor(vm) { if case .success = $0 { return true }; return false }
        // 给 NotificationCenter 一点时间投递
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(observed, "INV4：发布成功必须 post .momentPublished")
    }

    // MARK: - canPublish 派生 + F5/F7

    func test_canPublish_falseWhenEmptyOrInProgress() async {
        let vm = makeVM()
        XCTAssertFalse(vm.canPublish, "空 → false")
        vm.text = "x"
        XCTAssertFalse(vm.canPublish, "仅文本 → false（H5 强制 ≥1 图）")
        vm.appendImage(rawData: bytes(100))
        XCTAssertTrue(vm.canPublish, "文本 + 图 → true")
        vm.publish()
        // 此时状态机已变（uploadingImages），canPublish=false
        XCTAssertFalse(vm.canPublish, "进行中 → false（R13 防双发）")
    }

    // MARK: - F5: 9 张图后选择按钮 disable

    func test_F5_appendImageBeyond9_isNoop() {
        let vm = makeVM()
        for _ in 0..<10 {
            vm.appendImage(rawData: bytes(100))
        }
        XCTAssertEqual(vm.imageDataList.count, 9, "最多 9 张")
    }

    // MARK: - 选图阶段拦截大图

    func test_appendImage_rejectsOverLimit() {
        let vm = makeVM()
        let bigData = bytes(11 * 1024 * 1024)  // 11MB > 10MB
        vm.appendImage(rawData: bigData)
        XCTAssertEqual(vm.imageDataList.count, 0, "> 10MB 拒绝入 imgs")
        XCTAssertNotNil(vm.transientError, "应有 toast 提示")
    }
}
