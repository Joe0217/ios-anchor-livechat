#if DEBUG
import Combine
import SwiftUI

/// H-2 spec §5 状态清单 Preview 覆盖（loading / empty / error / loaded 含 4 类 bubble）。
///
/// **零 SDK 依赖**：内联 preview provider stub 数据；不接 NIMSDK。
struct ChatDetailView_Previews: PreviewProvider {

    @MainActor
    final class PreviewProvider_: P2PChatProviderProtocol {
        var stubHistory: [ChatMessage] = []
        var stubError: Error?
        func fetchHistory(peerYxAccId: String, anchor: String?, limit: Int) async throws -> [ChatMessage] {
            if let e = stubError { throw e }
            return stubHistory
        }
        func sendText(peerYxAccId: String, text: String, clientMsgId: String) async throws -> String { "SVR-\(clientMsgId)" }
        func sendAudio(peerYxAccId: String, localFilePath: String, dur: Int, clientMsgId: String) async throws -> String { "SVR-\(clientMsgId)" }
        func sendImage(peerYxAccId: String, url: URL, clientMsgId: String) async throws -> String { "SVR-\(clientMsgId)" }
        func sendVideo(peerYxAccId: String, url: URL, thumbnailUrl: URL?, dur: Int, clientMsgId: String) async throws -> String { "SVR-\(clientMsgId)" }
        // H-3 Step 1a-5 私密消息 Preview no-op
        func sendPrivateImage(peerYxAccId: String, peerUserId: String, url: URL, privateId: String, signedData: [String: Any], clientMsgId: String) async throws -> String { "SVR-\(clientMsgId)" }
        func sendPrivateVideo(peerYxAccId: String, peerUserId: String, url: URL, thumbnailUrl: URL?, dur: Int, privateId: String, signedData: [String: Any], clientMsgId: String) async throws -> String { "SVR-\(clientMsgId)" }
        func markAllRead(peerYxAccId: String) async {}
        func sendReceipt(peerYxAccId: String, lastReceivedMessageId: String) async {}
        func subscribe(_ handler: @MainActor @escaping (P2PChatEvent) -> Void) {}
        func unsubscribe() {}
    }

    @MainActor
    static func makeStore(messages: [ChatMessage] = [], error: Error? = nil) -> P2PChatStore {
        let provider = PreviewProvider_()
        provider.stubHistory = messages
        provider.stubError = error
        return P2PChatStore(peerYxAccId: "peer", selfYxAccId: "self", provider: provider)
    }

    static let now = Int64(Date().timeIntervalSince1970 * 1000)

    static let sampleMessages: [ChatMessage] = [
        // 对方 5min 前发的文字
        .init(id: "1", clientMsgId: nil, from: "peer", to: "self",
              content: .text("Hi, how are you?"), status: .sent,
              timestamp: now - 6 * 60 * 1000, isOutgoing: false),
        // 我方回复文字 sending
        .init(id: "2", clientMsgId: "c2", from: "self", to: "peer",
              content: .text("I'm good"), status: .sent,
              timestamp: now - 5 * 60 * 1000, isOutgoing: true),
        // 对方发图
        .init(id: "3", clientMsgId: nil, from: "peer", to: "self",
              content: .image(url: URL(string: "https://picsum.photos/200")!, size: nil),
              status: .sent, timestamp: now - 4 * 60 * 1000, isOutgoing: false),
        // 我方发视频 sent
        .init(id: "4", clientMsgId: "c4", from: "self", to: "peer",
              content: .video(url: URL(string: "https://ex.com/v.mp4")!,
                              thumbnail: URL(string: "https://picsum.photos/200"), dur: 32),
              status: .sent, timestamp: now - 3 * 60 * 1000, isOutgoing: true),
        // 对方发语音
        .init(id: "5", clientMsgId: nil, from: "peer", to: "self",
              content: .audio(url: URL(string: "https://ex.com/a.m4a")!, dur: 8),
              status: .sent, timestamp: now - 2 * 60 * 1000, isOutgoing: false),
        // 我方语音 uploading
        .init(id: "6", clientMsgId: "c6", from: "self", to: "peer",
              content: .audio(url: URL(string: "file:///tmp/a.m4a")!, dur: 3),
              status: .uploading(progress: 0.5), timestamp: now - 60 * 1000, isOutgoing: true),
        // 我方文字 failed
        .init(id: "7", clientMsgId: "c7", from: "self", to: "peer",
              content: .text("Retry me"), status: .failed(errorCode: "net"),
              timestamp: now - 30 * 1000, isOutgoing: true),
        // 我方文字 refused（拉黑）
        .init(id: "8", clientMsgId: "c8", from: "self", to: "peer",
              content: .text("Blocked test"), status: .refused(reason: "blocked"),
              timestamp: now - 20 * 1000, isOutgoing: true),
        // 我方文字 read
        .init(id: "9", clientMsgId: "c9", from: "self", to: "peer",
              content: .text("Read receipt test"), status: .read,
              timestamp: now - 10 * 1000, isOutgoing: true),
    ]

    static let sampleMedia: [AnchorMediaItem] = [
        .init(id: "m1", mediaUrl: URL(string: "https://picsum.photos/300/400")!,
              coverUrl: nil, kind: .image, dur: nil),
        .init(id: "m2", mediaUrl: URL(string: "https://picsum.photos/300/400")!,
              coverUrl: nil, kind: .image, dur: nil),
        .init(id: "m3", mediaUrl: URL(string: "https://ex.com/v.mp4")!,
              coverUrl: URL(string: "https://picsum.photos/300/400"), kind: .video, dur: 45),
    ]

    // 2026-07-07 v6：SwiftUI 类型推导超时（"generic parameter 'R' could not be inferred"）修复 ——
    // 原 Group { 3×ChatDetailView } 让编译器全局 TupleView 泛型推导过复杂；
    // 拆到独立 computed property 减轻 body 类型推导，Group 内改为符号引用
    static var previews: some View {
        Group {
            previewLoaded
            previewEmpty
            previewError
        }
        .preferredColorScheme(.dark)
    }

    private static var previewLoaded: some View {
        ChatDetailView(
            store: makeStore(messages: sampleMessages),
            peerNickname: "Alice",
            peerAvatarURL: URL(string: "https://picsum.photos/100"),
            myAvatarURL: URL(string: "https://picsum.photos/101"),
            mediaItems: sampleMedia,
            mediaItemsLoading: false,
            privateItems: [],
            privateItemsLoading: false,
            peerUserId: 12345,
            onClose: nil,
            chatType: .regular,
            canCall: false,
            replyPointsStore: ReplyPointsStore.shared
        )
        .previewDisplayName("Loaded · 4 bubble 类型 + 6 状态")
    }

    private static var previewEmpty: some View {
        ChatDetailView(
            store: makeStore(messages: []),
            peerNickname: "Alice",
            peerAvatarURL: nil, myAvatarURL: nil,
            mediaItems: [], mediaItemsLoading: false,
            privateItems: [], privateItemsLoading: false,
            peerUserId: nil,
            onClose: nil,
            chatType: .regular,
            canCall: false,
            replyPointsStore: ReplyPointsStore.shared
        )
        .previewDisplayName("Empty")
    }

    private static var previewError: some View {
        ChatDetailView(
            store: makeStore(messages: [], error: NSError(domain: "preview", code: -1)),
            peerNickname: "Alice",
            peerAvatarURL: nil, myAvatarURL: nil,
            mediaItems: [], mediaItemsLoading: false,
            privateItems: [], privateItemsLoading: false,
            peerUserId: nil,
            onClose: nil,
            chatType: .regular,
            canCall: false,
            replyPointsStore: ReplyPointsStore.shared
        )
        .previewDisplayName("Error retry")
    }
}
#endif
