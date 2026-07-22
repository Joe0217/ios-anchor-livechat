import Foundation

/// Phase E —— 积分排行榜 Store。对齐 Task Phase C 建立的静默错误保留 previous pattern。
///
/// 状态机与 [LiveDataStore.State](../LiveData/LiveDataStore.swift) 同款 4 态。失败保留 previous;
/// 首次失败保持 skeleton(H5 无 error UI,用户下拉刷新触发 retry)。
@MainActor
final class PointsRankStore: ObservableObject {

    enum LoadState {
        case idle
        case loading(previous: PointsRankListResponse?)
        case loaded(PointsRankListResponse)
        case error(String, previous: PointsRankListResponse?)

        var currentPayload: PointsRankListResponse? {
            switch self {
            case .idle: return nil
            case .loading(let p): return p
            case .loaded(let r): return r
            case .error(_, let p): return p
            }
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    @Published private(set) var state: LoadState = .idle

    /// Top3 派生 —— H5 顺序:`[items[1], items[0], items[2]]` 即 [2nd, 1st, 3rd] 居中放 1 位
    var topThree: [PointsRankItemVO?] {
        guard let payload = state.currentPayload else { return [nil, nil, nil] }
        let items = payload.items
        return [
            items.count > 1 ? items[1] : nil,   // 2nd
            items.count > 0 ? items[0] : nil,   // 1st (居中)
            items.count > 2 ? items[2] : nil    // 3rd
        ]
    }

    /// 4 名起(items.dropFirst(3))
    var restList: [PointsRankItemVO] {
        guard let payload = state.currentPayload, payload.items.count > 3 else { return [] }
        return Array(payload.items.dropFirst(3))
    }

    /// 我方积分(顶部 pill 显示)
    var myIntegral: Int {
        state.currentPayload?.myIntegral ?? 0
    }

    private let service: PointsRankServiceProtocol
    private var didAppear = false
    private var currentTask: Task<Void, Never>?

    init(service: PointsRankServiceProtocol = PointsRankService.shared) {
        self.service = service
    }

    /// 页面首次出现拉数据;避免重复
    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        Task { await loadRank() }
    }

    /// 下拉刷新:async 让 refreshable 等待任务完成才收 spinner
    /// (对齐 [list-refresh-preserve-items](.claude/rules/list-refresh-preserve-items.md) §B)
    func refresh() async {
        await loadRank()
    }

    private func loadRank() async {
        currentTask?.cancel()

        // 保留 previous(list-refresh-preserve-items rule)
        let previous: PointsRankListResponse?
        switch state {
        case .loaded(let r): previous = r
        case .loading(let p), .error(_, let p): previous = p
        case .idle: previous = nil
        }
        state = .loading(previous: previous)

        let t = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.fetchWeeklyRank()
                if Task.isCancelled { return }
                self.state = .loaded(result)
            } catch {
                if Task.isCancelled { return }
                AppLogger.net.error("[PointsRank] load failed: \(String(describing: error), privacy: .public)")
                // 静默错误保留 previous(对齐 Task Phase C 建立的 pattern)
                let msg = (error as? APIError)?.message ?? L10n.commonNetworkError
                self.state = .error(msg, previous: previous)
            }
        }
        currentTask = t
        await t.value
    }
}
