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
                isVip: i <= 2,
                countryId: i == 1 ? "US" : nil,
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
                diamondEach: Self.diamondEachTable[giftIndex],
                formattedTime: nil
            ))
        }
        return GiftRecordPage(records: records, hasMore: page < 2, nextPage: page + 1)
    }
}

/// H5 同源真 API 实现。接口数字字段会混发 JSON number 与 string，统一宽松解析。
struct ContributionServiceReal: ContributionServiceProtocol {
    func fetchRank(anchorId: String, roomId: String) async throws -> ContributionRankPage {
        let data = try await APIClient.shared.post(
            "/api/live/send/rank/contributionRank",
            body: ["anchorId": anchorId, "roomId": roomId]
        )
        let raw = try JSONSerialization.jsonObject(with: data)
        let entries = Self.extractList(from: raw).enumerated().compactMap { index, value -> ContributionEntry? in
            guard let item = value as? [String: Any],
                  let userId = Self.string(item["userId"] ?? item["id"]), !userId.isEmpty else { return nil }
            return ContributionEntry(
                id: userId,
                rank: max(1, Self.int(item["rank"]) ?? (index + 1)),
                userId: userId,
                nickname: Self.string(item["nickname"] ?? item["nickName"]) ?? "",
                avatarUrl: Self.string(item["avatar"] ?? item["icon"]),
                level: max(0, Self.int(item["level"]) ?? 0),
                isVip: Self.bool(item["isVip"] ?? item["vipFlag"]) ?? false,
                countryId: Self.string(item["countryId"]),
                thisLiveDiamond: max(0, Self.int64(item["income"] ?? item["thisLiveDiamond"]) ?? 0),
                last90DaysDiamond: max(0, Self.int64(item["totalDiamond"] ?? item["last90DaysDiamond"]) ?? 0)
            )
        }
        return ContributionRankPage(entries: entries, totalIncome: entries.reduce(0) { $0 + $1.thisLiveDiamond })
    }

    func fetchGiftRecords(anchorId: String, roomId: String,
                          page: Int, size: Int) async throws -> GiftRecordPage {
        let data = try await APIClient.shared.post(
            "/api/gift/getThisLiveSendGiftRecord",
            body: [
                "anchorId": anchorId,
                "roomId": roomId,
                "currentPage": page,
                "pageSize": size
            ]
        )
        let raw = try JSONSerialization.jsonObject(with: data)
        let records = Self.extractList(from: raw).enumerated().compactMap { index, value -> GiftRecord? in
            guard let item = value as? [String: Any] else { return nil }
            return GiftRecord(
                id: Self.string(item["id"] ?? item["recordId"]) ?? "p\(page)r\(index)",
                time: max(0, Self.int64(item["time"] ?? item["createTime"] ?? item["timestamp"]) ?? 0),
                userId: Self.string(item["userId"] ?? item["sendUserId"]) ?? "",
                userNickname: Self.string(item["nickname"] ?? item["nickName"]) ?? "",
                userAvatarUrl: Self.string(item["avatar"] ?? item["icon"]),
                giftName: Self.string(item["giftName"] ?? item["name"]) ?? "",
                giftIconUrl: Self.string(item["giftImg"] ?? item["giftSmallImg"] ?? item["giftIcon"]),
                quantity: max(0, Self.int(item["giftCount"] ?? item["giftNum"] ?? item["count"]) ?? 0),
                diamondEach: max(0, Self.int64(item["giftPrice"] ?? item["diamondEach"]) ?? 0),
                formattedTime: Self.string(item["formattedTime"])
            )
        }
        return GiftRecordPage(records: records, hasMore: records.count >= size && size > 0, nextPage: page + 1)
    }

    private static func extractList(from raw: Any) -> [Any] {
        if let list = raw as? [Any] { return list }
        guard let object = raw as? [String: Any] else { return [] }
        for key in ["result", "records", "list", "data"] {
            if let value = object[key] {
                let list = extractList(from: value)
                if !list.isEmpty || value is [Any] { return list }
            }
        }
        return []
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = int64(value) { return String(value) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value = int64(value) else { return nil }
        return Int(clamping: value)
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            guard type != "c", type != "B" else { return nil }
            return value.int64Value
        }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            return type == "c" || type == "B" ? value.boolValue : value.intValue != 0
        }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
