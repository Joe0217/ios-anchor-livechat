import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PKRankStore")

/// PK 贡献榜 sheet 状态机（对齐 H5 pkRankListPopup.vue L45-73 `fetchRankList`）。
///
/// H5 单请求单列表模型：
/// - popup 打开 → `fetchRankList` (getPkRankListApi body: {pkId, anchorId})
/// - loading spinner / rankList 数组 / 错误 toast
/// - 无分页、无 tab 切换（比 ContributionStore 更简单）
@MainActor
final class PKRankStore: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded([PKRankItem])
        case error(String)
    }

    @Published private(set) var state: State = .idle

    private let pkId: String
    private let anchorId: Int
    private var didLoadOnce = false

    init(pkId: String, anchorId: Int) {
        self.pkId = pkId
        self.anchorId = anchorId
    }

    /// sheet 出现时拉一次；重复触发跳过（已 loaded/loading）。
    func onAppear() {
        guard !didLoadOnce, case .idle = state else { return }
        didLoadOnce = true
        Task { await load() }
    }

    func retry() {
        Task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            let items = try await PKService.getPkRankList(pkId: pkId, anchorId: anchorId)
            state = .loaded(items)
        } catch {
            logger.warning("getPkRankList failed pkId=\(self.pkId, privacy: .private) anchorId=\(self.anchorId): \(String(describing: error), privacy: .private)")
            state = .error(String(describing: error))
        }
    }
}
