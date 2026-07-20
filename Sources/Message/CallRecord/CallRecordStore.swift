import Foundation
import os

/// 通话历史记录列表 store —— 对齐 H5 `communication/index.vue:getRecordList` +
/// `communication/records/list.vue` 分页 + refresh + preserve-visual 铁律。
///
/// **状态机**（参 [list-refresh-preserve-items.md](../../.claude/rules/list-refresh-preserve-items.md)）：
/// ```
/// .idle → .loading                      // 首拉
///       → .loaded(items, hasMore)
///       → .refreshing(items:old)        // 下拉刷新保留视觉
///         → .loaded(new, hasMore)
///         → .pageError(old, msg)
///       → .loadingMore(items)           // 触底加载更多
///         → .loaded(items+new, hasMore)
///         → .pageError(items, msg)
///       → .error(msg)                   // 首拉失败（无 items 可保留）
/// ```
///
/// **无更多数据判定**：一页返回空数组即 `hasMore=false`（对齐 H5 `res.length === 0 → recordsFinishStatus = true`）。
@MainActor
final class CallRecordStore: ObservableObject {

    enum State: Equatable {
        case idle
        case loading                              // 首拉，无 items 可展示
        case refreshing(items: [CallRecord])      // 下拉刷新，保留旧 items
        case loadingMore(items: [CallRecord])     // 加载更多
        case loaded(items: [CallRecord], hasMore: Bool)
        /// 分页/刷新失败但保留旧 items（不清空列表）
        case pageError(items: [CallRecord], message: String)
        /// 首拉失败（无 items）
        case error(String)

        /// 当前可展示的 items（无论加载态）
        var items: [CallRecord] {
            switch self {
            case .idle, .loading, .error: return []
            case .refreshing(let it),
                 .loadingMore(let it),
                 .pageError(let it, _): return it
            case .loaded(let it, _): return it
            }
        }

        var hasMore: Bool {
            if case .loaded(_, let m) = self { return m }
            return false
        }
    }

    @Published private(set) var state: State = .idle

    private let pageSize: Int
    private let fetcher: (_ currentPage: Int, _ pageSize: Int) async throws -> [CallRecord]

    private var currentPage: Int = 0
    private var currentTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "CallRecordStore")

    /// `nonisolated` 是为了让 SwiftUI View 的属性初始化器 / init 默认值能在非 MainActor 上下文合法构造。
    /// init 体内仅赋值 `let` 字段（pageSize/fetcher），其他 @Published/存储属性走声明处默认值（`.idle`/0/nil），
    /// 未触碰 MainActor-isolated 状态，编译器可判定安全。
    nonisolated init(pageSize: Int = 20,
                     fetcher: @escaping (_ currentPage: Int, _ pageSize: Int) async throws -> [CallRecord]
                        = { try await CallRecordService.fetch(currentPage: $0, pageSize: $1) }) {
        self.pageSize = pageSize
        self.fetcher = fetcher
    }

    // MARK: - Public

    /// 首次载入（仅当 idle 时；已 loaded / loading 不重复触发）
    func loadIfNeeded() async {
        if case .idle = state {
            await load(reset: true)
        }
    }

    /// 强制刷新（下拉手势 / 手动重载）。保留旧 items 视觉。
    func refresh() {
        beginRefresh()
    }

    /// `.refreshable` closure 版：await 到本次刷新任务完成才 return，
    /// SwiftUI 顶部 spinner 才会保留到网络到达
    /// （参 [list-refresh-preserve-items.md](../../.claude/rules/list-refresh-preserve-items.md) 规则 B）。
    func refreshAsync() async {
        beginRefresh()
        await currentTask?.value
    }

    /// 触底加载下一页。若已在加载或已无更多则 no-op。
    func loadMore() {
        // 只在稳定 loaded 且 hasMore 时才允许
        guard case .loaded(let items, let hasMore) = state, hasMore else { return }
        state = .loadingMore(items: items)
        let next = currentPage + 1
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.performFetch(page: next, appendTo: items)
        }
    }

    /// 首拉失败后重试（.error 态入口）
    func retry() async {
        await load(reset: true)
    }

    // MARK: - Private

    private func beginRefresh() {
        currentPage = 0
        // 保留视觉：仅无 items 时走 loading（首拉走 load）；有 items 走 refreshing
        switch state {
        case .loaded(let items, _),
             .loadingMore(let items),
             .pageError(let items, _),
             .refreshing(let items):
            state = .refreshing(items: items)
        case .idle, .loading, .error:
            state = .loading
        }
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.performFetch(page: 1, appendTo: nil)
        }
    }

    private func load(reset: Bool) async {
        if reset { currentPage = 0 }
        state = .loading
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.performFetch(page: 1, appendTo: nil)
        }
        await currentTask?.value
    }

    /// - Parameter appendTo: nil 表示首拉/刷新（覆盖）；非 nil 表示分页追加
    private func performFetch(page: Int, appendTo previous: [CallRecord]?) async {
        do {
            let newItems = try await fetcher(page, pageSize)
            guard !Task.isCancelled else { return }

            // 一页返回空数组 = 无更多（对齐 H5 `recordsFinishStatus = true`）
            let hasMore = !newItems.isEmpty && newItems.count >= pageSize

            if let prev = previous {
                // 分页追加
                state = .loaded(items: prev + newItems, hasMore: hasMore)
            } else {
                // 首拉 / 刷新覆盖
                state = .loaded(items: newItems, hasMore: hasMore)
            }
            currentPage = page
            logger.info("[CallRecord] fetched page=\(page, privacy: .public) new=\(newItems.count, privacy: .public) hasMore=\(hasMore, privacy: .public)")
        } catch {
            guard !Task.isCancelled else { return }
            let msg = (error as? APIError)?.message ?? error.localizedDescription
            if let prev = previous {
                // 分页失败：保留旧 items + pageError
                state = .pageError(items: prev, message: msg)
            } else if let existing = existingItemsBeforeFailure() {
                // 刷新失败：保留旧 items + pageError（不清空）
                state = .pageError(items: existing, message: msg)
            } else {
                // 首拉失败：无 items 可保留
                state = .error(msg)
            }
            logger.notice("⚠️ [CallRecord] fetch failed page=\(page, privacy: .public) msg=\(msg, privacy: .private)")
        }
    }

    /// 若当前 state 保留了 items（refreshing / loadingMore / loaded / pageError），
    /// 返回这些 items 用作失败态兜底；否则 nil。
    private func existingItemsBeforeFailure() -> [CallRecord]? {
        let items = state.items
        return items.isEmpty ? nil : items
    }

    #if DEBUG
    /// Preview / test 专用：直接注入 state（生产禁用）
    func _debugSetState(_ s: State) { state = s }
    #endif
}
