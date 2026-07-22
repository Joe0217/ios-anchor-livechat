import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveTopRank")

/// 顶部右侧送礼榜 Top 2 单条（对齐 H5 `liveStore.topRankList[]`）
struct TopRankItem: Identifiable, Equatable {
    var id: String { userId }
    let userId: String
    let avatarUrl: String?
    let cost: Int64      // 贡献金额（用于排序 + `cost > 1` 过滤）
    let rank: Int        // 1-based rank（1 或 2）
}

/// v16 顶部右侧 Top2 送礼头像 store（对齐 H5 liveRoomTop.vue L221）
///
/// **v16 根治**：H5 主播端 `topRankList` 完全依赖 IM attachType 50/56 消息（**无初始 API**），
/// 若后端未广播 IM → Top2 永不显示。iOS 侧改为主动调 `apiSendRank(rankType='now', dbId=roomId)`
/// 拉本次直播送礼榜前 2，避免依赖 IM 消息广播的**时机不确定性**。
///
/// **数据源三重兜底**：
/// 1. **进房 loadInitial** → 调 apiSendRank 拉初始 Top2（进房瞬间即显示）
/// 2. **IM attachType 50/56 到达且不带完整 msg[]** → NIMChatroomManager 触发 refresh() 兜底
/// 3. **收 attachType 1 sendGift** → 同样触发 refresh()（H5 handleLiveGiftMessage 逻辑）
///
/// **规则**（对齐 H5 slice(0, 2) + UI 的 cost > 1 门禁）：
/// - 只保留 Top 2
/// - 首名 cost <= 1 时由 View 隐藏整个 Top2 区域
/// - 收到空榜必须清空，避免已离场用户遗留在顶部
@MainActor
final class LiveTopRankStore: ObservableObject {
    @Published private(set) var items: [TopRankItem] = []

    private let service: SendRankServiceProtocol
    /// 直播间 dbId（apiSendRank 需要）—— setRoomId 后才能真正调 API
    private var dbId: Int?
    /// IM 全量榜单和房间切换都会推进版本，避免较晚返回的 API 覆盖权威 IM 数据。
    private var dataGeneration = 0
    /// 同一 generation 内也只接受最新一次 API 刷新的结果。
    private var latestRefreshID = 0

    init(service: SendRankServiceProtocol = SendRankServiceReal()) {
        self.service = service
    }

    /// 直播间 id 注入（LiveRoomView.onAppear 从 roomInfo.id 传入）
    /// v22：roomId 变化时清空 stale 数据（新场次不带前一场 Top2 残留）
    func setRoomId(_ id: Int?) {
        if dbId != id {
            items = []
            dataGeneration &+= 1
        }
        dbId = id
    }

    /// 进房初始化拉取
    func loadInitial() {
        Task { await refresh() }
    }

    /// v16 从 apiSendRank 主动拉本次直播送礼榜前 2
    ///
    /// **兜底策略**：
    /// - dbId 未设置或为 0 → 保持 items 为空（尚未开播完成）
    /// - API 失败 → 保持现有 items 不变（避免闪空态）
    func refresh() async {
        guard let roomID = dbId, roomID > 0 else {
            logger.debug("TopRank refresh skipped: dbId not set")
            return
        }
        latestRefreshID &+= 1
        let refreshID = latestRefreshID
        let generation = dataGeneration
        do {
            let list = try await service.fetchSendRank(rankType: .now, dbId: roomID)
            guard refreshID == latestRefreshID,
                  generation == dataGeneration,
                  dbId == roomID else {
                logger.debug("TopRank refresh discarded: superseded by newer room/rank data")
                return
            }
            // H5 updateTopList 直接 slice(0, 2)。cost 门禁属于 UI，而非 store 过滤规则。
            let top2 = list.prefix(2).enumerated().map { (idx, entry) in
                TopRankItem(userId: entry.userId, avatarUrl: entry.avatarUrl,
                            cost: entry.costNum, rank: idx + 1)
            }
            items = top2
            logger.info("TopRank refreshed from apiSendRank: \(self.items.count) items")
        } catch {
            logger.error("TopRank refresh failed: \(String(describing: error), privacy: .public)")
            // 保持现有 items，不清空（避免 API 抖动导致 UI 闪烁）
        }
    }

    /// v12 兼容入口：IM attachType 50/56 收到 msg[] 时直接全量替换（保留供 NIM 侧调用）
    ///
    /// **对齐 H5 setFromRankList**：msg[] 是完整送礼榜，slice(0, 2) 截前 2；非累加语义
    func setFromRankList(_ rankList: [[String: Any]]) {
        dataGeneration &+= 1
        var parsed: [TopRankItem] = []
        for (idx, entry) in rankList.prefix(2).enumerated() {
            guard let userId = LiveRankValueParser.string(entry["userId"]) else { continue }

            let icon = LiveRankValueParser.string(entry["icon"] ?? entry["avatar"])
            let cost = max(0, LiveRankValueParser.int64(entry["cost"] ?? entry["costNum"]) ?? 0)

            parsed.append(TopRankItem(userId: userId, avatarUrl: icon, cost: cost, rank: idx + 1))
        }
        items = parsed
        logger.info("TopRank setFromRankList: \(self.items.count) items")
    }

    /// logout / 离房清理
    func clear() {
        items = []
        dbId = nil
        dataGeneration &+= 1
    }
}
