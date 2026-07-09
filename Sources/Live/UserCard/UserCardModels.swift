import Foundation

/// UserCard model（对齐 H5 userCard.vue L87 `getAnchorPersonalCard` 返回）
struct UserCardInfo: Equatable {
    let userId: String
    let nickname: String
    let avatarUrl: String?
    let gender: Gender
    let age: Int?
    let countryEmoji: String?
    let level: Int
    let levelName: String?
    let isVip: Bool
    let followerCount: Int
    let followingCount: Int
    /// 礼物墙（Top N 礼物图片 + 数量）
    let giftWalls: [GiftWallItem]
    /// 是否已被本用户拉黑
    let isBlocked: Bool
    /// 是否已被本用户关注
    let isFollowed: Bool

    enum Gender: Equatable {
        case male, female, unknown
    }
}

struct GiftWallItem: Identifiable, Equatable {
    let id: String        // giftId
    let iconUrl: String?
    let count: Int
}
