import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "BlocklistVM")

/// 黑名单列表 ViewModel（spec §3 + §4.4）。
///
/// 实现 spec §3.3 全部 8 条不变量：
/// 1. loadState 单一态
/// 2. 乐观删除原子性（pendingRemoveIds 守 view button disabled）
/// 3. 失败回滚位置稳定（除非代际漂移）
/// 4. 删除并发隔离（loadGeneration token）
/// 5. items 非空守卫
/// 6. transientError 生命周期 2s（View 侧 `.task(id:)` 实现，VM 仅赋值）
/// 7. 触底 + 刷新隔离（snapshot generation 比对）
/// 8. session 失效跨场景（APIClient 自动 post .apiSessionInvalidated，本 VM 无须处理）
@MainActor
final class BlocklistViewModel: ObservableObject {
    @Published private(set) var items: [BlocklistItem] = []
    @Published private(set) var loadState: BlocklistLoadState = .idle
    @Published var transientError: String?
    /// 进行中的删除 userId 集合（View 据此 disable 删除按钮，防双击重复请求）
    @Published private(set) var pendingRemoveIds: Set<String> = []
    /// hasMore 单独存（spec §4.5），方便 View 在 `.loaded` 态判断是否还能触底加载
    @Published private(set) var hasMore: Bool = true

    private let service: BlocklistServiceProtocol
    private let pageSize: Int
    /// 代际 token：每次 reset（首页/刷新）递增；删除回滚 / load 回包前比对，过期则弃
    private var loadGeneration: Int = 0
    private var currentPage: Int = 0
    /// 网络错误兜底文案（避免 ViewModel 直接吃 L10n，注入式让单测稳定）
    private let networkErrorFallback: String
    private let badUserIdFallback: String

    /// `.blocklistChanged` observer（H-0 拉黑成功后 post → 黑名单列表自动 refresh，spec §5.4）。
    private var blocklistChangedObserver: NSObjectProtocol?

    init(service: BlocklistServiceProtocol,
         pageSize: Int = 20,
         networkErrorFallback: String = "Network error, please try again.",
         badUserIdFallback: String = "Invalid user ID") {
        self.service = service
        self.pageSize = pageSize
        self.networkErrorFallback = networkErrorFallback
        self.badUserIdFallback = badUserIdFallback
        // 跨页同步：H-0 用户详情页拉黑成功 post `.blocklistChanged` → 本 VM reload
        // 不区分 sender（自身 post 也接收）：黑名单列表自己没有 post 通道，不会自触发死循环
        self.blocklistChangedObserver = NotificationCenter.default.addObserver(
            forName: .blocklistChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                logger.info("blocklist received .blocklistChanged, reloading first page")
                await self.loadFirstPage()
            }
        }
    }

    deinit {
        if let obs = blocklistChangedObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Actions

    /// 拉首页（onAppear / 下拉刷新调用）。
    func loadFirstPage() async {
        await load(reset: true)
    }

    /// 触底加载下一页。
    func loadMore() async {
        guard hasMore else { return }
        await load(reset: false)
    }

    /// 错误后用户点 retry。
    func retry() async {
        // items 为空 → 重新拉首页；非空 → 触底加载下一页
        if items.isEmpty {
            await load(reset: true)
        } else {
            await load(reset: false)
        }
    }

    /// 移除黑名单条目（spec §4.4 v2）。
    func unblock(_ item: BlocklistItem) async {
        // 1. 类型转换在最外层守卫，避免任何 mutation（不变量 #1 持稳）
        guard let uidInt = Int(item.userId) else {
            transientError = badUserIdFallback
            logger.warning("unblock: bad userId=\(item.userId, privacy: .private)")
            return
        }
        // 2. items 非空守卫（不变量 #5）
        guard !items.isEmpty else { return }
        // 3. 同 userId 并发守卫（不变量 #2）
        guard !pendingRemoveIds.contains(item.userId) else { return }
        // 4. 找到原 index；找不到（异步刷新已删除该项）→ 无操作
        guard let originalIdx = items.firstIndex(where: { $0.id == item.id }) else { return }

        // 5. pending 标记 + 记录代际 token
        pendingRemoveIds.insert(item.userId)
        let myGeneration = loadGeneration
        defer { pendingRemoveIds.remove(item.userId) }   // 兜底释放

        // 6. 乐观删除
        let removed = items.remove(at: originalIdx)

        do {
            try await service.removeBlock(
                request: BlockOptRequest(type: 1, userId: uidInt, yxAccid: item.yxAccid)
            )
            logger.info("unblock uid=\(item.userId, privacy: .private) ok")
        } catch {
            // 7. 回滚前检测代际 token（不变量 #4）
            guard myGeneration == loadGeneration else {
                logger.warning("unblock uid=\(item.userId, privacy: .private) failed but generation drifted, drop rollback")
                return
            }
            // 8. 失败回滚：插回原 index（边界裁剪到当前 items.count）
            let insertAt = min(originalIdx, items.count)
            items.insert(removed, at: insertAt)
            // 9. 文案：APIError 用接口 message，其他用通用网络错误
            if let e = error as? APIError {
                transientError = e.message
            } else {
                transientError = networkErrorFallback
            }
            logger.error("unblock uid=\(item.userId, privacy: .private) error: \(String(describing: error), privacy: .private)")
        }
    }

    /// View 在 `.task(id: transientError)` 内 sleep 2s 后调用本方法清掉 toast。
    func clearTransientError() {
        transientError = nil
    }

    #if DEBUG
    /// Preview 专用：手动标记某 userId 处于 pending 状态，覆盖 R-8 视觉态。
    func beginPreviewPending(userId: String) {
        pendingRemoveIds.insert(userId)
    }
    #endif

    // MARK: - Internal load logic

    private func load(reset: Bool) async {
        // 单一态守卫（不变量 #1）：loading 中拒绝再触发
        guard !loadState.isLoading else { return }

        if reset {
            loadGeneration += 1
            loadState = .loadingFirstPage
        } else {
            guard hasMore else { return }
            loadState = .loadingMore
        }
        let nextPage = reset ? 1 : currentPage + 1
        let snapshotGen = loadGeneration

        do {
            let page = try await service.fetchActive(page: nextPage, size: pageSize)
            // 代际过期 → 丢弃结果（不变量 #4 + #7）
            guard snapshotGen == loadGeneration else { return }

            // 真分页 fallback 检测（spec §4.5 / review #11）：
            // 触底加载本批与已加载尾 N 条 id 完全相同 → 服务端不支持真分页，停止
            if !reset && !page.isEmpty
                && page.map(\.id) == items.suffix(page.count).map(\.id)
            {
                logger.warning("blocklist: paging returned same items, assume server doesn't support paging")
                hasMore = false
                loadState = .loaded
                return
            }

            if reset {
                items = page
            } else {
                items.append(contentsOf: page)
            }
            currentPage = nextPage
            hasMore = page.count >= pageSize
            loadState = .loaded
        } catch let e as APIError {
            guard snapshotGen == loadGeneration else { return }
            loadState = .error(L10n.blocklistLoadErrorRetry)
        } catch {
            guard snapshotGen == loadGeneration else { return }
            loadState = .error(L10n.blocklistLoadErrorRetry)
        }
    }
}
