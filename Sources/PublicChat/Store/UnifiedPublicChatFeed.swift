import Foundation
import Combine

@MainActor
final class UnifiedPublicChatFeed: ObservableObject {
    @Published private(set) var messages: [UnifiedPublicChatMessage] = []
    let limit: Int

    init(limit: Int = 200) {
        self.limit = limit
    }

    func append(_ msg: UnifiedPublicChatMessage) {
        messages.append(msg)
        trimIfNeeded()
    }

    func appendBatch(_ msgs: [UnifiedPublicChatMessage]) {
        messages.append(contentsOf: msgs)
        trimIfNeeded()
    }

    /// 全量替换语义（供 upstream 全量 map 后灌入用；Live 场景 T10 使用）
    func replace(_ msgs: [UnifiedPublicChatMessage]) {
        messages = msgs
        trimIfNeeded()
    }

    func clear() {
        messages.removeAll()
    }

    private func trimIfNeeded() {
        if messages.count > limit {
            messages.removeFirst(messages.count - limit)
        }
    }
}
