import Foundation

protocol HomeRankingServiceProtocol {
    func fetchRanking(category: HomeRankingCategory, period: HomeRankingPeriod) async throws -> HomeRankingPayload
    func fetchCoupleRanking(period: HomeRankingPeriod) async throws -> HomeCoupleRankingPayload
}

struct HomeRankingService: HomeRankingServiceProtocol {
    static let shared = HomeRankingService()

    func fetchRanking(category: HomeRankingCategory, period: HomeRankingPeriod) async throws -> HomeRankingPayload {
        let rankType = rankType(for: category, period: period)
        let data = try await APIClient.shared.post(
            "/api/ranking/getRankingList",
            body: ["rankType": rankType, "pageSize": 30, "currentPage": 1, "key": ""]
        )
        return try JSONDecoder().decode(HomeRankingResponse.self, from: data).payload
    }

    func fetchCoupleRanking(period: HomeRankingPeriod) async throws -> HomeCoupleRankingPayload {
        let dailyType = period == .week ? "weekly" : "daily"
        let data = try await APIClient.shared.post(
            "/api/ranking/v2/userRank",
            body: [
                "rankType": "ANCHOR_USER_COUPLE",
                "dailyType": dailyType,
                "pageSize": 50,
                "currentPage": 1
            ]
        )
        return try HomeCoupleRankingResponse.decode(from: data)
    }

    private func rankType(for category: HomeRankingCategory, period: HomeRankingPeriod) -> String {
        switch (category, period) {
        case (.charm, .day): return "ANCHOR_DAY"
        case (.charm, .week): return "ANCHOR_WEEK"
        case (.charm, .month): return "ANCHOR_MON"
        case (.wealth, .day): return "USER_DAY"
        case (.wealth, .week): return "USER_WEEK"
        case (.wealth, .month): return "USER_MON"
        case (.couple, _):
            preconditionFailure("CP ranking uses fetchCoupleRanking(period:)")
        }
    }
}

private struct HomeRankingResponse: Decodable {
    let members: [HomeRankingMember]
    let mine: HomeRankingMember?
    let currentTime: String?

    private enum CodingKeys: String, CodingKey {
        case rankingMembers, rankingMineVo, currentTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = (try? c.decode([HomeRankingMember].self, forKey: .rankingMembers)) ?? []
        mine = try? c.decodeIfPresent(HomeRankingMember.self, forKey: .rankingMineVo)
        currentTime = c.decodeFlexibleString(forKey: .currentTime)
    }

    var payload: HomeRankingPayload {
        HomeRankingPayload(members: members, mine: mine, currentTime: currentTime)
    }
}

private enum HomeCoupleRankingResponse {
    static func decode(from data: Data) throws -> HomeCoupleRankingPayload {
        let root = try JSONSerialization.jsonObject(with: data)
        if let list = root as? [[String: Any]] {
            return HomeCoupleRankingPayload(members: try decodeMembers(list), mine: nil)
        }
        guard let object = root as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unexpected CP ranking response"))
        }
        let list = (object["list"] as? [[String: Any]]) ?? []
        let mine = object["myRank"] as? [String: Any]
        return HomeCoupleRankingPayload(
            members: try decodeMembers(list),
            mine: try mine.map(decodeMember)
        )
    }

    private static func decodeMembers(_ source: [[String: Any]]) throws -> [HomeCoupleRankingMember] {
        try source.map(decodeMember)
    }

    private static func decodeMember(_ source: [String: Any]) throws -> HomeCoupleRankingMember {
        let data = try JSONSerialization.data(withJSONObject: source)
        return try JSONDecoder().decode(HomeCoupleRankingMember.self, from: data)
    }
}
