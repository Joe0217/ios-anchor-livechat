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
/// 2. **IM attachType 50/56 到达** → NIMChatroomManager 触发 refresh() 再拉一次（对齐 H5 事件驱动）
/// 3. **收 attachType 1 sendGift** → 同样触发 refresh()（H5 handleLiveGiftMessage 逻辑）
///
/// **规则**（对齐 H5 slice(0, 2) + cost > 1 过滤）：
/// - 只保留 Top 2
/// - 无贡献用户（cost <= 1）过滤掉
///
/// **v22 加固**（用户反馈"Top2 随用户离开而消失"）：
/// 采用"只覆盖、不清空"语义 —— 后端 rankList 抖动（用户离开导致列表变短 / 空）
/// 时保留现有 items，只在收到含 cost>1 的新有效榜单时才替换。场次切换由
/// `setRoomId(_:)` 检测 dbId 变化时主动清空。
@MainActor
final class LiveTopRankStore: ObservableObject {
    @Published private(set) var items: [TopRankItem] = []

    private let service: SendRankServiceProtocol
    /// 直播间 dbId（apiSendRank 需要）—— setRoomId 后才能真正调 API
    private var dbId: Int?

    init(service: SendRankServiceProtocol = SendRankServiceReal()) {
        self.service = service
    }

    /// 直播间 id 注入（LiveRoomView.onAppear 从 roomInfo.id 传入）
    /// v22：roomId 变化时清空 stale 数据（新场次不带前一场 Top2 残留）
    func setRoomId(_ id: Int?) {
        if dbId != id {
            items = []
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
        guard let dbId, dbId > 0 else {
            logger.debug("TopRank refresh skipped: dbId not set")
            return
        }
        do {
            let list = try await service.fetchSendRank(rankType: .now, dbId: dbId)
            // slice(0, 2) + cost > 1 过滤（对齐 H5 语义）
            let top2 = list.prefix(2).enumerated().compactMap { (idx, entry) -> TopRankItem? in
                TopRankItem(userId: entry.userId, avatarUrl: entry.avatarUrl,
                            cost: entry.costNum, rank: idx + 1)
            }
            // v22 修：Top2 一旦拿到有效数据就固定展示，实时更新只覆盖不清空
            // ——空 list / first.cost<=1（表明后端本次没有有效榜单，多因某 Top 用户离开引发的 rankList 抖动）
            // 保持现有 items 不动，避免"用户离开导致头像消失"的产品反馈
            guard let first = top2.first, first.cost > 1 else {
                logger.info("TopRank refresh kept: incoming empty/invalid (current items=\(self.items.count) retained)")
                return
            }
            items = top2
            logger.info("TopRank refreshed from apiSendRank: \(self.items.count) items (first cost=\(self.items.first?.cost ?? 0))")
        } catch {
            logger.error("TopRank refresh failed: \(String(describing: error), privacy: .public)")
            // 保持现有 items，不清空（避免 API 抖动导致 UI 闪烁）
        }
    }

    /// v12 兼容入口：IM attachType 50/56 收到 msg[] 时直接全量替换（保留供 NIM 侧调用）
    ///
    /// **对齐 H5 setFromRankList**：msg[] 是完整送礼榜，slice(0, 2) 截前 2；非累加语义
    func setFromRankList(_ rankList: [[String: Any]]) {
        var parsed: [TopRankItem] = []
        for (idx, entry) in rankList.prefix(2).enumerated() {
            var uid: String?
            if let s = entry["userId"] as? String, !s.isEmpty { uid = s }
            else if let n = entry["userId"] as? Int64 { uid = String(n) }
            else if let n = entry["userId"] as? Int { uid = String(n) }
            else if let n = entry["userId"] as? NSNumber { uid = n.stringValue }
            guard let userId = uid else { continue }

            let icon = entry["icon"] as? String
            var cost: Int64 = 0
            if let c64 = entry["cost"] as? Int64 { cost = c64 }
            else if let c = entry["cost"] as? Int { cost = Int64(c) }
            else if let n = entry["cost"] as? NSNumber { cost = n.int64Value }

            parsed.append(TopRankItem(userId: userId, avatarUrl: icon, cost: cost, rank: idx + 1))
        }
        // v22 修：与 refresh() 一致 —— 空/first.cost<=1 保留现有 items（不因用户离开清空 Top2）
        guard let first = parsed.first, first.cost > 1 else {
            logger.info("TopRank setFromRankList kept: incoming empty/invalid (current items=\(self.items.count) retained)")
            return
        }
        items = parsed
        logger.info("TopRank setFromRankList: \(self.items.count) items (first cost=\(self.items.first?.cost ?? 0))")
    }

    /// logout / 离房清理
    func clear() {
        items = []
        dbId = nil
    }
}
