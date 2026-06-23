import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "MomentTabVM")

/// Moment tab 数据源：分页拉取我的动态，loadState + posts + hasMore。
@MainActor
final class MomentTabViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle, loading, loaded, error(String)
        var isLoading: Bool { if case .loading = self { return true } else { return false } }
    }

    @Published private(set) var posts: [MomentPost] = []
    @Published private(set) var currentPage: Int = 0
    @Published private(set) var hasMore: Bool = true
    @Published private(set) var loadState: LoadState = .idle

    private let pageSize: Int

    init(pageSize: Int = 20) {
        self.pageSize = pageSize
    }

    /// 首页拉取（覆盖）。tab 显示且未加载时调，或下拉刷新时调。
    func loadFirstPage() async {
        await load(reset: true)
    }

    /// 下一页（追加）
    func loadNextPage() async {
        guard hasMore else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        if loadState.isLoading { return }
        guard let userId = SessionStore.shared.user?.userId else {
            loadState = .error("Not logged in")
            return
        }

        let nextPage = reset ? 1 : currentPage + 1
        loadState = .loading

        do {
            let page = try await MomentService.getMyMoments(
                userId: userId, pageSize: pageSize, currentPage: nextPage
            )
            if reset {
                posts = page.posts
            } else {
                posts.append(contentsOf: page.posts)
            }
            currentPage = nextPage
            hasMore = page.hasMore
            loadState = .loaded
        } catch let e as APIError {
            loadState = .error(e.message)
            logger.error("loadMoments APIError code=\(e.code): \(e.message)")
        } catch {
            loadState = .error(error.localizedDescription)
            logger.error("loadMoments error: \(String(describing: error))")
        }
    }
}
