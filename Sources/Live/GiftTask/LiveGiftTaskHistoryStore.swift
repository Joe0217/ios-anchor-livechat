import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveGiftTaskHistoryStore")

/// Tab1 底部送礼历史分页无限滚动 store —— sheet 内 `@StateObject`(spec §1.1)。
///
/// **触发**:
/// - Sheet onPresent 触发 `refreshAsync(anchorUserId:)` 拉 page 1
/// - 用户下拉刷新 `.refreshable { await store.refreshAsync(...) }`
/// - 触底触发 `loadMoreIfNeeded(currentItem:anchorUserId:)`
///
/// **状态机**(spec §1.2 v2):
/// - idle → refresh → loading → loaded / finished / error
/// - loaded / finished / error → refresh → loading(empty) → loaded / finished
/// - loaded(hasMore) → loadMore → loadingMore(items) → loaded(items+new) / finished
///
/// **竞态**:`currentTask.cancel()` 保护 refresh 与 loadMore 冲突;refresh 强夺 loadMore;
/// reset 期间 pending 请求 cancel 不写入 store。
@MainActor
final class LiveGiftTaskHistoryStore: ObservableObject {

    // MARK: - State

    enum PagingState: Equatable {
        case idle
        case loading                                                    // 首次(无 previous)
        case refreshing(items: [IndexedGiftHistoryItem])                // refresh 保留 items
        case loaded(items: [IndexedGiftHistoryItem], hasMore: Bool)
        case loadingMore(items: [IndexedGiftHistoryItem])
        case finished(items: [IndexedGiftHistoryItem])                  // 无更多
        case error(items: [IndexedGiftHistoryItem], String)             // 兼容旧错误态
    }

    @Published private(set) var pagingState: PagingState = .idle

    /// 派生:当前 items 视图(loaded/refreshing/loadingMore/finished/error 五态都能取到)
    var items: [IndexedGiftHistoryItem] {
        switch pagingState {
        case .refreshing(let items), .loaded(let items, _), .loadingMore(let items),
             .finished(let items), .error(let items, _):
            return items
        case .idle, .loading:
            return []
        }
    }

    // MARK: - 依赖 & 配置

    private let service: LiveGiftTaskServiceProtocol
    private let pageSize: Int
    private var currentPage: Int = 1
    private var currentTask: Task<Void, Never>?

    init(service: LiveGiftTaskServiceProtocol = LiveGiftTaskServiceReal(),
         pageSize: Int = 20) {
        self.service = service
        self.pageSize = pageSize
    }

    deinit {
        currentTask?.cancel()
    }

    // MARK: - 公开入口

    /// 下拉刷新(或 sheet onPresent 首次触发)—— async 版本供 SwiftUI `.refreshable` 使用。
    func refreshAsync(anchorUserId: String) async {
        currentTask?.cancel()
        currentPage = 1

        // 对齐 H5 refresh(): 请求一开始就清空历史列表。
        pagingState = .loading

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performFetch(anchorUserId: anchorUserId)
        }
        currentTask = task
        await task.value
    }

    /// 上拉加载更多(触底触发)—— view 层调 `onAppear` of 最后一项时 fire。
    /// 仅在 `.loaded(hasMore=true)` 有效;其他态忽略(refresh 承担强夺)。
    func loadMoreIfNeeded(currentItem: IndexedGiftHistoryItem, anchorUserId: String) {
        guard case .loaded(let items, let hasMore) = pagingState, hasMore else { return }
        // 只在真正最后一项时触发(避免中间项 onAppear 重复触发)
        guard currentItem.id == items.last?.id else { return }
        beginLoadMore(items: items, anchorUserId: anchorUserId)
    }

    /// 保留给错误 UI 的兼容入口；H5 出错后列表为空且结束，手势下拉仍可重新请求。
    func retry(anchorUserId: String) {
        switch pagingState {
        case .error:
            Task { await refreshAsync(anchorUserId: anchorUserId) }
        default:
            break
        }
    }

    /// Sheet dismiss / LiveRoomView disappear 时调
    func reset() {
        currentTask?.cancel()
        currentTask = nil
        currentPage = 1
        pagingState = .idle
    }

    // MARK: - 内部

    private func beginLoadMore(items: [IndexedGiftHistoryItem], anchorUserId: String) {
        currentTask?.cancel()
        pagingState = .loadingMore(items: items)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadMore(anchorUserId: anchorUserId, existing: items)
        }
        currentTask = task
    }

    private func performFetch(anchorUserId: String) async {
        do {
            try Task.checkCancellation()
            let raw = try await service.fetchLiveGiftHistory(anchorUserId: anchorUserId,
                                                             page: currentPage, pageSize: pageSize)
            try Task.checkCancellation()

            let indexed = raw.enumerated().map { row, item in
                IndexedGiftHistoryItem(page: currentPage, row: row, item: item)
            }

            // H5 只以空数组设置 finished；不足一页仍允许下一次触底请求。
            pagingState = raw.isEmpty
                ? .finished(items: [])
                : .loaded(items: indexed, hasMore: true)
            logger.info("History refresh page=\(self.currentPage, privacy: .public) items=\(raw.count, privacy: .public)")
        } catch is CancellationError {
            logger.debug("History refresh cancelled")
        } catch {
            let msg = "\(error)"
            // H5 catch: sendGiftList=[]; finished=true。
            pagingState = .finished(items: [])
            logger.warning("History refresh failed: \(msg, privacy: .private)")
        }
    }

    private func performLoadMore(anchorUserId: String, existing: [IndexedGiftHistoryItem]) async {
        let nextPage = currentPage + 1
        do {
            try Task.checkCancellation()
            let raw = try await service.fetchLiveGiftHistory(anchorUserId: anchorUserId,
                                                             page: nextPage, pageSize: pageSize)
            try Task.checkCancellation()

            let indexed = raw.enumerated().map { row, item in
                IndexedGiftHistoryItem(page: nextPage, row: row, item: item)
            }

            if raw.isEmpty {
                pagingState = .finished(items: existing)
            } else {
                currentPage = nextPage
                let merged = existing + indexed
                pagingState = .loaded(items: merged, hasMore: true)
            }
            logger.info("History loadMore page=\(nextPage, privacy: .public) items=\(raw.count, privacy: .public)")
        } catch is CancellationError {
            logger.debug("History loadMore cancelled")
        } catch {
            let msg = "\(error)"
            // H5 加载失败同样清空并结束列表。
            pagingState = .finished(items: [])
            logger.warning("History loadMore failed: \(msg, privacy: .private)")
        }
    }
}
