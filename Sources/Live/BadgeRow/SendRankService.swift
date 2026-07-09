import Foundation

/// v16 送礼榜 API 契约（对齐 H5 apiSendRank，src/api/live/index.ts:14）
///
/// - endpoint: `POST /api/live/send/rank/sendRank`
/// - body: `{ rankType: 'now' | 'today' | 'week', dbId: Int }`
/// - response: `[{userId, nickname, icon, userLevel, vipFlag, activeTycoon, costNum, rank}]`
///
/// **业务语义**：
/// - `rankType='now'` = 本次直播（当前小时）送礼排名 → **顶部右侧 Top2 头像的真数据源**
/// - `rankType='today'` = 今日送礼排名（跨场次累计）
/// - `rankType='week'` = 本周送礼排名（跨场次累计，Week Tab 头部有前 3 名大卡片）
///
/// **iOS 用法**：
/// - `LiveTopRankStore.refresh()` → `fetchSendRank(rankType:.now, dbId:roomId)` 拉 `list.prefix(2)` 更新 Top2
/// - `UserWeeklyRankSheetView` Top Gifter 内层 3 子 Tab → 各调一次
enum SendRankType: String, CaseIterable {
    case now
    case today
    case week
}

/// 送礼榜单条条目（response 元素结构）
struct SendRankEntry: Identifiable, Equatable {
    let id: String              // userId
    let userId: String
    let nickname: String
    let avatarUrl: String?
    let level: Int
    let isVip: Bool
    let isActiveTycoon: Bool
    let costNum: Int64          // 送礼贡献钻石数
    let rank: Int               // 服务端算好的排名（1-based）
}

protocol SendRankServiceProtocol {
    func fetchSendRank(rankType: SendRankType, dbId: Int) async throws -> [SendRankEntry]
}

/// v16 真 API 实现
struct SendRankServiceReal: SendRankServiceProtocol {
    func fetchSendRank(rankType: SendRankType, dbId: Int) async throws -> [SendRankEntry] {
        let body: [String: Any] = ["rankType": rankType.rawValue, "dbId": dbId]
        let data = try await APIClient.shared.post("/api/live/send/rank/sendRank", body: body)

        // response 直接是 [item] 数组或含在 result 里；APIClient 已解 result，此处 root 应就是 array
        // 兼容两种：array 直返 / dict.list 嵌套
        var rawList: [[String: Any]] = []
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rawList = arr
        } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = dict["list"] as? [[String: Any]] { rawList = arr }
        }

        return rawList.enumerated().compactMap { (idx, item) in
            // userId 多态兼容（Int / Int64 / NSNumber / String）
            let uid: String? = {
                if let s = item["userId"] as? String, !s.isEmpty { return s }
                if let n = item["userId"] as? Int64 { return String(n) }
                if let n = item["userId"] as? Int { return String(n) }
                if let n = item["userId"] as? NSNumber { return n.stringValue }
                return nil
            }()
            guard let userId = uid else { return nil }

            var cost: Int64 = 0
            if let v = item["costNum"] as? Int64 { cost = v }
            else if let v = item["costNum"] as? Int { cost = Int64(v) }
            else if let v = item["costNum"] as? NSNumber { cost = v.int64Value }

            let rank: Int = (item["rank"] as? Int)
                ?? ((item["rank"] as? NSNumber)?.intValue)
                ?? (idx + 1)

            return SendRankEntry(
                id: userId,
                userId: userId,
                nickname: (item["nickname"] as? String) ?? (item["nickName"] as? String) ?? "",
                avatarUrl: item["icon"] as? String,
                level: (item["userLevel"] as? Int) ?? (item["level"] as? Int) ?? 0,
                isVip: (item["vipFlag"] as? Bool) ?? false,
                isActiveTycoon: (item["activeTycoon"] as? Bool) ?? false,
                costNum: cost,
                rank: rank
            )
        }
    }
}

/// v16 Fakes（H 期或空态回退占位）
struct SendRankServiceFakes: SendRankServiceProtocol {
    func fetchSendRank(rankType: SendRankType, dbId: Int) async throws -> [SendRankEntry] {
        try await Task.sleep(nanoseconds: 200_000_000)
        // Fakes 数据：Now 空（未开播还没人送礼）；Today/Week 5 条 mock
        if rankType == .now { return [] }
        let base: Int64 = rankType == .week ? 20000 : 5000
        let names = ["Alice", "Bob", "Charlie", "David", "Emma"]
        var out: [SendRankEntry] = []
        for i in 1...5 {
            let entry = SendRankEntry(
                id: "u\(i)", userId: "u\(i)",
                nickname: names[i - 1],
                avatarUrl: nil,
                level: 30 - i * 3,
                isVip: i <= 2,
                isActiveTycoon: i == 1,
                costNum: base * Int64(6 - i),
                rank: i
            )
            out.append(entry)
        }
        return out
    }
}

/// v16 观众列表 API（对齐 H5 apiViewers，src/api/live/index.ts:35）
///
/// - endpoint: `POST /api/live/send/rank/viewers`
/// - body: `{ anchorUserId: Int }`
/// - response: `[{userId, nickname, icon, userLevel, vipFlag, activeTycoon, countryId}]`
struct ViewerEntry: Identifiable, Equatable {
    let id: String
    let userId: String
    let nickname: String
    let avatarUrl: String?
    let level: Int
    let isVip: Bool
    let isActiveTycoon: Bool
    let countryId: String?
}

protocol ViewersServiceProtocol {
    func fetchViewers(anchorUserId: Int) async throws -> [ViewerEntry]
}

struct ViewersServiceReal: ViewersServiceProtocol {
    func fetchViewers(anchorUserId: Int) async throws -> [ViewerEntry] {
        let body: [String: Any] = ["anchorUserId": anchorUserId]
        let data = try await APIClient.shared.post("/api/live/send/rank/viewers", body: body)

        var rawList: [[String: Any]] = []
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rawList = arr
        } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = dict["list"] as? [[String: Any]] {
            rawList = arr
        }

        return rawList.compactMap { item in
            let uid: String? = {
                if let s = item["userId"] as? String, !s.isEmpty { return s }
                if let n = item["userId"] as? Int64 { return String(n) }
                if let n = item["userId"] as? Int { return String(n) }
                if let n = item["userId"] as? NSNumber { return n.stringValue }
                return nil
            }()
            guard let userId = uid else { return nil }
            return ViewerEntry(
                id: userId,
                userId: userId,
                nickname: (item["nickname"] as? String) ?? (item["nickName"] as? String) ?? "",
                avatarUrl: item["icon"] as? String,
                level: (item["userLevel"] as? Int) ?? (item["level"] as? Int) ?? 0,
                isVip: (item["vipFlag"] as? Bool) ?? false,
                isActiveTycoon: (item["activeTycoon"] as? Bool) ?? false,
                countryId: item["countryId"] as? String
            )
        }
    }
}

struct ViewersServiceFakes: ViewersServiceProtocol {
    func fetchViewers(anchorUserId: Int) async throws -> [ViewerEntry] {
        try await Task.sleep(nanoseconds: 200_000_000)
        return (1...5).map { i in
            ViewerEntry(
                id: "v\(i)", userId: "v\(i)",
                nickname: ["Alice", "Bob", "Cathy", "David", "Ellen"][i - 1],
                avatarUrl: nil,
                level: [42, 28, 15, 8, 3][i - 1],
                isVip: [true, false, false, false, false][i - 1],
                isActiveTycoon: [false, true, false, false, false][i - 1],
                countryId: nil
            )
        }
    }
}
