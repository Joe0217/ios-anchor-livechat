import Foundation

/// P2P 会话列表状态机（H-1 MVP，spec §2.2）。
///
/// 3 态设计（B 档降档，无需复杂中间态）：
/// - `.idle` 初始
/// - `.loading` 拉取中（含首次拉取 + 重试）
/// - `.loaded([...])` 有内容态；空数组表示当前分类无数据（**非**分类过滤后空——按 view 层派生"该分类下空"）
/// - `.error(_)` 拉取失败
///
/// **状态转换**：
/// ```
/// .idle → [load()] → .loading
/// .loading → [success] → .loaded(sessions)
/// .loading → [error] → .error(...)
/// .error → [retry()] → .loading
/// .loaded → [delegate incremental] → .loaded(newSessions)
/// ```
///
/// `.empty` 不作单独 state——按 view 层派生"当前分类下 sessions 为空"显示 empty 视图。
enum MessageSessionState: Equatable {
    case idle
    case loading
    case loaded([MessageSession])
    case error(String)
}
