import Foundation

/// 派对房大厅列表状态机（E 期 Step 1a，spec §2/§7）。
///
/// **架构**：view-owned `@StateObject`（挂 PartyTabRootView）。tab 销毁重建时 store 随之 deinit，
/// deinit 里 cancel currentTask（spec §7 F-23）。**不做** shared 单例（spec §6B F-02 拍板）。
///
/// **状态机 6 态 + cancel 边**（spec §2）：
/// - `idle` → startInitial → `loading`
/// - `loading` / `loadingMore` → success / failure / cancel
/// - `loaded` → refresh / loadMore
/// - `error` → retry / refresh
/// - `pageError` → retryPage / refresh
///
/// **并发保护**：
/// - 每次入口先 `currentTask?.cancel()` 再启新任务
/// - `loading / loadingMore` 时 `loadMore()` no-op
/// - `refresh()` 强夺 loadingMore（cancel + 重置 rooms）
/// - `error` 状态 double-tap `retry()` 忽略（currentTask 未 nil 时 no-op）
///
/// **Task 语义**：async 内含 `Task.checkCancellation()`，被 cancel 时静默不改 state（避免撞死已 dismount view）。
@MainActor
final class PartyListStore: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        /// 首拉/error 重试的全屏 loading（**无 rooms** 可保留视觉时用）
        case loading
        case loaded(rooms: [PartyRoomInfo], hasMore: Bool)
        case loadingMore(rooms: [PartyRoomInfo])
        /// 下拉刷新期保留旧 rooms 视觉（`.refreshable` 顶部 spinner 表达"刷新中"）。
        /// 见 `.claude/rules/list-refresh-preserve-items.md`。
        case refreshing(rooms: [PartyRoomInfo])
        case error(message: String, canRetry: Bool)
        case pageError(rooms: [PartyRoomInfo], message: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case (.loading, .loading):
                return true
            case (.loaded(let lr, let lm), .loaded(let rr, let rm)):
                return lm == rm && sameIds(lr, rr)
            case (.loadingMore(let lr), .loadingMore(let rr)):
                return sameIds(lr, rr)
            case (.refreshing(let lr), .refreshing(let rr)):
                return sameIds(lr, rr)
            case (.error(let lm, let lc), .error(let rm, let rc)):
                return lm == rm && lc == rc
            case (.pageError(let lr, let lm), .pageError(let rr, let rm)):
                return lm == rm && sameIds(lr, rr)
            default:
                return false
            }
        }

        private static func sameIds(_ a: [PartyRoomInfo], _ b: [PartyRoomInfo]) -> Bool {
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.stableListId != y.stableListId { return false }
            return true
        }
    }

    // MARK: - 依赖

    /// pageSize 默认值。`nonisolated` 让 init 参数默认值可在 nonisolated context 引用（Swift 6 严格并发）。
    nonisolated static let defaultPageSize = 20

    @Published private(set) var state: State = .idle

    private let service: PartyListService
    private let pageSize: Int
    private let languageCodeProvider: () -> String?

    private var currentTask: Task<Void, Never>?

    /// 当前已加载页面数（用于 offset 计算）。`loaded/pageError` 时表示已成功页数；`loadingMore` 时是"尝试中"。
    private var loadedPageCount: Int = 0

    // MARK: - 生命周期

    init(
        service: PartyListService,
        pageSize: Int = PartyListStore.defaultPageSize,
        languageCodeProvider: @escaping () -> String? = { nil }
    ) {
        self.service = service
        self.pageSize = pageSize
        self.languageCodeProvider = languageCodeProvider
    }

    deinit {
        // spec §7 F-23：view-owned @StateObject dismount 时确保网络任务不空转
        currentTask?.cancel()
    }

    // MARK: - 公开入口

    /// 首次进入 tab / 冷启动 / idle → 拉首页
    func startInitial() {
        // idle 或已 loaded 都可以从头拉；language 变化时也用这个入口
        beginRefresh()
    }

    /// 下拉刷新：任意态 → 重置 → 拉首页
    func refresh() {
        beginRefresh()
    }

    /// 上拉加载更多：仅 `.loaded` 有效；`loading/loadingMore/error/pageError` 时忽略（refresh 承担强夺）
    func loadMore() {
        guard case .loaded(let rooms, let hasMore) = state, hasMore else { return }
        beginLoadMore(currentRooms: rooms)
    }

    /// 错误重试：`.error` → 重拉首页（等价 startInitial）；double-tap 时若 currentTask 未 nil 则 no-op
    func retry() {
        guard case .error = state else { return }
        beginRefresh()
    }

    /// 分页错误重试：`.pageError` → loadingMore
    func retryPage() {
        guard case .pageError(let rooms, _) = state else { return }
        beginLoadMore(currentRooms: rooms)
    }

    // MARK: - 内部 —— 状态迁移

    private func beginRefresh() {
        currentTask?.cancel()
        loadedPageCount = 0
        // list-refresh-preserve-items rule：refresh 期保留已有 rooms 视觉，仅无数据时走 loading
        switch state {
        case .loaded(let rooms, _), .loadingMore(let rooms), .pageError(let rooms, _):
            state = .refreshing(rooms: rooms)
        case .refreshing:
            break // 已 refreshing，保持
        case .idle, .loading, .error:
            state = .loading
        }

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.performInitial()
        }
    }

    private func beginLoadMore(currentRooms: [PartyRoomInfo]) {
        currentTask?.cancel()
        state = .loadingMore(rooms: currentRooms)

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoadMore(currentRooms: currentRooms)
        }
    }

    // MARK: - 内部 —— 执行

    private func performInitial() async {
        // list-refresh-preserve-items：refresh 期失败也不能让 rooms 消失，先记录进入本次拉取时的 rooms 快照
        let preservedRooms: [PartyRoomInfo]? = {
            if case .refreshing(let rooms) = state { return rooms }
            return nil
        }()

        do {
            try Task.checkCancellation()
            let rooms = try await service.fetchList(
                languageCode: languageCodeProvider(),
                offset: nil,
                pageSize: pageSize,
                queryParam: nil,
                version: "v2"
            )
            try Task.checkCancellation()

            loadedPageCount = 1
            let hasMore = rooms.count == pageSize
            state = .loaded(rooms: rooms, hasMore: hasMore)
        } catch is CancellationError {
            // 静默：view 已 dismount 或被 refresh 强夺
            return
        } catch {
            guard !Task.isCancelled else { return }
            if let rooms = preservedRooms {
                // refresh 失败 → 保留旧 rooms + 底部 banner（对齐 pageError 语义，用户可继续看列表 + retry）
                state = .pageError(rooms: rooms, message: mapMessage(error))
            } else {
                state = .error(message: mapMessage(error), canRetry: true)
            }
        }
    }

    private func performLoadMore(currentRooms: [PartyRoomInfo]) async {
        let offset = loadedPageCount * pageSize
        do {
            try Task.checkCancellation()
            let page = try await service.fetchList(
                languageCode: languageCodeProvider(),
                offset: offset,
                pageSize: pageSize,
                queryParam: nil,
                version: "v2"
            )
            try Task.checkCancellation()

            loadedPageCount += 1
            let merged = currentRooms + page
            let hasMore = page.count == pageSize
            state = .loaded(rooms: merged, hasMore: hasMore)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .pageError(rooms: currentRooms, message: mapMessage(error))
        }
    }

    // MARK: - 错误消息映射

    /// 简易 message 映射；真接口错误的详细分类走 Live 层（PartyAPIError → 中文 message）。
    /// Fake 单测直接把错误 error.localizedDescription 收进；生产 Live 侧真接口错误已含中文 message。
    private func mapMessage(_ error: Error) -> String {
        if let fake = error as? PartyListServicePreviewFakeError {
            switch fake {
            case .networkError: return "network"
            case .decodeError: return "decode"
            case .businessError(let code, let message): return "business:\(code):\(message)"
            }
        }
        return error.localizedDescription
    }
}
