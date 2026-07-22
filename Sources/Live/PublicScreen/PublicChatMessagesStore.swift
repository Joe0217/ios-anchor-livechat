import Combine
import Foundation

/// 直播公屏消息存储。H5 在每个消息入口后统一裁到最近 50 条，避免长直播无限增长。
@MainActor
final class PublicChatMessagesStore: ObservableObject {
    nonisolated static let liveMessageLimit = 50

    @Published private(set) var messages: [PublicChatMessage] = []

    func append(_ message: PublicChatMessage, limit: Int = liveMessageLimit) {
        messages.append(message)
        if messages.count > limit {
            messages.removeFirst(messages.count - limit)
        }
    }

    func clear() {
        messages.removeAll()
    }
}
