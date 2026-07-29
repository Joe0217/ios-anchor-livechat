import Foundation

/// Props 主背包状态机（M1 Step 1a · spec §2.1 / §2.2）。
///
/// **架构**：view-owned `@StateObject`（挂 PropsMainView）。tab 销毁重建时 store 随之 deinit，
/// deinit 里 cancel currentTask。**不做** shared 单例（保持 view scope）；session lifecycle 通过
/// `SessionStore.logout → PropsInventoryStore` 用**全局 shared 快照**（spec §6.2 · 见 §11 M1 exit gate）。
///
/// **7 态 + phase-aware error**：
/// - idle → loadFirst → loading
/// - loading → success → loaded / empty · error → error(nil, .initial)
/// - loaded → loadMore → loadingMore · refresh → refreshing
/// - loadingMore → success → loaded · error → error(items, .loadMore) · refresh → refreshing（丢弃 loadingMore 响应）
/// - refreshing → success → loaded / empty · error → error(items, .refresh)
/// - empty → refresh → refreshing · changeTab → loading
/// - error → retry (by phase) · changeTab → loading
///
/// **selection state** 独立第三维（chooseItemId: Int64?） · changeTab 清空 / refresh 后旧 id 不在 new records 清空。
///
/// **并发保护 · loadSeq**：
/// - 每次入口 loadSeq++ + `currentTask?.cancel()` + 启新 Task
/// - Task 内先 `let localSeq = loadSeq`，返回后 `guard localSeq == self.loadSeq else { return }` 丢弃过期响应
/// - ops snapshot 也带 loadSeq · 失败时 seq 不同则不回滚（服务端为准）
@MainActor
final class PropsInventoryStore: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case loading                                              // 首次拉取（无 items 可保留）
        case loaded(items: [PropItem], hasMore: Bool)
        case loadingMore(items: [PropItem])
        case refreshing(items: [PropItem])                        // 保留 items 视觉（list-refresh rule）
        case empty                                                // totalNum=0 / records=[]
        case error(items: [PropItem]?, phase: LoadPhase, message: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.loading, .loading): return true
            case (.empty, .empty): return true
            case (.loaded(let li, let lm), .loaded(let ri, let rm)):
                return lm == rm && sameIds(li, ri)
            case (.loadingMore(let li), .loadingMore(let ri)):
                return sameIds(li, ri)
            case (.refreshing(let li), .refreshing(let ri)):
                return sameIds(li, ri)
            case (.error(let li, let lp, let lm), .error(let ri, let rp, let rm)):
                return lp == rp && lm == rm && sameIdsOpt(li, ri)
            default: return false
            }
        }

        private static func sameIds(_ a: [PropItem], _ b: [PropItem]) -> Bool {
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.id == $1.id && $0.wearStatus == $1.wearStatus }
        }
        private static func sameIdsOpt(_ a: [PropItem]?, _ b: [PropItem]?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case (let x?, let y?): return sameIds(x, y)
            default: return false
            }
        }
    }

    /// error 状态携带的 phase，供 retry 分派回原意图（spec R4/R4b · 红队 d2-2）
    enum LoadPhase: Equatable {
        case initial, loadMore, refresh
    }

    // MARK: - OpsState + Snapshot

    /// 佩戴/卸下操作态（spec §2.2 · 每个 item 独立 disable 而非全局）
    enum OpsState: Equatable {
        case idle
        case wearing(itemId: Int64, snapshot: OpsSnapshot)
        case removing(itemId: Int64, snapshot: OpsSnapshot)

        var busyItemId: Int64? {
            switch self {
            case .idle: return nil
            case .wearing(let id, _), .removing(let id, _): return id
            }
        }
    }

    /// 乐观回滚快照（spec §2.2 · 红队 d2-4）
    struct OpsSnapshot: Equatable {
        let previouslyEquippedItemId: Int64?    // 同 itemType 内之前穿的那件（可能 nil）
        let previousMineURL: String?             // AnchorInfoStore.mine 对应字段旧值
        let loadSeq: Int                          // ops 时的 loadSeq · 失败时 seq 变化则不回滚
    }

    // MARK: - Published

    @Published private(set) var state: State = .idle
    @Published private(set) var opsState: OpsState = .idle

    /// UI 选中态（独立于 state · spec §2.1 selection）
    @Published var chooseItemId: Int64?

    /// 当前 tab（nil = All · 对齐 H5 tabList[0]）
    @Published private(set) var currentTab: PropTabItemType?

    // MARK: - 依赖

    nonisolated static let defaultPageSize = 10                   // spec D5 对齐 H5

    private let service: PropsService
    private let pageSize: Int

    // MARK: - 内部状态

    /// 竞态防护 · 每次 changeTab/refresh/loadMore 前 `loadSeq += 1`
    private var loadSeq: Int = 0
    private var currentTask: Task<Void, Never>?
    private var isRefreshing = false                              // refreshAsync inflight 独立标记
    private var loadedPageCount: Int = 0

    // MARK: - 生命周期

    init(service: PropsService, pageSize: Int = PropsInventoryStore.defaultPageSize) {
        self.service = service
        self.pageSize = pageSize
    }

    deinit {
        currentTask?.cancel()
    }

    // MARK: - 首次拉取

    /// 首次进入 view 触发（对齐 view.task）· idle → loading（已在 loaded 后 no-op）
    func loadFirstIfNeeded() {
        guard case .idle = state else { return }
        loadFirst()
    }

    /// 强制首拉（清 items + loadSeq++）
    func loadFirst() {
        currentTask?.cancel()
        loadSeq += 1
        loadedPageCount = 0
        state = .loading
        chooseItemId = nil
        let seq = loadSeq
        currentTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performInitial(seq: seq)
        }
    }

    private func performInitial(seq: Int) async {
        do {
            let page = try await service.fetchPage(
                itemType: currentTab, pageIndex: 1, pageSize: pageSize
            )
            try Task.checkCancellation()
            guard seq == loadSeq else { return }
            loadedPageCount = 1
            let filtered = filterAllTabEntranceIfNeeded(page.records)
            let hasMore = filtered.count < page.totalNum
            if filtered.isEmpty && page.totalNum == 0 {
                state = .empty
            } else {
                state = .loaded(items: filtered, hasMore: hasMore)
            }
        } catch is CancellationError {
            return
        } catch {
            guard seq == loadSeq else { return }
            state = .error(items: nil, phase: .initial, message: humanReadable(error))
        }
    }

    // MARK: - 分页加载

    /// 触底加载下一页（.loaded(hasMore=true) 时可用）
    func loadMore() {
        guard case .loaded(let items, let hasMore) = state, hasMore else { return }
        currentTask?.cancel()
        loadSeq += 1
        state = .loadingMore(items: items)
        let seq = loadSeq
        currentTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performLoadMore(seq: seq, existing: items)
        }
    }

    private func performLoadMore(seq: Int, existing: [PropItem]) async {
        let nextPage = loadedPageCount + 1
        do {
            let page = try await service.fetchPage(
                itemType: currentTab, pageIndex: nextPage, pageSize: pageSize
            )
            try Task.checkCancellation()
            guard seq == loadSeq else { return }
            loadedPageCount = nextPage
            let filtered = filterAllTabEntranceIfNeeded(page.records)
            let all = existing + filtered
            let hasMore = all.count < page.totalNum
            state = .loaded(items: all, hasMore: hasMore)
        } catch is CancellationError {
            return
        } catch {
            guard seq == loadSeq else { return }
            state = .error(items: existing, phase: .loadMore, message: humanReadable(error))
        }
    }

    // MARK: - 下拉刷新

    /// sync 触发 · view 层 sync context 使用（`Button` action / `.refreshable` 之外的入口）
    func refresh() {
        currentTask?.cancel()
        loadSeq += 1
        loadedPageCount = 0
        let items = currentItems() ?? []
        state = items.isEmpty ? .loading : .refreshing(items: items)
        let seq = loadSeq
        currentTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRefresh(seq: seq, existing: items)
        }
    }

    /// async 版本 · `.refreshable { await store.refreshAsync() }` 使用
    /// 保证 spinner 保持到任务完成（list-refresh-preserve-items rule §规则 B）
    func refreshAsync() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        currentTask?.cancel()
        loadSeq += 1
        loadedPageCount = 0
        let items = currentItems() ?? []
        state = items.isEmpty ? .loading : .refreshing(items: items)
        let seq = loadSeq
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(seq: seq, existing: items)
        }
        currentTask = task
        await task.value
    }

    private func performRefresh(seq: Int, existing: [PropItem]) async {
        do {
            let page = try await service.fetchPage(
                itemType: currentTab, pageIndex: 1, pageSize: pageSize
            )
            try Task.checkCancellation()
            guard seq == loadSeq else { return }
            loadedPageCount = 1
            let filtered = filterAllTabEntranceIfNeeded(page.records)
            let hasMore = filtered.count < page.totalNum
            if filtered.isEmpty && page.totalNum == 0 {
                state = .empty
            } else {
                state = .loaded(items: filtered, hasMore: hasMore)
            }
            // 刷新后旧 chooseItemId 若不在 new records 清空（spec §2.1 selection）
            if let cid = chooseItemId, !filtered.contains(where: { $0.id == cid }) {
                chooseItemId = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard seq == loadSeq else { return }
            state = .error(items: existing, phase: .refresh, message: humanReadable(error))
        }
    }

    // MARK: - Tab 切换

    func changeTab(_ tab: PropTabItemType?) {
        guard tab != currentTab else { return }
        currentTab = tab
        chooseItemId = nil                                        // spec §2.1 changeTab clear selection
        loadFirst()
    }

    // MARK: - Retry（phase-aware · spec R4/R4b）

    func retry() {
        guard case .error(let items, let phase, _) = state else { return }
        switch phase {
        case .initial: loadFirst()
        case .loadMore:
            guard let items else { loadFirst(); return }
            // 回归 loaded(hasMore=true) 后 loadMore
            state = .loaded(items: items, hasMore: true)
            loadMore()
        case .refresh:
            guard let items, !items.isEmpty else { loadFirst(); return }
            state = .loaded(items: items, hasMore: loadedPageCount * pageSize < items.count)
            refresh()
        }
    }

    // MARK: - 佩戴 / 卸下（乐观 + snapshot 回滚）

    /// 佩戴或卸下（spec §2.2）· 前置校验 + 快照 + API + 失败回滚
    ///
    /// - Returns: `.success` / `.rejected(reason)` · 供 view 判断是否需要弹 toast
    @discardableResult
    func performOps(item: PropItem, action: PropEquipAction) async -> OpsResult {
        // 前置校验（对齐 H5 equipBtn 三条 toast）
        if item.isFromBag != 1 {
            return .rejected(.notOwned)
        }
        if item.wearStatus == 1 && action == .equip {
            return .rejected(.alreadyWorn)
        }
        if item.wearStatus != 1 && action == .unequip {
            return .rejected(.alreadyUnequipped)
        }
        // 并发（同一 item busy）拒绝
        if opsState.busyItemId == item.id {
            return .rejected(.busy)
        }

        // 快照
        let previousMineURL = AnchorInfoConsumerBridge.shared.currentURL(for: item.itemType)
        let previouslyEquipped = currentItems()?.first(where: {
            $0.itemType == item.itemType && $0.wearStatus == 1 && $0.id != item.id
        })?.id
        let snap = OpsSnapshot(
            previouslyEquippedItemId: previouslyEquipped,
            previousMineURL: previousMineURL,
            loadSeq: loadSeq
        )

        // 乐观更新
        opsState = (action == .equip) ? .wearing(itemId: item.id, snapshot: snap)
                                       : .removing(itemId: item.id, snapshot: snap)
        applyLocalOps(item: item, action: action)

        // API
        do {
            try await service.equipOps(itemId: item.id, action: action)
            opsState = .idle
            return .success
        } catch {
            // 若 seq 变化说明 refresh 已在途 → 不回滚（服务端为准）
            if snap.loadSeq != loadSeq {
                opsState = .idle
                return .rejected(.staleServerAuthoritative)
            }
            // 回滚 items + mine
            rollbackLocalOps(item: item, action: action, snapshot: snap)
            opsState = .idle
            return .rejected(.apiFailed(message: humanReadable(error)))
        }
    }

    /// Ops 结果（view 层用于弹 toast + banner 分档 · spec toast-vs-banner rule）
    enum OpsResult: Equatable {
        case success
        case rejected(RejectionReason)
    }
    enum RejectionReason: Equatable {
        case notOwned                    // 未拥有（对齐 H5 "You can not equip or unequip this"）
        case alreadyWorn                 // 已穿戴又 equip（"You already wear this"）
        case alreadyUnequipped           // 未穿戴又 unequip（"You already unequip this"）
        case busy                        // 同 item ops 进行中
        case staleServerAuthoritative    // Ops 期 refresh 已在途，不回滚
        case apiFailed(message: String)  // 网络/业务错
    }

    private func applyLocalOps(item: PropItem, action: PropEquipAction) {
        // items 同 itemType 全 wearStatus=0，当前置 1（equip）
        mutateItems { items in
            for i in items.indices where items[i].itemType == item.itemType {
                items[i] = items[i].withWearStatus(0)
            }
            if action == .equip, let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = items[idx].withWearStatus(1)
            }
        }
        // 写 AnchorInfoStore.mine（Consumer bridge · L3 消费点接入）
        let newURL: String? = (action == .equip) ? item.itemImg : nil
        AnchorInfoConsumerBridge.shared.write(itemType: item.itemType, url: newURL)
    }

    private func rollbackLocalOps(item: PropItem, action: PropEquipAction, snapshot: OpsSnapshot) {
        // items 恢复：先全 itemType 清零；若有之前穿戴的 id 恢复为 1
        mutateItems { items in
            for i in items.indices where items[i].itemType == item.itemType {
                items[i] = items[i].withWearStatus(0)
            }
            if let prev = snapshot.previouslyEquippedItemId,
               let idx = items.firstIndex(where: { $0.id == prev }) {
                items[idx] = items[idx].withWearStatus(1)
            }
        }
        // mine 恢复
        AnchorInfoConsumerBridge.shared.write(itemType: item.itemType, url: snapshot.previousMineURL)
    }

    // MARK: - 生命周期辅助

    /// view onDisappear 主动 cancel（红队 d5-S3）
    func cancelInFlight() {
        currentTask?.cancel()
    }

    /// SessionStore.logout 挂钩（spec R22 · session-scoped-store-refresh rule）
    func clear() {
        currentTask?.cancel()
        loadSeq += 1
        loadedPageCount = 0
        currentTab = nil
        chooseItemId = nil
        opsState = .idle
        state = .idle
    }

    // MARK: - Utilities

    /// 当前 state 内的 items（若有）
    func currentItems() -> [PropItem]? {
        switch state {
        case .loaded(let items, _),
             .loadingMore(let items),
             .refreshing(let items):
            return items
        case .error(let items, _, _):
            return items
        case .idle, .loading, .empty:
            return nil
        }
    }

    /// 内部 mutation helper · 保持 state case 结构，只改 items
    private func mutateItems(_ transform: (inout [PropItem]) -> Void) {
        switch state {
        case .loaded(var items, let hasMore):
            transform(&items)
            state = .loaded(items: items, hasMore: hasMore)
        case .loadingMore(var items):
            transform(&items)
            state = .loadingMore(items: items)
        case .refreshing(var items):
            transform(&items)
            state = .refreshing(items: items)
        case .error(var items, let phase, let msg):
            if items != nil {
                transform(&items!)
                state = .error(items: items, phase: phase, message: msg)
            }
        case .idle, .loading, .empty: break
        }
    }

    /// All Tab 时前端过滤 Entrance 记录（spec §5 R15 · 对齐 H5 enabledItemTypes）
    private func filterAllTabEntranceIfNeeded(_ records: [PropItem]) -> [PropItem] {
        guard currentTab == nil else { return records }
        return records.filter { PropTabItemType.allTabAllowedRawValues.contains($0.itemType.rawValue) }
    }

    /// Error → 用户可读文案
    private func humanReadable(_ error: Error) -> String {
        if let e = error as? PropsServiceError {
            return e.displayMessage
        }
        return "Something went wrong. Please retry."
    }
}

// MARK: - AnchorInfoConsumerBridge

/// 道具消费点桥接。
///
/// Chat Skin 已接入真实 `AnchorInfoStore.mine.chatBubble`，使装备结果可以立即进入所有消息发送路径；
/// 其余道具类型仍保留原有内存桥接，等待各自的资料字段完成对齐。
@MainActor
final class AnchorInfoConsumerBridge {
    static let shared = AnchorInfoConsumerBridge()
    private init() {}

    private var mineURLs: [PropItemType: String] = [:]

    func currentURL(for itemType: PropItemType) -> String? {
        #if !HILY_TESTS
        if itemType == .chatSkin,
           let chatBubble = AnchorInfoStore.shared.currentChatBubble,
           !chatBubble.isEmpty {
            return chatBubble
        }
        #endif
        return mineURLs[itemType]
    }

    func write(itemType: PropItemType, url: String?) {
        if let url, !url.isEmpty {
            mineURLs[itemType] = url
        } else {
            mineURLs.removeValue(forKey: itemType)
        }
        #if !HILY_TESTS
        if itemType == .chatSkin {
            AnchorInfoStore.shared.applyChatBubble(url)
        }
        #endif
    }

    /// SessionStore.logout 挂钩
    func clear() {
        mineURLs.removeAll()
    }
}
