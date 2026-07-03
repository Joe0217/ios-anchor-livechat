import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveStreamVM")

/// Live 广场 ViewModel（对齐 H5 `views/home/liveList.vue`）。
///
/// 状态机 / 分页模式照搬 LiveListViewModel：单一态、代际 token、真分页 fallback。
/// 与 LiveList 的差异：无 segment 分段，单一列表；数据源 `getLiveList`。
///
/// **请求生命周期隔离**（同 AnchorInfoStore 模式）：
/// 请求经 `Task.detached` 启动，view cancel（refreshable 完成 / 切 tab / body re-eval）
/// 不影响 URLSession task 继续完成——否则会报 `NSURLErrorCancelled -999`。
@MainActor
final class LiveStreamViewModel: ObservableObject {

    @Published private(set) var items: [LiveStreamAnchor] = []
    @Published private(set) var loadState: LiveStreamLoadState = .idle
    @Published private(set) var hasMore: Bool = true

    private let service: LiveStreamServiceProtocol
    /// 首屏页大小（首次加载 / 下拉刷新）——用户偏好：更小首屏更快出内容。
    private let firstPageSize: Int
    /// 后续每页页大小（触底加载）。
    private let pageSize: Int
    private var currentPage: Int = 0
    private var loadGeneration: Int = 0
    private let networkErrorFallback: String

    /// 进行中的 detached task 引用——避免 refreshable / view cancel 传播到 URLSession。
    private var inflightTask: Task<Void, Never>?

    init(service: LiveStreamServiceProtocol = LiveStreamService.shared,
         firstPageSize: Int = 6,
         pageSize: Int = 10,
         networkErrorFallback: String = "Network error, please try again.") {
        self.service = service
        self.firstPageSize = firstPageSize
        self.pageSize = pageSize
        self.networkErrorFallback = networkErrorFallback
    }

    /// 根据当前页返回该页应请求的 size。page=1 走 firstPageSize，其余走 pageSize。
    private func size(forPage page: Int) -> Int {
        page == 1 ? firstPageSize : pageSize
    }

    // MARK: - Actions

    /// 拉首页（首次进入 / 下拉刷新触发）。
    func loadFirstPage() async {
        await performLoad(reset: true)
    }

    /// 触底加载下一页。
    func loadMore() async {
        guard hasMore else { return }
        await performLoad(reset: false)
    }

    /// 错误后 retry：空列表 → 重拉首页；非空 → 触底重试。
    func retry() async {
        await performLoad(reset: items.isEmpty)
    }

    // MARK: - Internal load logic

    /// 请求生命周期隔离入口：detached task 启动 → view cancel 不影响 URLSession。
    /// 外层 await 保持 refreshable UI 显示到实际请求完成才收起。
    private func performLoad(reset: Bool) async {
        // 已有 inflight → 挂等它完成（保 refreshable UI 反馈时长；也避免同一时刻两次请求）
        if let inflightTask {
            await inflightTask.value
            return
        }
        guard !loadState.isLoading else {
            logger.info("performLoad skip: already loading reset=\(reset)")
            return
        }
        let task = Task.detached { @MainActor [self] in
            await doLoad(reset: reset)
        }
        inflightTask = task
        await task.value
        inflightTask = nil
    }

    private func doLoad(reset: Bool) async {
        if reset {
            loadState = .loadingFirstPage
            loadGeneration += 1
        } else {
            guard hasMore else { return }
            loadState = .loadingMore
        }
        let nextPage = reset ? 1 : currentPage + 1
        let usedSize = size(forPage: nextPage)
        let snapshotGen = loadGeneration
        logger.info("load start reset=\(reset) page=\(nextPage) size=\(usedSize) gen=\(snapshotGen) prevItems=\(self.items.count)")

        do {
            let page = try await service.fetchLiveList(currentPage: nextPage, pageSize: usedSize)
            guard snapshotGen == loadGeneration else {
                logger.info("load discard: gen expired snap=\(snapshotGen) cur=\(self.loadGeneration)")
                return
            }

            // 真分页 fallback：连续两页相同 id → 服务端不支持真分页停止
            if !reset && !page.isEmpty
                && page.map(\.id) == items.suffix(page.count).map(\.id)
            {
                logger.warning("liveStream: paging returned same items, stop")
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
            // hasMore 用**本次请求的 size** 判——page.count < 请求的 size 说明后端没更多了
            hasMore = page.count >= usedSize
            loadState = .loaded
            logger.info("load applied reset=\(reset) items=\(self.items.count) hasMore=\(self.hasMore)")
        } catch let e as APIError {
            guard snapshotGen == loadGeneration else { return }
            loadState = .error(e.message)
            logger.error("load APIError code=\(e.code) message=\(e.message, privacy: .public)")
        } catch {
            guard snapshotGen == loadGeneration else { return }
            loadState = .error(networkErrorFallback)
            logger.error("load error: \(String(describing: error), privacy: .public)")
        }
    }

    #if DEBUG
    /// Preview 用工厂：注入静态 items，service 不被调用。
    static func preview(items: [LiveStreamAnchor] = [],
                        loadState: LiveStreamLoadState = .loaded) -> LiveStreamViewModel {
        let vm = LiveStreamViewModel(service: PreviewLiveStreamService())
        vm.items = items
        vm.loadState = loadState
        return vm
    }
    #endif
}

#if DEBUG
private final class PreviewLiveStreamService: LiveStreamServiceProtocol {
    func fetchLiveList(currentPage: Int, pageSize: Int) async throws -> [LiveStreamAnchor] {
        try await Task.sleep(nanoseconds: .max)
        return []
    }
}
#endif
