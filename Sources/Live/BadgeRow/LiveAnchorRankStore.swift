import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveAnchorRank")

/// 主播顶部 Rank 徽章 store（对齐 H5 `liveRoomTopAnchorRank.vue`）
///
/// **数据源**：`receiveRankV3` API 返回 `currentAnchorRank`
/// **触发**：进房时一次拉取（H5 无定时轮询）
@MainActor
final class LiveAnchorRankStore: ObservableObject {
    /// 当前 rank 位次（nil = 未加载 / -1 = 无效值 / >0 = 排名）
    @Published private(set) var currentRank: Int?

    /// 显示文案（对齐 H5 逻辑）：
    /// - 1-100 → "No.X"
    /// - >100 → "100+"
    /// - -1 → "99+"（H5 兼容值）
    /// - nil → "--"
    var displayText: String {
        guard let rank = currentRank else { return "--" }
        if rank == -1 { return "99+" }
        if rank > 100 { return "100+" }
        if rank <= 0 { return "--" }
        return "No.\(rank)"
    }

    /// v13 复用 RankService（Fakes 或 Real），避免硬编码 15
    private var service: RankServiceProtocol = RankServiceReal()

    /// 进房初始化拉取（对齐 H5 onMounted → apiReceiveRank({anchorUserId, rankType:'week'}) → currentAnchorRank）
    func loadInitial() {
        Task { await load() }
    }

    /// v14 外部（如 RankSheetView load 完成后）用最新 rank 回填顶部徽章
    ///
    /// **对齐 H5**：H5 主播端 rank 徽章无推送机制（收 IM 不重拉），本方法用于"打开排行榜后同步顶部数字"场景
    func setRank(_ rank: Int?) {
        guard rank != currentRank else { return }
        currentRank = rank
        logger.info("AnchorRank set to: \(self.displayText, privacy: .public)")
    }

    private func load() async {
        // 对齐 H5 liveRoomTopAnchorRank.vue：apiReceiveRank({anchorUserId, rankType:'week'}) → res.currentAnchorRank
        guard let uid = SessionStore.shared.user?.userId else {
            logger.warning("AnchorRank load skipped: no session userId")
            return
        }
        do {
            let page = try await service.fetchWeekRank(period: .week, anchorUserId: String(uid))
            currentRank = page.anchorOwnRank
            logger.info("AnchorRank loaded from service: \(self.displayText, privacy: .public)")
        } catch {
            logger.error("AnchorRank load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
