import Foundation

/// 首页右上角入口的两个实际目的地。H5 在 Circle 子页会把同一徽章改链到 `/pointsRank`。
enum HomeLeaderboardRoute: Hashable {
    case ranking
    case points
}

/// 首页榜单分类。与 H5 `/rank?path=list` 的 Charm / Wealth / Couple 三个主 Tab 一一对应。
enum HomeRankingCategory: String, CaseIterable, Identifiable {
    case charm
    case wealth
    case couple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .charm: return L10n.homeRankCharm
        case .wealth: return L10n.homeRankWealth
        case .couple: return L10n.homeRankCouple
        }
    }
}

/// H5 普通榜单周期；CP 榜只支持 day/week，View 会据此隐藏 month。
enum HomeRankingPeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return L10n.homeRankDay
        case .week: return L10n.homeRankWeek
        case .month: return L10n.homeRankMonth
        }
    }
}

/// 首页全站榜普通条目。H5 `getRankingList` 的所有展示字段均做 String/Int 混发兼容。
struct HomeRankingMember: Decodable, Identifiable, Equatable {
    let userId: String
    let nickname: String
    let icon: String?
    let countryId: String?
    let age: Int?
    let levelName: String?
    let isVip: Bool
    let value: String
    let reward: String?
    let rank: Int?
    let isRanked: Bool

    var id: String { userId }

    private enum CodingKeys: String, CodingKey {
        case userId, anchorUid, nickname, nickName, icon, avatar, countryId, age
        case userlevelName, userLevelName, levelName, vip, vipFlag, num, costNum
        case rankingReward, reward, rank, onRank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.decodeFlexibleString(forKey: .userId)
            ?? c.decodeFlexibleString(forKey: .anchorUid)
            ?? UUID().uuidString
        nickname = c.decodeFlexibleString(forKey: .nickname)
            ?? c.decodeFlexibleString(forKey: .nickName)
            ?? L10n.anonymous
        icon = c.decodeFlexibleString(forKey: .icon) ?? c.decodeFlexibleString(forKey: .avatar)
        countryId = c.decodeFlexibleString(forKey: .countryId)
        age = c.decodeFlexibleInt(forKey: .age)
        levelName = c.decodeFlexibleString(forKey: .userlevelName)
            ?? c.decodeFlexibleString(forKey: .userLevelName)
            ?? c.decodeFlexibleString(forKey: .levelName)
        isVip = c.decodeFlexibleBool(forKey: .vip) ?? c.decodeFlexibleBool(forKey: .vipFlag) ?? false
        value = c.decodeFlexibleString(forKey: .num)
            ?? c.decodeFlexibleString(forKey: .costNum)
            ?? "0"
        reward = c.decodeFlexibleString(forKey: .rankingReward) ?? c.decodeFlexibleString(forKey: .reward)
        rank = c.decodeFlexibleInt(forKey: .rank)
        isRanked = c.decodeFlexibleBool(forKey: .onRank) ?? (rank.map { $0 > 0 } ?? false)
    }
}

struct HomeRankingPayload: Equatable {
    let members: [HomeRankingMember]
    let mine: HomeRankingMember?
    let currentTime: String?
}

/// CP 榜使用独立接口与双人结构。H5 同时兼容根数组和 `{ list, myRank }`，原生同样兼容。
struct HomeCoupleRankingMember: Decodable, Identifiable, Equatable {
    let rank: Int?
    let anchorId: String?
    let anchorNickname: String
    let anchorIcon: String?
    let userId: String?
    let userNickname: String
    let userIcon: String?
    let value: String
    let anchorRewards: [HomeCoupleRankingReward]
    let userRewards: [HomeCoupleRankingReward]

    var isMysteryUser: Bool { userId?.isEmpty != false }
    var displayUserNickname: String { isMysteryUser ? L10n.homeRankMystery : userNickname }

    var id: String {
        [anchorId, userId].compactMap { $0 }.joined(separator: "-").isEmpty
            ? UUID().uuidString
            : [anchorId, userId].compactMap { $0 }.joined(separator: "-")
    }

    private enum CodingKeys: String, CodingKey {
        case rank, rankNo, anchorUid, anchorUserId, anchorNickname, anchorNickName, anchorIcon
        case userId, userNickname, userNickName, userIcon, costNum, num, anchorRewards, userRewards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rank = c.decodeFlexibleInt(forKey: .rank) ?? c.decodeFlexibleInt(forKey: .rankNo)
        anchorId = c.decodeFlexibleString(forKey: .anchorUid) ?? c.decodeFlexibleString(forKey: .anchorUserId)
        anchorNickname = c.decodeFlexibleString(forKey: .anchorNickname)
            ?? c.decodeFlexibleString(forKey: .anchorNickName)
            ?? L10n.homeRankHostPlaceholder
        anchorIcon = c.decodeFlexibleString(forKey: .anchorIcon)
        userId = c.decodeFlexibleString(forKey: .userId)
        userNickname = c.decodeFlexibleString(forKey: .userNickname)
            ?? c.decodeFlexibleString(forKey: .userNickName)
            ?? L10n.homeRankUserPlaceholder
        userIcon = c.decodeFlexibleString(forKey: .userIcon)
        value = c.decodeFlexibleString(forKey: .costNum) ?? c.decodeFlexibleString(forKey: .num) ?? "0"
        anchorRewards = (try? c.decode([HomeCoupleRankingReward].self, forKey: .anchorRewards)) ?? []
        userRewards = (try? c.decode([HomeCoupleRankingReward].self, forKey: .userRewards)) ?? []
    }
}

/// CP 榜奖励项。H5 `cp-reward-popup.vue` 展示 `itemIcon` / `itemName`，id 会混发 String/Int。
struct HomeCoupleRankingReward: Decodable, Identifiable, Equatable {
    let itemId: String
    let itemIcon: String?
    let itemName: String?
    let itemType: Int
    let durationDays: Int

    var id: String { itemId }

    private enum CodingKeys: String, CodingKey {
        case itemId, id, itemIcon, icon, itemName, name, itemType, durationDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = c.decodeFlexibleString(forKey: .itemId)
            ?? c.decodeFlexibleString(forKey: .id)
            ?? UUID().uuidString
        itemIcon = c.decodeFlexibleString(forKey: .itemIcon) ?? c.decodeFlexibleString(forKey: .icon)
        itemName = c.decodeFlexibleString(forKey: .itemName) ?? c.decodeFlexibleString(forKey: .name)
        itemType = c.decodeFlexibleInt(forKey: .itemType) ?? 0
        durationDays = c.decodeFlexibleInt(forKey: .durationDays) ?? 0
    }
}

struct HomeCoupleRankingPayload: Equatable {
    let members: [HomeCoupleRankingMember]
    let mine: HomeCoupleRankingMember?
}
