import XCTest

/// H-2 spec §5 验收清单的 Store 层单测（正向 + 反向）。
@MainActor
final class P2PChatStoreTests: XCTestCase {

    // MARK: - Test factory

    private func makeStore(stub: [ChatMessage] = [],
                           sendResult: Result<String, Error> = .success("SVR-1"))
        -> (P2PChatStore, FakeP2PChatProvider) {
        let provider = FakeP2PChatProvider()
        provider.stubHistory = [nil: .success(stub)]
        provider.stubSendResult = sendResult
        let store = P2PChatStore(peerYxAccId: "peer", selfYxAccId: "self", provider: provider)
        return (store, provider)
    }

    // MARK: - 正向 P3/P6/P7/P9/P10 · 状态机

    func test_load_success_transitions_to_loaded() async {
        let m1 = ChatMessageFactory.make(id: "1", timestamp: 100)
        let (store, _) = makeStore(stub: [m1])
        await store.load()
        guard case .loaded(let all) = store.state else { return XCTFail("expect loaded") }
        XCTAssertEqual(all.map(\.id), ["1"])
    }

    func test_load_empty_transitions_to_empty() async {
        let (store, _) = makeStore(stub: [])
        await store.load()
        XCTAssertEqual(store.state, .empty)
    }

    /// P4: 进页调 markAllRead + P5: 对最后一条对端消息发 receipt
    func test_load_calls_markAllRead_and_sendReceipt_lastIncoming() async {
        let incoming = ChatMessageFactory.make(id: "in-1", isOutgoing: false)
        let outgoing = ChatMessageFactory.make(id: "out-1", isOutgoing: true)
        let (store, provider) = makeStore(stub: [outgoing, incoming, outgoing])
        await store.load()
        XCTAssertEqual(provider.stubMarkAllReadCalls, ["peer"])
        XCTAssertEqual(provider.stubReceiptCalls.count, 1)
        XCTAssertEqual(provider.stubReceiptCalls.first?.messageId, "in-1")
    }

    /// P6: 发文字 sending → sent
    func test_sendText_optimistic_then_sent() async {
        let (store, provider) = makeStore(stub: [])
        provider.stubSendResult = .success("SVR-99")
        await store.load()

        await store.sendText("hello")

        guard case .loaded(let all) = store.state, let msg = all.last else { return XCTFail() }
        XCTAssertEqual(msg.id, "SVR-99")
        XCTAssertEqual(msg.status, .sent)
        if case .text(let t) = msg.content { XCTAssertEqual(t, "hello") } else { XCTFail() }
        XCTAssertEqual(provider.stubSendTextCalls.count, 1)
    }

    /// P7: 发音频 uploading → sent（发送前是 .uploading，成功后 .sent）
    func test_sendAudio_starts_uploading_ends_sent() async {
        let (store, provider) = makeStore(stub: [])
        provider.stubSendResult = .success("SVR-audio")
        await store.load()

        let url = URL(string: "file:///tmp/a.m4a")!
        await store.sendAudio(localFilePath: "/tmp/a.m4a", dur: 5, previewURL: url)

        guard case .loaded(let all) = store.state, let msg = all.last else { return XCTFail() }
        XCTAssertEqual(msg.status, .sent)
        XCTAssertEqual(msg.id, "SVR-audio")
        if case .audio(_, let dur) = msg.content { XCTAssertEqual(dur, 5) } else { XCTFail() }
    }

    /// P9/P10: 发图片/视频（外链免上传主路径）
    func test_sendImage_and_sendVideo_success() async {
        let (store, provider) = makeStore(stub: [])
        provider.stubSendResult = .success("SVR-img")
        await store.load()

        let img = AnchorMediaItem(id: "1", mediaUrl: URL(string: "https://x/pic.jpg")!, coverUrl: nil, kind: .image, dur: nil)
        await store.sendImage(item: img)
        XCTAssertEqual(provider.stubSendImageCalls.count, 1)

        provider.stubSendResult = .success("SVR-vid")
        let vid = AnchorMediaItem(id: "2", mediaUrl: URL(string: "https://x/v.mp4")!, coverUrl: URL(string: "https://x/v.jpg"), kind: .video, dur: 10)
        await store.sendVideo(item: vid)
        XCTAssertEqual(provider.stubSendVideoCalls.count, 1)

        guard case .loaded(let all) = store.state, all.count == 2 else { return XCTFail() }
        XCTAssertEqual(all[0].id, "SVR-img")
        XCTAssertEqual(all[1].id, "SVR-vid")
    }

    // MARK: - 反向 R1/R2/R11 · 失败分流

    /// R1: 网络失败 → .failed（可重发）
    func test_sendText_retryable_error_transitions_to_failed() async {
        let (store, provider) = makeStore(stub: [])
        provider.stubSendResult = .failure(SendError.retryable(errorCode: nil))
        await store.load()

        await store.sendText("hi")

        guard case .loaded(let all) = store.state, let msg = all.last else { return XCTFail() }
        if case .failed = msg.status {} else { XCTFail("expect failed, got \(msg.status)") }
    }

    /// R2: 7101 拉黑 → .refused（禁重发）
    func test_sendText_refused_error_transitions_to_refused() async {
        let (store, provider) = makeStore(stub: [])
        provider.stubSendResult = .failure(SendError.refused(reason: "blocked"))
        await store.load()

        await store.sendText("hi")

        guard case .loaded(let all) = store.state, let msg = all.last else { return XCTFail() }
        if case .refused = msg.status {} else { XCTFail("expect refused") }
    }

    /// resend 从 .failed 恢复
    func test_resend_from_failed_message_succeeds() async {
        let (store, provider) = makeStore(stub: [])
        provider.stubSendResult = .failure(SendError.retryable(errorCode: "net"))
        await store.load()
        await store.sendText("hi")
        guard case .loaded(let msgs1) = store.state, let clientId = msgs1.last?.clientMsgId else { return XCTFail() }

        provider.stubSendResult = .success("SVR-retry")
        await store.resend(clientMsgId: clientId)

        guard case .loaded(let msgs2) = store.state, let final = msgs2.last else { return XCTFail() }
        XCTAssertEqual(final.status, .sent)
        XCTAssertEqual(final.id, "SVR-retry")
    }

    // MARK: - 反向 R14 · 已读回读

    func test_receipt_upgrades_outgoing_sent_to_read() async {
        let outSent = ChatMessageFactory.make(id: "o-1", from: "self", to: "peer",
                                              status: .sent, timestamp: 100, isOutgoing: true)
        let outLater = ChatMessageFactory.make(id: "o-2", from: "self", to: "peer",
                                               status: .sent, timestamp: 200, isOutgoing: true)
        let (store, _) = makeStore(stub: [outSent, outLater])
        await store.load()

        store.handleEvent(.receiptReceived(timestamp: 150))

        guard case .loaded(let all) = store.state else { return XCTFail() }
        XCTAssertEqual(all[0].status, .read, "timestamp<=150 应升级 read")
        XCTAssertEqual(all[1].status, .sent, "timestamp>150 保持 sent")
    }

    /// receipt 幂等：多次相同 receipt 不重复升级 / 不出错
    func test_receipt_is_idempotent() async {
        let out = ChatMessageFactory.make(id: "o-1", from: "self", to: "peer",
                                          status: .sent, timestamp: 100, isOutgoing: true)
        let (store, _) = makeStore(stub: [out])
        await store.load()
        store.handleEvent(.receiptReceived(timestamp: 150))
        store.handleEvent(.receiptReceived(timestamp: 150))
        guard case .loaded(let all) = store.state else { return XCTFail() }
        XCTAssertEqual(all.first?.status, .read)
    }

    // MARK: - 反向 R15 · loading 期 pending events

    /// loading 期 SDK 推增量 → 入队；loaded 后合并去重
    func test_delegate_event_during_loading_enqueued_and_merged() async {
        let provider = FakeP2PChatProvider()
        provider.stubHistory = [nil: .success([ChatMessageFactory.make(id: "1")])]
        provider.fetchSuspends = true

        let store = P2PChatStore(peerYxAccId: "peer", selfYxAccId: "self", provider: provider)
        let task = Task { await store.load() }
        await Task.yield()

        // 此时 fetch 挂起中，state=.loading
        XCTAssertEqual(store.state, .loading)
        // 增量事件入队
        provider.emit(.received([ChatMessageFactory.make(id: "2")]))
        // 释放 fetch
        provider.resumeFetch()
        await task.value

        guard case .loaded(let all) = store.state else { return XCTFail() }
        XCTAssertEqual(Set(all.map(\.id)), ["1", "2"], "pending 期入队的 add 事件应合并到 loaded")
    }

    // MARK: - 反向 R7 · 上拉分页

    /// pageSize=1 让首屏 1 条 = 满量（isEndReached=false），才允许 loadMore
    func test_loadMore_prepends_older_messages() async {
        let recent = ChatMessageFactory.make(id: "r", timestamp: 200)
        let older = ChatMessageFactory.make(id: "o", timestamp: 100)
        let provider = FakeP2PChatProvider()
        provider.stubHistory = [
            nil: .success([recent]),
            "r": .success([older])
        ]
        let store = P2PChatStore(peerYxAccId: "peer", selfYxAccId: "self", provider: provider, pageSize: 1)
        await store.load()
        XCTAssertFalse(store.isEndReached, "首屏返 1 条 = pageSize，未到底")

        await store.loadMore()

        guard case .loaded(let all) = store.state else { return XCTFail() }
        XCTAssertEqual(all.map(\.id), ["o", "r"], "上拉 prepend 更旧到列表头")
    }

    func test_loadMore_empty_sets_isEndReached() async {
        let recent = ChatMessageFactory.make(id: "r")
        let provider = FakeP2PChatProvider()
        provider.stubHistory = [
            nil: .success([recent]),
            "r": .success([])
        ]
        // 用 pageSize=1 让首屏不误判 endReached，测上拉真正拉空→endReached
        let store = P2PChatStore(peerYxAccId: "peer", selfYxAccId: "self", provider: provider, pageSize: 1)
        await store.load()
        XCTAssertFalse(store.isEndReached)

        await store.loadMore()

        XCTAssertTrue(store.isEndReached, "上拉返 0 条 → isEndReached")
    }

    // MARK: - 收到新消息 → badge 计数 + 自动回执

    func test_received_events_bump_badge_and_send_receipt() async {
        let (store, provider) = makeStore(stub: [ChatMessageFactory.make(id: "1")])
        await store.load()
        provider.stubReceiptCalls.removeAll()

        store.handleEvent(.received([
            ChatMessageFactory.make(id: "in-1", isOutgoing: false),
            ChatMessageFactory.make(id: "in-2", isOutgoing: false),
        ]))
        // sendReceipt 是异步（Task），需 yield 触发
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(store.pendingBottomBadge, 2)
        XCTAssertEqual(provider.stubReceiptCalls.first?.messageId, "in-2", "回执给最后一条对端消息")
    }

    /// 增量事件 messageId 去重
    func test_received_events_dedupe_by_messageId() async {
        let existing = ChatMessageFactory.make(id: "1")
        let (store, _) = makeStore(stub: [existing])
        await store.load()

        store.handleEvent(.received([existing, ChatMessageFactory.make(id: "2")]))

        guard case .loaded(let all) = store.state else { return XCTFail() }
        XCTAssertEqual(all.map(\.id), ["1", "2"])
    }
}
