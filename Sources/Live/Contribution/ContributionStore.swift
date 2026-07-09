import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "ContributionStore")

/// Contribution sheet 状态机（对齐 H5 liveContributionPop.vue 双 Tab + 分页）
@MainActor
final class ContributionStore: ObservableObject {
    enum RankState: Equatable {
        case idle
        case loading
        case loaded(ContributionRankPage)
        case error(String)
    }

    enum RecordState: Equatable {
        case idle
        case loading                    // 首次加载
        case loaded([GiftRecord], hasMore: Bool, nextPage: Int)
        case loadingMore([GiftRecord], nextPage: Int)  // 上拉分页中
        case error(String)
    }

    @Published private(set) var rankState: RankState = .idle
    @Published private(set) var recordState: RecordState = .idle
    @Published var selectedTab: ContributionTab = .ranking

    private let service: ContributionServiceProtocol
    private let anchorId: String
    private let roomId: String
    private let pageSize: Int = 20

    init(service: ContributionServiceProtocol = ContributionServiceFakes(),
         anchorId: String, roomId: String) {
        self.service = service
        self.anchorId = anchorId
        self.roomId = roomId
    }

    /// Sheet 打开时调用；两 tab 并行首次拉取
    func onSheetAppear() {
        if rankState == .idle { Task { await loadRank() } }
        if recordState == .idle { Task { await loadRecordsFirstPage() } }
    }

    /// 拉取贡献榜
    private func loadRank() async {
        rankState = .loading
        do {
            let page = try await service.fetchRank(anchorId: anchorId, roomId: roomId)
            rankState = .loaded(page)
        } catch {
            logger.warning("Contribution fetchRank failed: \(String(describing: error), privacy: .private)")
            rankState = .error(String(describing: error))
        }
    }

    /// 拉取第一页礼物记录
    private func loadRecordsFirstPage() async {
        recordState = .loading
        do {
            let page = try await service.fetchGiftRecords(anchorId: anchorId, roomId: roomId,
                                                          page: 1, size: pageSize)
            recordState = .loaded(page.records, hasMore: page.hasMore, nextPage: page.nextPage)
        } catch {
            logger.warning("Contribution fetchRecords failed: \(String(describing: error), privacy: .private)")
            recordState = .error(String(describing: error))
        }
    }

    /// 上拉加载更多礼物记录
    func loadMoreRecordsIfNeeded() {
        guard case .loaded(let existing, let hasMore, let nextPage) = recordState, hasMore else { return }
        Task {
            recordState = .loadingMore(existing, nextPage: nextPage)
            do {
                let page = try await service.fetchGiftRecords(anchorId: anchorId, roomId: roomId,
                                                              page: nextPage, size: pageSize)
                recordState = .loaded(existing + page.records, hasMore: page.hasMore, nextPage: page.nextPage)
            } catch {
                logger.warning("Contribution loadMore failed: \(String(describing: error), privacy: .private)")
                // 保持已有 records，仅回退 loading state
                recordState = .loaded(existing, hasMore: hasMore, nextPage: nextPage)
            }
        }
    }

    /// error 态重试
    func retryRank() { Task { await loadRank() } }
    func retryRecords() { Task { await loadRecordsFirstPage() } }
}
