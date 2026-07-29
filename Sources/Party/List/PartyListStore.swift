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

    // MARK: - 语言状态（E 增强：语言 pill 横滑）

    /// 首个占位为 "All"（languageCode=""）；后续 append PartyAPI.languageList 结果。
    @Published private(set) var languages: [PartyLanguage] = [.all]

    @Published private(set) var activeLanguageIndex: Int = 0

    /// languages 是否已从后端拉过（避免重复请求；失败保留只 [.all]）。
    private var didLoadLanguages = false

    // MARK: - 我的派对房状态（E 增强 v2：Create Room / My Room 按钮分流）

    /// 用户已有的派对房（`nil` = 无 room；有值 = 显 My Room 按钮，点击直接进）。
    @Published private(set) var myRoom: PartyMyRoom?
    /// **已成功解析一次 myRoom 拉取**。View 层用来 gate 浮动按钮渲染 ——
    /// 网络错误不能视为“没有房间”，否则会错误显示 Create Room；未解析前一律隐藏入口。
    @Published private(set) var didLoadMyRoom = false
    /// 拉取进行中 dedup flag（独立于 didLoadMyRoom 语义）
    private var isLoadingMyRoom = false

    /// 本 Store 服务的 tab 类型（.party 主大厅 / .followed 关注 / .recent 最近）。
    let kind: PartyRoomListKind

    private let service: PartyListService
    private let pageSize: Int
    private let languageCodeProvider: () -> String?

    private var currentTask: Task<Void, Never>?

    /// refreshAsync 独立 inflight 标记（v3：与 currentTask 解耦）。
    /// 修复 P1：原 inflight guard 用 `currentTask != nil` 判断，`beginLoadMore` 完成不清 nil →
    /// loadMore 后调 refreshAsync 误把已完成的 loadMore task 当 inflight → `.value` 立即返回 →
    /// spinner 一闪即收。改为独立 flag：refresh 只 gate 自己，不受 loadMore 生命周期影响。
    private var isRefreshing = false

    /// 当前已加载页面数（用于 offset 计算）。`loaded/pageError` 时表示已成功页数；`loadingMore` 时是"尝试中"。
    private var loadedPageCount: Int = 0

    // MARK: - 生命周期

    init(
        service: PartyListService,
        kind: PartyRoomListKind = .party,
        pageSize: Int = PartyListStore.defaultPageSize,
        languageCodeProvider: @escaping () -> String? = { nil }
    ) {
        self.service = service
        self.kind = kind
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

    /// SwiftUI `.refreshable` closure 专用：await 到网络请求真正完成，spinner 才收起。
    ///
    /// **两个关键机制**（对齐 LiveStreamViewModel v14 模式）：
    /// 1. **inflight guard**：已有 refresh 在跑时不重复触发，直接 await 现有 task（避免 TabView(.page) 内
    ///    `.refreshable` 短时间多次触发把 spinner 冲刷掉）
    /// 2. **Task.detached**：请求生命周期与 SwiftUI view/refreshable Task 完全解耦——即便 refreshable
    ///    closure 被 SwiftUI cancel（页切走/body re-eval），URLSession 请求继续跑完再回填 state
    func refreshAsync() async {
        // v3 inflight guard：只 gate refresh 自身，不受 loadMore/前置 startInitial 的 currentTask 生命周期影响
        if isRefreshing {
            await currentTask?.value
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        // 若前置有 startInitial/setLanguage 启动的 task_A 未完成，cancel 之避免与本次 refresh 并行写 state
        currentTask?.cancel()

        loadedPageCount = 0
        switch state {
        case .loaded(let rooms, _), .loadingMore(let rooms), .pageError(let rooms, _):
            state = .refreshing(rooms: rooms)
        case .refreshing:
            break
        case .idle, .loading, .error:
            state = .loading
        }

        let task = Task.detached { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitial()
        }
        currentTask = task
        await task.value
        if currentTask == task { currentTask = nil }
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

    // MARK: - 语言 pill（E 增强）

    /// 首次进入 Party tab 时拉一次语言列表。失败保留 [.all] 单项，本会话不重试。
    /// 对齐 H5 用户端 `stores/modules/party.js:1354 getLanguageList` 首项拼 All。
    func loadLanguagesIfNeeded() async {
        guard !didLoadLanguages else { return }
        didLoadLanguages = true
        do {
            let list = try await PartyAPI.languageList()
            languages = [.all] + list
        } catch {
            // 保留 [.all]，静默；下次 tab 切回不重试（避免长期失败刷屏）
            languages = [.all]
        }
    }

    /// 切换语言 pill → activeLanguageIndex 更新 + 触发重拉。
    func setLanguage(index: Int) {
        guard index >= 0, index < languages.count, index != activeLanguageIndex else { return }
        activeLanguageIndex = index
        beginRefresh()
    }

    /// 当前语言 code。`nil` 代表 All（不传给后端）；`languageCodeProvider` 参数保留仅作 fallback。
    /// **Follow/Recent tab 强制返回 nil**（H5 index.vue L96 语义：`tabIndex===0 ? languageCode : null`）。
    private var currentLanguageCode: String? {
        guard kind == .party else { return nil }
        guard activeLanguageIndex < languages.count else { return nil }
        let code = languages[activeLanguageIndex].languageCode
        return code.isEmpty ? nil : code
    }

    // MARK: - 我的派对房（E 增强 v2）

    /// 首次进入 Party tab 时拉一次；成功但无 room 时 `myRoom = nil`；后端 roomStatus=2（封禁）也视为无 room。
    /// 对齐 H5 用户端 index.vue L36 `showMyRoomIcon = hasMyRoom && roomStatus !== 2`。
    /// 只有接口成功返回后才置 `didLoadMyRoom = true`，View 才显示浮动按钮（避免闪切和错误兜底）。
    ///
    /// v7（2026-07-14）：用 Task.detached 隔离 URLSession 生命周期 —— 与 refreshAsync 一致；
    /// 之前 SwiftUI `.task(id: isPartyTabActive)` cancel 会传播到 URLSession → -999 cancelled
    /// → catch 后若置 didLoadMyRoom=true，会把网络错误误判为无房间并显示 Create Room
    func loadMyRoomIfNeeded() async {
        guard !didLoadMyRoom, !isLoadingMyRoom else { return }
        let task = Task.detached { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadMyRoom(clearOnFail: true)
        }
        await task.value
    }

    /// 手动重拉（如刚创建完房 pop 回大厅时）。已 loaded 时按钮已在，reload 期间保留旧值不清空避免闪。
    /// v7：同 loadMyRoomIfNeeded 用 Task.detached 隔离 —— 防 refreshable closure cancel 传播
    func reloadMyRoom() async {
        guard !isLoadingMyRoom else { return }
        let task = Task.detached { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadMyRoom(clearOnFail: false)
        }
        await task.value
    }

    private func performLoadMyRoom(clearOnFail: Bool) async {
        isLoadingMyRoom = true
        defer { isLoadingMyRoom = false }
        do {
            let wrapper = try await PartyAPI.getMyRoomAndFamilyInfo()
            if let r = wrapper?.myRoom, r.isVisible {
                myRoom = r
            } else {
                myRoom = nil
            }
            didLoadMyRoom = true
        } catch {
            // v7：URLError -999 cancelled 是 SwiftUI Task cancel 传播（非真失败），不锁 didLoadMyRoom
            // 让下次 loadIfNeeded 能重试；防御性设计（detach 后理论上不再传播，但双保险）
            if let urlErr = error as? URLError, urlErr.code == .cancelled {
                AppLogger.party.notice("[PartyListStore] loadMyRoom cancelled, keep didLoadMyRoom=false for retry")
                return
            }
            if clearOnFail {
                myRoom = nil
                // 首次请求失败时维持“未解析”状态：不能把网络错误当作“没有房间”。
                // Party tab 下次激活或用户下拉刷新会重新尝试，期间不显示 My Room/Create Room。
                didLoadMyRoom = false
                AppLogger.party.notice("[PartyListStore] loadMyRoom failed before first success; hide room entry and retry later")
            }
            // reload 场景失败：保留已成功确认过的 myRoom 和 didLoadMyRoom，避免入口闪变。
        }
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
                kind: kind,
                languageCode: currentLanguageCode ?? languageCodeProvider(),
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
                kind: kind,
                languageCode: currentLanguageCode ?? languageCodeProvider(),
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
