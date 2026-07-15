import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PKRecordStore")

/// PK 历史记录 sheet 状态机（对齐 H5 `pkHistoryPopup.vue` + useServerPagination hook）。
///
/// **接口**：`POST /api/pk/getPkRecordList` body `{currentPage, pageSize}`
/// **分页策略**（v25 2026-07-14 修上拉失效）：**统一 pageSize=20**（对齐 H5 pkHistoryPopup.vue:25 + useServerPagination.js:16 默认值）。
///   **铁律**：后端标准 offset = (currentPage-1) * pageSize —— pageSize 不对称会导致 records 跳段
///   （page1 pageSize=5 拿 1-5，page2 pageSize=10 offset=10 拿 11-20，records 6-10 永久丢失 → 上拉失效）
/// **元数据**：`validWinCount` / `totalPkCount` 首页响应含（用于 sheet 顶部统计栏）
/// **刷新**：`.refreshing(items:)` 中间态保留旧 items 视觉（对齐 [list-refresh-preserve-items.md]），
///   避免下拉刷新期把 rooms 清空造成"闪一下"体验断层
/// **hasMore 兜底**：对齐 H5 useServerPagination.js:100 `newList.length >= pageSize` 语义 —— records 少于 pageSize 视为最后一页
@MainActor
final class PKRecordStore: ObservableObject {
    enum State: Equatable {
        case idle
        case loading                              // 首次冷启（无旧 items 可保留）
        case refreshing([PKRecordItem])           // 下拉刷新态（保留旧 items 视觉；顶部 spinner 由 .refreshable 自身管）
        case loaded([PKRecordItem], hasMore: Bool, nextPage: Int)
        case loadingMore([PKRecordItem], nextPage: Int)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    /// 首页响应带回的本周有效胜场数（顶部统计栏用）
    @Published private(set) var validWinCount: Int = 0
    /// 首页响应带回的总 PK 场数（顶部统计栏用）
    @Published private(set) var totalPkCount: Int = 0

    /// 统一 pageSize —— 对齐 H5 pkHistoryPopup.vue L25 与 PKStore.loadMoreRecommend
    private let pageSize: Int = 20
    private var didLoadOnce = false

    /// sheet 出现时触发一次首页拉取；已 loaded 不重拉
    func onAppear() {
        guard !didLoadOnce else { return }
        didLoadOnce = true
        Task { await loadFirstPage(isRefresh: false) }
    }

    /// 下拉刷新：**保留旧 items 视觉**（对齐 [list-refresh-preserve-items.md]），
    /// 顶部 spinner 由 `.refreshable` 系统管，不切 loading 全屏 spinner
    func refresh() async {
        await loadFirstPage(isRefresh: true)
    }

    /// 上拉加载更多：仅当 state=.loaded 且 hasMore 才继续
    func loadMoreIfNeeded() {
        guard case .loaded(let existing, let hasMore, let nextPage) = state, hasMore else { return }
        Task {
            state = .loadingMore(existing, nextPage: nextPage)
            do {
                let page = try await PKService.getPkRecordList(currentPage: nextPage,
                                                               pageSize: pageSize)
                // v25（2026-07-14）：hasMore 覆盖判定（对齐 H5 useServerPagination.js:100 `newList.length >= pageSize`）
                let effectiveHasMore = page.hasMore && page.records.count >= pageSize
                state = .loaded(existing + page.records, hasMore: effectiveHasMore, nextPage: nextPage + 1)
            } catch {
                logger.warning("loadMoreIfNeeded failed: \(String(describing: error), privacy: .private)")
                // 2026-07-13 修死循环：失败时 hasMore 强制 false，防 sentinel 反复触发 loadMore
                state = .loaded(existing, hasMore: false, nextPage: nextPage)
            }
        }
    }

    /// 拉首页（`isRefresh=true` 时先进 `.refreshing` 中间态保留旧 items；否则进 `.loading` 全屏 spinner）
    private func loadFirstPage(isRefresh: Bool) async {
        if isRefresh {
            switch state {
            case .loaded(let items, _, _), .loadingMore(let items, _), .refreshing(let items):
                state = .refreshing(items)
            case .idle, .loading, .error:
                // 无旧 items 可保留 → 走全屏 loading
                state = .loading
            }
        } else {
            state = .loading
        }
        do {
            let page = try await PKService.getPkRecordList(currentPage: 1, pageSize: pageSize)
            validWinCount = page.validWinCount
            totalPkCount = page.totalPkCount
            // v25（2026-07-14）：hasMore 覆盖判定，records 少于 pageSize 视为最后一页
            let effectiveHasMore = page.hasMore && page.records.count >= pageSize
            state = .loaded(page.records, hasMore: effectiveHasMore, nextPage: 2)
        } catch {
            logger.warning("loadFirstPage failed: \(String(describing: error), privacy: .private)")
            // 刷新失败时保留旧 items（对齐 [list-refresh-preserve-items.md] 精神；用户可下次刷新重试）
            if case .refreshing(let items) = state, !items.isEmpty {
                state = .loaded(items, hasMore: false, nextPage: 2)
            } else {
                state = .error(String(describing: error))
            }
        }
    }
}
