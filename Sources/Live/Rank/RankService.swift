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
        var anchorRank: Int?
        if let v = dict["currentAnchorRank"] as? Int { anchorRank = v }
        else if let v = dict["currentAnchorRank"] as? Int64 { anchorRank = Int(v) }
        else if let v = dict["currentAnchorRank"] as? NSNumber { anchorRank = v.intValue }

        // 底部悬浮条 diffNum（对齐 H5 girlWeeklyRank.vue 距上一名差值）
        var diff: Int64?
        if let v = dict["diffNum"] as? Int64 { diff = v }
        else if let v = dict["diffNum"] as? Int { diff = Int64(v) }
        else if let v = dict["diffNum"] as? NSNumber { diff = v.int64Value }

        // 榜单列表（H5 anchorReceiveRankList[]）
        var entries: [RankEntry] = []
        if let list = dict["anchorReceiveRankList"] as? [[String: Any]] {
            for (idx, item) in list.enumerated() {
                let uid: String = {
                    if let s = item["userId"] as? String { return s }
                    if let n = item["userId"] as? Int64 { return String(n) }
                    if let n = item["userId"] as? Int { return String(n) }
                    if let n = item["userId"] as? NSNumber { return n.stringValue }
                    return ""
                }()
                guard !uid.isEmpty else { continue }
                var diamond: Int64 = 0
                if let v = item["costNum"] as? Int64 { diamond = v }
                else if let v = item["costNum"] as? Int { diamond = Int64(v) }
                else if let v = item["costNum"] as? NSNumber { diamond = v.int64Value }
                let level = (item["userLevel"] as? Int) ?? (item["level"] as? Int) ?? 0
                let nick = (item["nickname"] as? String) ?? (item["nickName"] as? String) ?? ""
                let icon = item["icon"] as? String ?? item["headImg"] as? String
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
            anchorNickname: (dict["nickname"] as? String) ?? "",
            anchorAvatarUrl: dict["icon"] as? String
        )
    }
}
