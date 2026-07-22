import Combine
import Foundation

/// 直播间 / 派对房消息入口红点未读计数派生 bridge。
///
/// **为什么需要 bridge**：`MessageSessionStore.shared` 是大单例（N 个 `@Published` 字段:
/// `state` / `systemInboxEntries` / `stationMail` / `conversationProfiles` / `primeUidSet` /
/// `flameUserIdSet` / `customerYxAccId` 等）。直接 `@ObservedObject` 会订阅所有变化，
/// LiveRoomView / PartyRoomView 是重量级 view（含 CameraPreview / PKArenaView / publicChatFeed），
/// 任何 session 更新都会触发整树重算 —— 60Hz 相机帧 sink 叠加会影响推流质量。
///
/// **对齐 rule**：[.claude/rules/swiftui-keepalive-publisher-isolation.md §方案 A](../../.claude/rules/swiftui-keepalive-publisher-isolation.md)
///
/// **计算与 ConversationSheetContent.allSessions 对齐**：3 类 flame ∪ prime ∪ stranger 去重后累加 unreadCount。
/// **不用** `MessageSessionStore.unreadCount(in: .flame)` —— 那含 systemInboxEntries（sheet 里已 filter 掉），
/// 会导致红点数字 ≠ sheet 内看到的未读源。
///
/// **removeDuplicates 拦截**：仅当 totalUnread 数字变化才 publish，避免无关字段变动触发 view 重算。
@MainActor
final class MessageEntryUnreadBridge: ObservableObject {

    @Published private(set) var totalUnread: Int = 0

    init(source: MessageSessionStore = .shared) {
        // 订阅 $state：sessions 数组变化（含 unreadCount 变化）会重新赋值 `.loaded([...])` 触发 publish。
        // conversationProfiles / primeUidSet 等无关字段变化时，state 不变 → publish 但 totalUnread compute
        // 结果相同 → removeDuplicates 拦截 → 不通知 view。
        source.$state
            .map { _ in MessageEntryUnreadBridge.compute(source) }
            .removeDuplicates()
            .assign(to: &$totalUnread)
    }

    private static func compute(_ store: MessageSessionStore) -> Int {
        let all = store.sessions(in: .flame)
            + store.sessions(in: .prime)
            + store.sessions(in: .stranger)
        var seen = Set<String>()
        return all
            .filter { seen.insert($0.id).inserted }
            .reduce(0) { $0 + $1.unreadCount }
    }
}
