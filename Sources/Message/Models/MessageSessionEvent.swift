import Foundation

/// NIM SDK delegate 增量事件的业务归一化（H-1 MVP，spec §2.2 合并语义）。
///
/// **合并语义**（v2 red team H-2 修订）：同 sessionId 出现多条 pendingUpdates，按到达顺序合并——
/// - 终态优先：`remove` 吃掉先前所有 `add` / `update`
/// - 后到覆盖：后到的 `update` 覆盖先到的 `add` 或 `update`
///
/// 决策纯逻辑，无 SDK 依赖，可入 HilyTests。
enum MessageSessionEvent: Equatable {
    case add(MessageSession)
    case update(MessageSession)
    case remove(sessionId: String)

    var sessionId: String {
        switch self {
        case .add(let s), .update(let s): return s.id
        case .remove(let id): return id
        }
    }

    /// 是否为终态事件（`remove` 一旦出现，先前 add/update 全丢）
    var isTerminal: Bool {
        if case .remove = self { return true }
        return false
    }
}

extension Array where Element == MessageSessionEvent {

    /// 按 sessionId 合并 pendingUpdates 序列，返回每 sessionId 的**最终动作**：
    ///
    /// - remove 覆盖先前 add/update → 保留 remove（表示应从列表移除该 session）
    /// - update 覆盖先前 add/update → 保留最后一次 update（表示应更新为最新数据）
    /// - 仅 add → 保留 add（表示应插入）
    ///
    /// 返回顺序稳定：按每 sessionId 的**首次出现顺序**排序。
    func mergedByLastTerminal() -> [MessageSessionEvent] {
        var order: [String] = []
        var latest: [String: MessageSessionEvent] = [:]

        for event in self {
            let sid = event.sessionId
            if latest[sid] == nil { order.append(sid) }

            if let prev = latest[sid], prev.isTerminal {
                // 已有 remove（终态），后续 add/update 忽略
                continue
            }
            latest[sid] = event
        }

        return order.compactMap { latest[$0] }
    }
}
