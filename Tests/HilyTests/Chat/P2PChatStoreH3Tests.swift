import XCTest

/// H-3 Step 1a-5：P2PChatStore.sendPrivateImage/Video 状态机 + 前置 sendPrivateInfo 调用 + 失败分类。
///
/// 覆盖 spec §F-2/F-3 + §R-3（apiGetSendPrivateInfo 失败）+ Critical-2（前置调用 + signedData 塞入 provider）
/// + Critical-3（remoteExt 组装由 provider 层测；本层验 Store call 参数）+ SendError 分流。
@MainActor
final class P2PChatStoreH3Tests: XCTestCase {

    // MARK: - Test factory

    private func makeStore(
        stub: [ChatMessage] = [],
        sendResult: Result<String, Error> = .success("SVR-1"),
        sendPrivateInfoResult: Result<[String: Any], Error> = .success(["privateId": "p-1", "giftId": 100]),
        includeSendPrivateInfoService: Bool = true
    ) -> (P2PChatStore, FakeP2PChatProvider, FakeSendPrivateInfoService?) {
        let provider = FakeP2PChatProvider()
        provider.stubHistory = [nil: .success(stub)]
        provider.stubSendResult = sendResult

        let sendInfoService: FakeSendPrivateInfoService? = {
            if !includeSendPrivateInfoService { return nil }
            let s = FakeSendPrivateInfoService()
            s.stubResult = sendPrivateInfoResult
            return s
        }()

        let store = P2PChatStore(
            peerYxAccId: "peer",
            selfYxAccId: "self",
            provider: provider,
            sendPrivateInfoService: sendInfoService
        )
        return (store, provider, sendInfoService)
    }

    /// helper：从 store.state 提取消息列表
    private func loadedMessages(_ store: P2PChatStore) -> [ChatMessage] {
        if case .loaded(let msgs) = store.state { return msgs }
        return []
    }

    private func makeImageSelection(privateId: String = "priv-abc") -> PrivateMediaSelection {
        PrivateMediaSelection(
            privateId: privateId,
            iconType: 1,
            url: URL(string: "https://cdn.example.com/private.jpg")!,
            coverUrl: nil,
            dur: nil
        )
    }

    private func makeVideoSelection(privateId: String = "priv-vid") -> PrivateMediaSelection {
        PrivateMediaSelection(
            privateId: privateId,
            iconType: 2,
            url: URL(string: "https://cdn.example.com/private.mp4")!,
            coverUrl: URL(string: "https://cdn.example.com/private.jpg"),
            dur: 30
        )
    }

    // MARK: - sendPrivateImage 成功路径（§F-2 / Critical-2）

    func testSendPrivateImage_Success_OptimisticAppendThenSent() async {
        let (store, provider, sendInfoSvc) = makeStore()
        provider.stubSendResult = .success("SVR-privImg-1")
        await store.load()

        let media = makeImageSelection(privateId: "abc-123")
        await store.sendPrivateImage(peerUserId: "peer-user-99", media: media)

        // 前置 sendPrivateInfoService 被调用（Critical-2）
        XCTAssertEqual(sendInfoSvc?.calls.count, 1)
        XCTAssertEqual(sendInfoSvc?.calls.first?.peerUserId, "peer-user-99")
        XCTAssertEqual(sendInfoSvc?.calls.first?.privateId, "abc-123")

        // provider.sendPrivateImage 被调用，signedData 已传入
        XCTAssertEqual(provider.stubSendPrivateImageCalls.count, 1)
        let call = provider.stubSendPrivateImageCalls.first!
        XCTAssertEqual(call.peer, "peer")
        XCTAssertEqual(call.peerUserId, "peer-user-99")
        XCTAssertEqual(call.privateId, "abc-123")
        XCTAssertEqual(call.url.absoluteString, "https://cdn.example.com/private.jpg")
        XCTAssertNotNil(call.signedData["giftId"])   // 后端签发字段透传

        // 状态迁移到 .sent
        let msgs = loadedMessages(store)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs.first?.status, .sent)
        XCTAssertEqual(msgs.first?.id, "SVR-privImg-1")
        XCTAssertEqual(msgs.first?.privateId, "abc-123", "乐观 msg 保留 privateId 字段")

        // content 是 .privateImage lockStatus=.unknown（初始）
        if case .privateImage(_, let lockStatus) = msgs.first?.content {
            XCTAssertEqual(lockStatus, .unknown, "乐观 msg lockStatus=.unknown；checkPrivateInfo 后由 Store 层更新")
        } else {
            XCTFail("expect .privateImage content")
        }
    }

    // MARK: - sendPrivateVideo 成功路径（§F-3）

    func testSendPrivateVideo_Success_OptimisticAppendThenSent() async {
        let (store, provider, sendInfoSvc) = makeStore()
        provider.stubSendResult = .success("SVR-privVid-1")
        await store.load()

        let media = makeVideoSelection(privateId: "vid-999")
        await store.sendPrivateVideo(peerUserId: "peer-user-99", media: media)

        XCTAssertEqual(sendInfoSvc?.calls.count, 1)
        XCTAssertEqual(provider.stubSendPrivateVideoCalls.count, 1)
        let call = provider.stubSendPrivateVideoCalls.first!
        XCTAssertEqual(call.peerUserId, "peer-user-99")
        XCTAssertEqual(call.dur, 30)
        XCTAssertEqual(call.thumbnailUrl?.absoluteString, "https://cdn.example.com/private.jpg")
        XCTAssertEqual(call.privateId, "vid-999")

        let msgs = loadedMessages(store)
        XCTAssertEqual(msgs.first?.status, .sent)
        if case .privateVideo(_, let cover, let dur, let lockStatus) = msgs.first?.content {
            XCTAssertEqual(cover?.absoluteString, "https://cdn.example.com/private.jpg")
            XCTAssertEqual(dur, 30)
            XCTAssertEqual(lockStatus, .unknown)
        } else {
            XCTFail("expect .privateVideo content")
        }
    }

    // MARK: - 失败分支（§R-3）

    /// R-3：apiGetSendPrivateInfo 失败 → NIM 不调 + status=.failed(retryable "signPrivate")
    func testSendPrivateImage_SignFailure_NoProviderCallStatusFailed() async {
        struct SignError: Error {}
        let (store, provider, sendInfoSvc) = makeStore(
            sendPrivateInfoResult: .failure(SignError())
        )
        await store.load()

        await store.sendPrivateImage(peerUserId: "peer-user", media: makeImageSelection())

        XCTAssertEqual(sendInfoSvc?.calls.count, 1)
        XCTAssertEqual(provider.stubSendPrivateImageCalls.count, 0, "sign 失败后 provider 不调")

        let msgs = loadedMessages(store)
        XCTAssertEqual(msgs.count, 1)
        if case .failed(let code) = msgs.first?.status {
            XCTAssertEqual(code, "signPrivate")
        } else {
            XCTFail("expect .failed status")
        }
    }

    /// NIM SendError.refused (7101 拉黑) → status=.refused
    func testSendPrivateImage_ProviderRefused_StatusRefused() async {
        let (store, provider, _) = makeStore(
            sendResult: .failure(SendError.refused(reason: "blocked_by_peer"))
        )
        await store.load()

        await store.sendPrivateImage(peerUserId: "peer-user", media: makeImageSelection())

        let msgs = loadedMessages(store)
        if case .refused = msgs.first?.status {
            // OK
        } else {
            XCTFail("expect .refused")
        }
    }

    /// NIM SendError.retryable → status=.failed(errorCode)
    func testSendPrivateImage_ProviderRetryable_StatusFailed() async {
        let (store, provider, _) = makeStore(
            sendResult: .failure(SendError.retryable(errorCode: "network"))
        )
        await store.load()

        await store.sendPrivateImage(peerUserId: "peer-user", media: makeImageSelection())

        let msgs = loadedMessages(store)
        if case .failed(let code) = msgs.first?.status {
            XCTAssertEqual(code, "network")
        } else {
            XCTFail("expect .failed status")
        }
    }

    // MARK: - iconType mismatch / service nil 短路

    /// iconType=2 传给 sendPrivateImage → 直接短路（防 caller 误传）
    func testSendPrivateImage_IconTypeMismatch_ShortCircuits() async {
        let (store, provider, sendInfoSvc) = makeStore()
        await store.load()

        let video = makeVideoSelection()   // iconType=2
        await store.sendPrivateImage(peerUserId: "peer-user", media: video)

        XCTAssertEqual(sendInfoSvc?.calls.count, 0)
        XCTAssertEqual(provider.stubSendPrivateImageCalls.count, 0)
        XCTAssertEqual(loadedMessages(store).count, 0)
    }

    /// iconType=1 传给 sendPrivateVideo → 短路
    func testSendPrivateVideo_IconTypeMismatch_ShortCircuits() async {
        let (store, provider, sendInfoSvc) = makeStore()
        await store.load()

        let image = makeImageSelection()   // iconType=1
        await store.sendPrivateVideo(peerUserId: "peer-user", media: image)

        XCTAssertEqual(sendInfoSvc?.calls.count, 0)
        XCTAssertEqual(provider.stubSendPrivateVideoCalls.count, 0)
        XCTAssertEqual(loadedMessages(store).count, 0)
    }

    /// sendPrivateInfoService=nil → 短路（H-2 兼容路径）
    func testSendPrivateImage_ServiceNil_ShortCircuits() async {
        let (store, provider, _) = makeStore(includeSendPrivateInfoService: false)
        await store.load()

        await store.sendPrivateImage(peerUserId: "peer-user", media: makeImageSelection())

        XCTAssertEqual(provider.stubSendPrivateImageCalls.count, 0)
        XCTAssertEqual(loadedMessages(store).count, 0)
    }
}
