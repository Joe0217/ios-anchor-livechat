import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "MomentFeedStore")

/// Circle Moment 子 tab 的状态机 (A-spec §3.3)。
///
/// trial #1 范围：
/// - 读：首页加载 + 触底加载下一页
/// - 写：乐观点赞**成功路径** (失败回滚 + 连点去重移 trial 后)
///
/// **不依赖** `CircleService.shared` 直接，而是通过 `CircleServiceProtocol` 注入；
/// 单测 (步 1a) 通过 mock instance 直接断言状态机迁移；
/// 真接入 (步 1c) 通过 `CircleService.shared` 默认值。
///
/// **挂载位置**：spec §6B.6 要求 `@StateObject` 挂在 Circle 容器层而非 Moment view 本身，
/// 否则内层 page 切换会重建 store，违反 §5.7/§5.8 状态保留验收。
@MainActor
final class MomentFeedStore: ObservableObject {

    /// 状态机 (spec §3.3)
    enum State: Equatable {
        case idle
        case loadingFirst
        /// 首页/翻页结果合并后的稳定态
        case loaded(posts: [MomentPost], hasMore: Bool)
        /// 翻页 inflight；posts 是已加载的，不抹掉
        case loadingMore(posts: [MomentPost])
        /// 翻页失败；posts 是已加载的，不抹掉；用户可 retry
        case loadMoreError(posts: [MomentPost])
        /// 首次加载失败 (含空)；不自动 retry，等用户点 retry
        case error

        /// 视图层取 posts 的便捷访问 (空 posts = nil/.idle/.loadingFirst/.error)。
        var posts: [MomentPost] {
            switch self {
            case .idle, .loadingFirst, .error:
                return []
            case .loaded(let posts, _),
                 .loadingMore(let posts),
                 .loadMoreError(let posts):
                return posts
            }
        }

        /// 视图层取 hasMore (仅 .loaded 才有意义；其他态返 false 防误判)
        var hasMore: Bool {
            if case .loaded(_, let hasMore) = self { return hasMore }
            return false
        }
    }

    @Published private(set) var state: State = .idle

    private let service: CircleServiceProtocol
    private let pageSize: Int
    /// 数据源：决定 fetchPage 走哪个 service 方法（official/all/my）。
    private let source: MomentSource

    /// posts 数组内存上限。超过时在 `startLoadingMore` 成功合并后 trim 最旧条目（顶部）。
    ///
    /// **取值依据**：MomentPost ~5KB（含 imgUrls/textContent），50 条 ≈ 250KB，相当于最近 10 页（pageSize=5）。
    /// **trim 时机约束**：仅在 `loadMore` 成功 append 后触发——此时新 page 已加入数组末尾，
    /// 用户视线在底部，trim 顶部对滚动位置和视觉无影响（+M -M 净变化为 0）。
    /// 单测可注入较小值（如 5）验证 trim 行为。
    private let maxPostsInMemory: Int

    /// 当前已加载到的页码 (next page = currentPage + 1)。
    /// **注意**：与 posts 数组长度解耦——trim 删除 posts 不影响 currentPage 推进。
    private var currentPage: Int = 0

    /// 正在跑的网络任务 — 切走时 cancel；切回时如果还在跑，不重发
    private var inflightTask: Task<Void, Never>?

    /// `.momentPublished` 通知挂起的"待刷新"标记（J INV4 + keep-alive 隔离规则）。
    ///
    /// 设计：
    /// - 发布成功广播 `.momentPublished`；本 store（source=.me）init 时 addObserver
    /// - keep-alive 架构下 me sub-tab 可能不可见，立即 fetch 浪费请求
    /// - 收到通知仅 set `pendingReload=true`，下次 `enterMoment()`（用户切到 me 子 tab）才真 fetch
    /// - 对齐 [.claude/rules/swiftui-keepalive-publisher-isolation.md](../../../.claude/rules/swiftui-keepalive-publisher-isolation.md)
    private var pendingReload: Bool = false
    private var momentPublishedObserver: NSObjectProtocol?

    init(source: MomentSource = .moment,
         service: CircleServiceProtocol = CircleService.shared,
         pageSize: Int = 5,
         maxPostsInMemory: Int = .max) {
        // maxPostsInMemory 默认 .max → 生产路径 trim 永不触发，
        // 用于验证用户反馈"滑几页老内容消失"——确认是 trim 上限太低还是别的成因后再恢复合理值。
        self.source = source
        self.service = service
        self.pageSize = pageSize
        self.maxPostsInMemory = maxPostsInMemory

        // 仅 source=.me 监听 .momentPublished —— official/moment 子 tab 不需要刷新自己的源
        if case .me = source {
            self.momentPublishedObserver = NotificationCenter.default.addObserver(
                forName: .momentPublished,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // closure 在 .main queue 触发；@MainActor 隔离下可直接写
                Task { @MainActor [weak self] in
                    self?.pendingReload = true
                    // 若用户已在 me 子 tab（enterMoment 已被调用一次，state ≠ .idle），立即刷
                    self?.consumePendingReloadIfActive()
                }
            }
        }
    }

    deinit {
        if let observer = momentPublishedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 按 source 派发到具体 service 方法。新增 source 时此处加一行 case 即可。
    private func fetchPage(_ page: Int) async throws -> MomentPage {
        switch source {
        case .official:
            return try await service.getOfficialMoments(pageSize: pageSize, currentPage: page)
        case .moment:
            return try await service.getAllMoments(pageSize: pageSize, currentPage: page)
        case .me(let userId):
            return try await service.getMyMoments(userId: userId, pageSize: pageSize, currentPage: page)
        }
    }

    // MARK: - Actions

    /// 进入 Moment 子 tab — 触发首次加载 (idempotent)。
    /// - `.idle` → 触发 `.loadingFirst`
    /// - `.error` → **不自动 retry** (spec §5.11)，保持 `.error` 等用户点 retry
    /// - 其他态 (含 .loadingFirst / .loaded / .loadingMore) → 不重发，保留现状
    func enterMoment() {
        // 优先消费"发布成功后挂起的刷新"——keep-alive 下用户切回 me 子 tab 时执行（J INV4）
        if pendingReload {
            pendingReload = false
            startLoadingFirst()
            return
        }
        switch state {
        case .idle:
            startLoadingFirst()
        case .loadingFirst, .loaded, .loadingMore, .loadMoreError, .error:
            break
        }
    }

    /// 外部触发的强制刷新（J spec INV4 用户主动下拉刷新等）。
    /// 区别于 enterMoment：不论当前 state 都重新拉首页。
    func reload() {
        pendingReload = false
        startLoadingFirst()
    }

    /// notification 触发：若 store 处于"用户已访问过"状态（≠ idle），立即消费 pendingReload；
    /// 否则保持 pendingReload，等 enterMoment 时再触发（避免不可见时浪费请求）。
    private func consumePendingReloadIfActive() {
        guard pendingReload else { return }
        // .idle 表示用户从未访问过 me 子 tab → 保持 pendingReload，等 enterMoment 时统一拉
        if case .idle = state { return }
        pendingReload = false
        startLoadingFirst()
    }

    /// 触底加载下一页。
    /// 仅 `.loaded(_, hasMore=true)` 触发；其他态忽略 (spec §5.3a: hasMore=false 不重发)。
    func loadMore() {
        guard case .loaded(let posts, let hasMore) = state, hasMore else { return }
        startLoadingMore(currentPosts: posts)
    }

    /// 点赞 / 取消点赞 (乐观更新成功路径，spec §3.3)。
    /// - 按 `postId` 查表 (不按 index — 翻页拼接后 index 已变)
    /// - 立即改 UI (LikeFlag 切换 + likeCount ±1)
    /// - 异步发请求；200 视为成功，失败 trial #1 不回滚 (移 trial 后)
    func tapLike(postId: Int) {
        guard case .loaded(var posts, let hasMore) = state,
              let idx = posts.firstIndex(where: { $0.postId == postId }) else {
            return
        }
        let current = posts[idx]
        let newFlag = (current.likeFlag == 1) ? 0 : 1
        let delta = (newFlag == 1) ? 1 : -1
        posts[idx].likeFlag = newFlag
        posts[idx].likeCount = (current.likeCount ?? 0) + delta
        state = .loaded(posts: posts, hasMore: hasMore)

        // fire-and-forget；trial #1 仅成功路径，失败不回滚
        Task { [service] in
            do {
                try await service.like(postId: postId, optionType: newFlag)
            } catch {
                logger.warning("like failed postId=\(postId) (trial #1 暂不回滚): \(String(describing: error))")
            }
        }
    }

    /// 用户点 retry。
    /// - `.error` → 回 `.loadingFirst`
    /// - `.loadMoreError` → 回 `.loadingMore` (posts 保留)
    /// - 其他态忽略
    func retry() {
        switch state {
        case .error:
            startLoadingFirst()
        case .loadMoreError(let posts):
            startLoadingMore(currentPosts: posts)
        default:
            break
        }
    }

    /// 切走 Moment 时调用 (从 Circle 切到 Live、或从 Moment 切到 Official/Me)。
    /// 取消 inflight；若卡在 loading 态，恢复为可再次触发的 state
    /// （否则切回来时 UI 会一直显示 loadingCenter 转圈，因为 Task 已 cancel 无人转 state）。
    func cancelInflight() {
        inflightTask?.cancel()
        inflightTask = nil
        // Task 内 `if Task.isCancelled { return }` 会跳过 state 转移；这里主动兜底
        switch state {
        case .loadingFirst:
            state = .idle
        case .loadingMore(let posts):
            // 保留已加载 posts；hasMore 保守设 true 让用户下拉/触底可再拉
            state = .loaded(posts: posts, hasMore: true)
        default:
            break
        }
    }

    // MARK: - Internal load logic

    private func startLoadingFirst() {
        inflightTask?.cancel()
        state = .loadingFirst
        currentPage = 0
        inflightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.fetchPage(1)
                if Task.isCancelled { return }
                self.currentPage = 1
                self.state = .loaded(posts: page.posts, hasMore: page.hasMore)
            } catch {
                if Task.isCancelled { return }
                logger.error("loadingFirst failed: \(String(describing: error))")
                self.state = .error
            }
        }
    }

    private func startLoadingMore(currentPosts: [MomentPost]) {
        inflightTask?.cancel()
        state = .loadingMore(posts: currentPosts)
        let nextPage = currentPage + 1
        inflightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.fetchPage(nextPage)
                if Task.isCancelled { return }
                self.currentPage = nextPage
                // trim 时机严格限定在合并 append 后：用户视线在底部（loadMore 触发条件），
                // +M -M 净变化为 0 → contentSize 不变 → 滚动位置无跳变。
                let merged = currentPosts + page.posts
                let trimmed = self.trimIfNeeded(merged)
                self.state = .loaded(posts: trimmed, hasMore: page.hasMore)
            } catch {
                if Task.isCancelled { return }
                logger.error("loadingMore failed page=\(nextPage): \(String(describing: error))")
                self.state = .loadMoreError(posts: currentPosts)
            }
        }
    }

    /// 内存上限保护：超过 `maxPostsInMemory` 时丢顶部最旧条目（用户已滚过的部分）。
    ///
    /// 朋友圈分页是"时间倒序"：page=1 最新（数组头），page=N 最早（数组尾）。
    /// 用户在底部触底加载更早内容 → trim 删顶部"已看过的较新内容" → 不打扰用户当前阅读。
    /// 用户向上滑回顶部超过 `maxPostsInMemory` 的范围时会发现内容消失——是预期的上限语义，
    /// 用户可下拉刷新重拉 page 1。
    private func trimIfNeeded(_ posts: [MomentPost]) -> [MomentPost] {
        guard posts.count > maxPostsInMemory else { return posts }
        let trimmed = Array(posts.suffix(maxPostsInMemory))
        logger.info("trimmed moment posts: \(posts.count) → \(trimmed.count) (max=\(self.maxPostsInMemory))")
        return trimmed
    }

#if DEBUG
    /// Preview 用工厂：直接注入一个稳定 state，service 永不被调用。
    /// 用于 SwiftUI PreviewProvider 覆盖 spec §4/§5 各合法状态 (idle/loading/loaded/error/...)。
    static func preview(state: State, pageSize: Int = 20) -> MomentFeedStore {
        let store = MomentFeedStore(service: PreviewCircleService(), pageSize: pageSize)
        store.state = state
        return store
    }
#endif
}

#if DEBUG
/// Preview-only：永远挂起的 service，不会真发请求。
/// 单测不用这个 (单测用 `FakeCircleService`)。
private final class PreviewCircleService: CircleServiceProtocol {
    func getMyMoments(userId: Int, pageSize: Int, currentPage: Int) async throws -> MomentPage {
        try await Task.sleep(nanoseconds: .max)
        return .empty
    }
    func getAllMoments(pageSize: Int, currentPage: Int) async throws -> MomentPage {
        try await Task.sleep(nanoseconds: .max)
        return .empty
    }
    func getOfficialMoments(pageSize: Int, currentPage: Int) async throws -> MomentPage {
        try await Task.sleep(nanoseconds: .max)
        return .empty
    }
    func like(postId: Int, optionType: Int) async throws {}
    func getComments(postId: Int, pageSize: Int, currentPage: Int) async throws -> [MomentComment] {
        try await Task.sleep(nanoseconds: .max)
        return []
    }
}
#endif
