import Foundation

/// HilyTests 用 P2P chat provider Fake（step 1a/1c 共用）。
@MainActor
final class FakeP2PChatProvider: P2PChatProviderProtocol {

    // MARK: - Stubs

    var stubHistory: [String?: Result<[ChatMessage], Error>] = [nil: .success([])]
    var stubSendResult: Result<String, Error> = .success("SVR-1")
    var stubReceiptCalls: [(peer: String, messageId: String)] = []
    var stubMarkAllReadCalls: [String] = []
    var stubSendTextCalls: [(peer: String, text: String, clientMsgId: String)] = []
    var stubSendAudioCalls: [(peer: String, path: String, dur: Int, clientMsgId: String)] = []
    var stubSendImageCalls: [(peer: String, url: URL, clientMsgId: String)] = []
    var stubSendVideoCalls: [(peer: String, url: URL, coverUrl: URL?, dur: Int, clientMsgId: String)] = []

    /// fetchHistory 是否挂起等 resumeFetch()（复现 loading 期事件入队场景）
    var fetchSuspends: Bool = false
    private var fetchResumeHandle: CheckedContinuation<Void, Never>?

    func resumeFetch() {
        fetchResumeHandle?.resume()
        fetchResumeHandle = nil
    }

    // MARK: - Delegate handler

    private var handler: (@MainActor (P2PChatEvent) -> Void)?

    func emit(_ event: P2PChatEvent) {
        handler?(event)
    }

    // MARK: - Protocol

    func fetchHistory(peerYxAccId: String, anchor: String?, limit: Int) async throws -> [ChatMessage] {
        if fetchSuspends {
            await withCheckedContinuation { cont in
                fetchResumeHandle = cont
            }
        }
        return try (stubHistory[anchor] ?? .success([])).get()
    }

    func sendText(peerYxAccId: String, text: String, clientMsgId: String) async throws -> String {
        stubSendTextCalls.append((peerYxAccId, text, clientMsgId))
        return try stubSendResult.get()
    }

    func sendAudio(peerYxAccId: String, localFilePath: String, dur: Int, clientMsgId: String) async throws -> String {
        stubSendAudioCalls.append((peerYxAccId, localFilePath, dur, clientMsgId))
        return try stubSendResult.get()
    }

    func sendImage(peerYxAccId: String, url: URL, clientMsgId: String) async throws -> String {
        stubSendImageCalls.append((peerYxAccId, url, clientMsgId))
        return try stubSendResult.get()
    }

    func sendVideo(peerYxAccId: String, url: URL, thumbnailUrl: URL?, dur: Int, clientMsgId: String) async throws -> String {
        stubSendVideoCalls.append((peerYxAccId, url, thumbnailUrl, dur, clientMsgId))
        return try stubSendResult.get()
    }

    // MARK: - H-3 私密消息 stubs

    var stubSendPrivateImageCalls: [(peer: String, peerUserId: String, url: URL, privateId: String, signedData: [String: Any], clientMsgId: String)] = []
    var stubSendPrivateVideoCalls: [(peer: String, peerUserId: String, url: URL, thumbnailUrl: URL?, dur: Int, privateId: String, signedData: [String: Any], clientMsgId: String)] = []

    func sendPrivateImage(
        peerYxAccId: String, peerUserId: String, url: URL,
        privateId: String, signedData: [String: Any], clientMsgId: String
    ) async throws -> String {
        stubSendPrivateImageCalls.append((peerYxAccId, peerUserId, url, privateId, signedData, clientMsgId))
        return try stubSendResult.get()
    }

    func sendPrivateVideo(
        peerYxAccId: String, peerUserId: String, url: URL, thumbnailUrl: URL?, dur: Int,
        privateId: String, signedData: [String: Any], clientMsgId: String
    ) async throws -> String {
        stubSendPrivateVideoCalls.append((peerYxAccId, peerUserId, url, thumbnailUrl, dur, privateId, signedData, clientMsgId))
        return try stubSendResult.get()
    }

    func markAllRead(peerYxAccId: String) async {
        stubMarkAllReadCalls.append(peerYxAccId)
    }

    func sendReceipt(peerYxAccId: String, lastReceivedMessageId: String) async {
        stubReceiptCalls.append((peerYxAccId, lastReceivedMessageId))
    }

    func subscribe(_ handler: @MainActor @escaping (P2PChatEvent) -> Void) {
        self.handler = handler
    }

    func unsubscribe() {
        self.handler = nil
    }
}

/// 测试消息构造工厂
enum ChatMessageFactory {
    static func make(id: String = "srv-\(UUID().uuidString)",
                     clientMsgId: String? = nil,
                     from: String = "peer",
                     to: String = "self",
                     content: ChatMessageContent = .text("hi"),
                     status: ChatMessageStatus = .sent,
                     timestamp: Int64 = 0,
                     isOutgoing: Bool = false) -> ChatMessage {
        ChatMessage(id: id, clientMsgId: clientMsgId, from: from, to: to,
                    content: content, status: status, timestamp: timestamp, isOutgoing: isOutgoing)
    }
}
