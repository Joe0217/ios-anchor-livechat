import Foundation

/// P2P 私聊页页面状态（H-2 spec §2.3）。
///
/// **状态机**：
/// ```
/// .loading ──成功──→ .loaded([msgs])
///     │                    │
///     │                    ├── delegate 增量 ──→ 合并（messageId 去重）
///     │                    ├── loading 期入 pendingUpdates ──→ loaded 后合并
///     │                    └── IM 断连 + fetchAll 空 ──→ 保留旧 loaded（Q3 同款）
///     │
///     └──失败──→ .error(msg) ──重试──→ .loading
/// ```
enum P2PChatState: Equatable {
    case loading
    case loaded([ChatMessage])
    case error(String)
    /// loaded 且 0 条历史（新会话）
    case empty
}
