import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveListVM")

/// List 子页 ViewModel（对齐 H5 `views/home/online/online.vue` + `prime/prime.vue` + `components/list.vue`）。
///
/// **两 segment 数据隔离 + keep-alive 体感**（对齐 H5 v-swiper + keep-alive 行为）：
/// - online / prime 各持自己的 items / loadState / hasMore / currentPage
/// - segment 切换**瞬时**切到目标 segment 的缓存，不等接口、不清空老缓存
/// - 目标 segment 从未加载过（`.idle`）→ 触发首次加载；已加载过 → 显示上次数据不重发
/// - 各 segment 的分页位置独立，互不干扰
///
/// 状态机/分页模式照搬 BlocklistViewModel trial #2：单一态、代际 token（按 segment 隔离）、
/// 真分页 fallback（连续两页相同 id → 服务端不支持真分页停止）。
@MainActor
final class LiveListViewModel: ObservableObject {

    /// 单个 segment 的完整状态。用 value type 让字典 in-place 修改触发 @Published。
    struct SegmentState: Equatable {
        var items: [LiveListAnchor] = []
        var loadState: LiveListLoadState = .idle
        var hasMore: Bool = true
        var currentPage: Int = 0
    }

    /// 当前 segment（View 切 segment 直接改这里）。didSet 处理瞬时切换 + 首次加载触发。
    @Published var segment: LiveListSegment = .online {
        didSet {
            guard oldValue != segment else { return }
            // 切换瞬时即可——目标 segment 从未加载过 → 触发首次加载；否则不发请求（keep-alive 体感）
            if states[segment]?.loadState == .idle {
                Task { await loadFirstPage() }
            }
        }
    }

    /// 按 segment 隔离的状态。@Published 让 View computed property（items/loadState/hasMore）能 re-evaluate。
    @Published private var states: [LiveListSegment: SegmentState] = [
        .online: SegmentState(),
        .prime: SegmentState(),
    ]

    // MARK: - 派生给 View（按当前 segment 取）

    var items: [LiveListAnchor] { states[segment]?.items ?? [] }
    var loadState: LiveListLoadState { states[segment]?.loadState ?? .idle }
    var hasMore: Bool { states[segment]?.hasMore ?? true }

    private let service: LiveListServiceProtocol
    private let pageSize: Int
    /// 代际 token 按 segment 隔离：online 的请求漂移不影响 prime。
    private var loadGenerations: [LiveListSegment: Int] = [.online: 0, .prime: 0]
    private let networkErrorFallback: String

    init(service: LiveListServiceProtocol = LiveListService.shared,
         pageSize: Int = 20,
         networkErrorFallback: String = "Network error, please try again.") {
        self.service = service
        self.pageSize = pageSize
        self.networkErrorFallback = networkErrorFallback
    }

    // MARK: - Actions

    /// 拉首页（首次进入 / 下拉刷新 / segment 切换触发）。
    func loadFirstPage() async {
        await load(reset: true, for: segment)
    }

    /// 触底加载下一页。
    func loadMore() async {
        guard states[segment]?.hasMore == true else { return }
        await load(reset: false, for: segment)
    }

    /// 错误后用户点 retry：空列表 → 重拉首页；非空 → 触底重试。
    func retry() async {
        let isEmpty = states[segment]?.items.isEmpty ?? true
        await load(reset: isEmpty, for: segment)
    }

    // MARK: - Internal load logic

    private func load(reset: Bool, for targetSegment: LiveListSegment) async {
        // 单一态守卫（按 segment 隔离）
        guard !(states[targetSegment]?.loadState.isLoading ?? false) else { return }

        if reset {
            updateState(for: targetSegment) {
                $0.loadState = .loadingFirstPage
            }
            loadGenerations[targetSegment, default: 0] += 1
        } else {
            guard states[targetSegment]?.hasMore == true else { return }
            updateState(for: targetSegment) {
                $0.loadState = .loadingMore
            }
        }
        let nextPage = reset ? 1 : (states[targetSegment]?.currentPage ?? 0) + 1
        let snapshotGen = loadGenerations[targetSegment, default: 0]
        let snapshotKeyword = targetSegment.keyword

        do {
            let page = try await service.fetchUsers(
                keyword: snapshotKeyword,
                currentPage: nextPage,
                pageSize: pageSize
            )
            // 代际过期 → 丢弃（同 segment 内重复 reset / 段位外切换无关）
            guard snapshotGen == loadGenerations[targetSegment, default: 0] else { return }

            // 真分页 fallback：连续两页相同 id → 服务端不支持真分页停止
            let currentItems = states[targetSegment]?.items ?? []
            if !reset && !page.isEmpty
                && page.map(\.id) == currentItems.suffix(page.count).map(\.id)
            {
                logger.warning("liveList[\(String(describing: targetSegment))]: paging returned same items, stop")
                updateState(for: targetSegment) {
                    $0.hasMore = false
                    $0.loadState = .loaded
                }
                return
            }

            updateState(for: targetSegment) {
                if reset {
                    $0.items = page
                } else {
                    $0.items.append(contentsOf: page)
                }
                $0.currentPage = nextPage
                $0.hasMore = page.count >= pageSize
                $0.loadState = .loaded
            }
        } catch let e as APIError {
            guard snapshotGen == loadGenerations[targetSegment, default: 0] else { return }
            updateState(for: targetSegment) {
                $0.loadState = .error(e.message)
            }
        } catch {
            guard snapshotGen == loadGenerations[targetSegment, default: 0] else { return }
            updateState(for: targetSegment) {
                $0.loadState = .error(networkErrorFallback)
            }
        }
    }

    /// helper：同 segment 多字段修改聚成一次 publisher（避免 view 多次 re-render）。
    private func updateState(for seg: LiveListSegment, _ transform: (inout SegmentState) -> Void) {
        var s = states[seg] ?? SegmentState()
        transform(&s)
        states[seg] = s
    }

    #if DEBUG
    /// Preview 用工厂：注入静态 items，service 不被调用。
    static func preview(segment: LiveListSegment = .online,
                        items: [LiveListAnchor] = [],
                        loadState: LiveListLoadState = .loaded) -> LiveListViewModel {
        let vm = LiveListViewModel(service: PreviewLiveListService())
        vm.segment = segment
        vm.updateState(for: segment) {
            $0.items = items
            $0.loadState = loadState
        }
        return vm
    }
    #endif
}

#if DEBUG
/// Preview-only：永挂起的 service，不发请求。
private final class PreviewLiveListService: LiveListServiceProtocol {
    func fetchUsers(keyword: Int, currentPage: Int, pageSize: Int) async throws -> [LiveListAnchor] {
        try await Task.sleep(nanoseconds: .max)
        return []
    }
}
#endif
