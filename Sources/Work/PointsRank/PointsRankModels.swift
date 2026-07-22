import Foundation

/// Phase E —— 积分排行榜页数据模型。对齐 H5 `POST /api/ranking/anchorIntegralRankingList` 响应。

/// 排行榜完整响应
struct PointsRankListResponse: Decodable, Hashable {
    let items: [PointsRankItemVO]
    let myIntegral: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([PointsRankItemVO].self, forKey: .items)) ?? []
        myIntegral = c.decodeFlexibleInt(forKey: .myIntegral) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case items, myIntegral
    }
}

/// 单条排行榜项。userId String/Int 双兼容(对齐 ios-decode-userid-compat rule)
struct PointsRankItemVO: Decodable, Identifiable, Hashable {
    let userId: String
    let nickname: String
    let icon: String?
    let countryId: String?
    let integralAmount: Int
    /// 领取的奖励(H5 用 `reward` 字段;非 point 榜用 `rankingReward`)
    let reward: String?

    var id: String { userId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // userId String/Int 双兼容
        if let s = try? c.decode(String.self, forKey: .userId) {
            userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .userId) {
            userId = String(i)
        } else {
            userId = ""
        }
        nickname = (try? c.decodeIfPresent(String.self, forKey: .nickname)) ?? ""
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        countryId = try? c.decodeIfPresent(String.self, forKey: .countryId)
        integralAmount = c.decodeFlexibleInt(forKey: .integralAmount) ?? 0
        // reward String/Int 双兼容
        if let s = try? c.decodeIfPresent(String.self, forKey: .reward), !s.isEmpty {
            reward = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .reward) {
            reward = "\(i)"
        } else {
            reward = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case userId, nickname, icon, countryId, integralAmount, reward
    }
}
