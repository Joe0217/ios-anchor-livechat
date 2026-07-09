import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "RankStore")

/// Rank sheet 状态机（对齐 H5 girlWeeklyRank.vue 双 Tab 各自加载）
@MainActor
final class RankStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(RankListPage)
        case error(String)
    }

    @Published private(set) var weekState: LoadState = .idle
    @Published private(set) var lastWeekState: LoadState = .idle
    /// 当前选中 tab（默认 .week）
    @Published var selectedPeriod: RankPeriod = .week

    private let service: RankServiceProtocol
    private let anchorUserId: String

    init(service: RankServiceProtocol = RankServiceReal(),   // v14 默认走真 API（H5 apiReceiveRank）
         anchorUserId: String) {
        self.service = service
        self.anchorUserId = anchorUserId
    }

    /// 进入 tab 时加载对应周期数据（幂等，已 loaded 不重新拉）
    func loadIfNeeded(period: RankPeriod) {
        let currentState: LoadState = (period == .week) ? weekState : lastWeekState
        guard currentState == .idle else { return }
        Task { await load(period: period) }
    }

    /// 强制刷新（error 态重试用；从空态触发，会走 loading）
    func reload(period: RankPeriod) {
        Task { await load(period: period) }
    }

    /// v14 SwiftUI `.refreshable` 专用同步 async 入口（下拉刷新等待完成态）
    ///
    /// **v17 修复**：下拉刷新时**保留旧 loaded 数据**，只在拉到新数据后原地替换，避免"闪空态 → 重新出现"的观感抖动。
    /// 与 load(period:) 走 setState(.loading) 清空旧数据不同：refresh 只在 fetch 完成后 setState(.loaded(new))。
    func refresh(period: RankPeriod) async {
        do {
            let page = try await service.fetchWeekRank(period: period,
                                                       anchorUserId: anchorUserId)
            setState(period, .loaded(page))
        } catch {
            logger.warning("RankStore refresh failed period=\(period.rawValue, privacy: .public) error=\(String(describing: error), privacy: .private)")
            // v17：refresh 失败不切 error 态，保留旧 loaded 数据（用户下拉刷新失败仍能看到旧数据）
        }
    }

    /// v14 从 loaded 状态取当前周期的主播 anchorOwnRank（供 sheet onAppear 回填顶部徽章）
    func currentAnchorRank(period: RankPeriod) -> Int? {
        let state: LoadState = (period == .week) ? weekState : lastWeekState
        if case .loaded(let page) = state { return page.anchorOwnRank }
        return nil
    }

    private func load(period: RankPeriod) async {
        setState(period, .loading)
        do {
            let page = try await service.fetchWeekRank(period: period,
                                                       anchorUserId: anchorUserId)
            setState(period, .loaded(page))
        } catch {
            logger.warning("RankStore fetch failed period=\(period.rawValue, privacy: .public) error=\(String(describing: error), privacy: .private)")
            setState(period, .error(String(describing: error)))
        }
    }

    private func setState(_ period: RankPeriod, _ state: LoadState) {
        if period == .week { weekState = state } else { lastWeekState = state }
    }
}
