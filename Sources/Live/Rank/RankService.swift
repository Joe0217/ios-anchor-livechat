import Foundation

/// Rank 数据源 protocol（H 里程碑接入真 API 时 replace Fakes → Real）。
///
/// **真 API 契约**（对齐 H5 `receiveRankV3.js` + `.claude/rules/api-http-method-strict.md`）：
/// - method: **POST**
/// - path: `/api/live/send/rank/receiveRankV3`
/// - body: `{ anchorUserId: String, rankType: String("week"|"lastWeek") }`
/// - 加密: AES-128-CBC + Hex（走 APIClient 主链路自动处理）
protocol RankServiceProtocol {
    func fetchWeekRank(period: RankPeriod, anchorUserId: String) async throws -> RankListPage
}

/// Fakes 实现（本轮 Level B 视觉走通用）
struct RankServiceFakes: RankServiceProtocol {
    private static let mockNames: [String] = [
        "Alice", "Bob", "Charlie", "David", "Emma",
        "Frank", "Grace", "Henry", "Ivy", "Jack"
    ]

    func fetchWeekRank(period: RankPeriod, anchorUserId: String) async throws -> RankListPage {
        // 模拟异步延迟 300ms（让 loading 态可见）
        try await Task.sleep(nanoseconds: 300_000_000)

        let base = period == .week ? Int64(1000) : Int64(800)
        var entries: [RankEntry] = []
        entries.reserveCapacity(10)
        for i in 1...10 {
            entries.append(RankEntry(
                id: "u\(i)",
                rank: i,
                userId: "user\(i)",
                nickname: Self.mockNames[i - 1],
                avatarUrl: nil,
                level: 20 - i,
                diamond: base * Int64(11 - i)
            ))
        }
        return RankListPage(
            entries: entries,
            anchorOwnRank: 6,           // v13: 15 → 6 对齐用户明示的真实排名（H 期接真 API 时废弃 Fakes）
            diffToPrevious: 200,
            anchorIncome: 5_000,
            anchorNickname: "Me",
            anchorAvatarUrl: nil
        )
    }
}

/// v14 真 API 实现（对齐 H5 `apiReceiveRank`，src/api/live/index.ts:33）
///
/// - method: POST
/// - path: `/api/live/send/rank/receiveRankV3`
/// - body: `{ anchorUserId: String, rankType: 'week' | 'lastWeek' }`
/// - response 顶层字段：`currentAnchorRank` / `anchorReceiveRankList[]` / `costNum` / `diffNum`
///
/// H5 组件 liveRoomTopAnchorRank.vue 只读 `res?.currentAnchorRank`；girlWeeklyRank.vue 读整体 list
struct RankServiceReal: RankServiceProtocol {
    func fetchWeekRank(period: RankPeriod, anchorUserId: String) async throws -> RankListPage {
        let body: [String: Any] = [
            "anchorUserId": anchorUserId,
            "rankType": period.rawValue    // "week" / "lastWeek"
        ]
        let data = try await APIClient.shared.post("/api/live/send/rank/receiveRankV3", body: body)
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        // 顶部 rank 徽章依赖字段（组件 liveRoomTopAnchorRank.vue L22 res.currentAnchorRank）
        let anchorRank = LiveRankValueParser.int(dict["currentAnchorRank"])

        // 底部悬浮条 diffNum（对齐 H5 girlWeeklyRank.vue 距上一名差值）
        let diff = LiveRankValueParser.int64(dict["diffNum"])
        let anchorIncome = max(0, LiveRankValueParser.int64(dict["costNum"]) ?? 0)

        // 榜单列表（H5 anchorReceiveRankList[]）
        var entries: [RankEntry] = []
        if let list = dict["anchorReceiveRankList"] as? [[String: Any]] {
            for (idx, item) in list.enumerated() {
                guard let uid = LiveRankValueParser.string(item["userId"]) else { continue }
                let diamond = max(0, LiveRankValueParser.int64(item["costNum"]) ?? 0)
                let level = max(0, LiveRankValueParser.int(item["userLevel"] ?? item["level"]) ?? 0)
                let nick = LiveRankValueParser.string(item["nickname"] ?? item["nickName"]) ?? ""
                let icon = LiveRankValueParser.string(item["icon"] ?? item["headImg"])
                entries.append(RankEntry(
                    id: uid, rank: idx + 1, userId: uid, nickname: nick,
                    avatarUrl: icon, level: level, diamond: diamond
                ))
            }
        }

        return RankListPage(
            entries: entries,
            anchorOwnRank: anchorRank,
            diffToPrevious: diff,
            anchorIncome: anchorIncome,
            anchorNickname: LiveRankValueParser.string(dict["nickname"]) ?? "",
            anchorAvatarUrl: LiveRankValueParser.string(dict["icon"])
        )
    }
}
