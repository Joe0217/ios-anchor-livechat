import Foundation

/// Contribution 数据源 protocol（H 里程碑接入真 API 时 replace Fakes → Real）
///
/// **真 API 契约**（对齐 H5 liveContributionPop.vue store 调用点）：
/// - 贡献榜: POST `/api/live/send/rank/contributionRank`  body: `{ anchorId, roomId }`
/// - 礼物记录: POST `/api/gift/getThisLiveSendGiftRecord`  body: `{ anchorId, roomId, currentPage, pageSize }`
/// - 加密: AES-128-CBC + Hex（走 APIClient 主链路自动处理）
protocol ContributionServiceProtocol {
    func fetchRank(anchorId: String, roomId: String) async throws -> ContributionRankPage
    func fetchGiftRecords(anchorId: String, roomId: String,
                          page: Int, size: Int) async throws -> GiftRecordPage
}

/// Fakes 实现（Level B 视觉走通用）
struct ContributionServiceFakes: ContributionServiceProtocol {
    private static let rankNames: [String] = [
        "Alice", "Bob", "Charlie", "David", "Emma",
        "Frank", "Grace", "Henry", "Ivy", "Jack",
        "Kevin", "Lily", "Mike", "Nancy", "Oscar"
    ]
    private static let recordNames: [String] = [
        "Alice", "Bob", "Charlie", "David", "Emma",
        "Frank", "Grace", "Henry", "Ivy", "Jack"
    ]
    private static let giftNames: [String] = ["Rose", "Star", "Diamond", "Rocket", "Crown"]
    private static let diamondEachTable: [Int64] = [100, 500, 2000, 5000, 50000]

    func fetchRank(anchorId: String, roomId: String) async throws -> ContributionRankPage {
        try await Task.sleep(nanoseconds: 300_000_000)
        var entries: [ContributionEntry] = []
        entries.reserveCapacity(15)
        for i in 1...15 {
            entries.append(ContributionEntry(
                id: "u\(i)",
                rank: i,
                userId: "user\(i)",
                nickname: Self.rankNames[i - 1],
                avatarUrl: nil,
                level: 25 - i,
                thisLiveDiamond: Int64((20 - i) * 500),
                last90DaysDiamond: Int64((20 - i) * 8000)
            ))
        }
        return ContributionRankPage(entries: entries,
                                    totalIncome: entries.map(\.thisLiveDiamond).reduce(0, +))
    }

    func fetchGiftRecords(anchorId: String, roomId: String,
                          page: Int, size: Int) async throws -> GiftRecordPage {
        try await Task.sleep(nanoseconds: 300_000_000)
        // 模拟分页：第 1 页 20 条，第 2 页 10 条，第 3 页起为空
        guard page <= 2 else {
            return GiftRecordPage(records: [], hasMore: false, nextPage: page)
        }
        let count = page == 1 ? 20 : 10
        let startIndex = (page - 1) * 20
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var records: [GiftRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let idx = startIndex + i
            let giftIndex = idx % 5
            records.append(GiftRecord(
                id: "g\(idx)",
                time: now - Int64(idx * 30_000),
                userId: "user\(idx % 10 + 1)",
                userNickname: Self.recordNames[idx % 10],
                userAvatarUrl: nil,
                giftName: Self.giftNames[giftIndex],
                giftIconUrl: nil,
                quantity: (idx % 3) + 1,
                diamondEach: Self.diamondEachTable[giftIndex]
            ))
        }
        return GiftRecordPage(records: records, hasMore: page < 2, nextPage: page + 1)
    }
}

/// 真 API 实现（H 里程碑接入）
///
/// TODO H 里程碑：
/// ```
/// // fetchRank
/// let body: [String: Any] = ["anchorId": anchorId, "roomId": roomId]
/// let resp: ContributionRankResponse = try await APIClient.shared.post(
///     "/api/live/send/rank/contributionRank", body: body)
/// // fetchGiftRecords
/// let body2: [String: Any] = ["anchorId": anchorId, "roomId": roomId,
///                              "currentPage": page, "pageSize": size]
/// let resp2: GiftRecordResponse = try await APIClient.shared.post(
///     "/api/gift/getThisLiveSendGiftRecord", body: body2)
/// ```
struct ContributionServiceReal: ContributionServiceProtocol {
    func fetchRank(anchorId: String, roomId: String) async throws -> ContributionRankPage {
        // TODO H 里程碑
        return try await ContributionServiceFakes().fetchRank(anchorId: anchorId, roomId: roomId)
    }

    func fetchGiftRecords(anchorId: String, roomId: String,
                          page: Int, size: Int) async throws -> GiftRecordPage {
        // TODO H 里程碑
        return try await ContributionServiceFakes().fetchGiftRecords(
            anchorId: anchorId, roomId: roomId, page: page, size: size)
    }
}
