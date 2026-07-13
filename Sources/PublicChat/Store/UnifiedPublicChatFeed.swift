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

    /// 更新 `.text` variant 的 translation 字段（对齐 H5 `messageScroller.vue` translatedClick）。
    /// 命中不到 msgId 或非 `.text` variant 时静默 no-op。
    func setTranslation(messageId: UUID, translation: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let old = messages[idx]
        guard case .text(let content, let mentions, _, let replyToNick) = old.variant else { return }
        let newVariant: PublicChatVariant = .text(
            content: content,
            mentions: mentions,
            translation: translation,
            replyToNick: replyToNick
        )
        messages[idx] = UnifiedPublicChatMessage(
            id: old.id,
            timestamp: old.timestamp,
            sender: old.sender,
            variant: newVariant
        )
    }

    private func trimIfNeeded() {
        if messages.count > limit {
            messages.removeFirst(messages.count - limit)
        }
    }
}
