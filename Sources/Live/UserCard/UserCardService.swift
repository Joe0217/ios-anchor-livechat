import Foundation

/// UserCard 数据源 protocol（H 里程碑接入真 API）
///
/// **真 API 契约**（对齐 H5 `userCard.vue` L87）：
/// - POST `/api/user/getAnchorPersonalCard`  body: `{ searchValue: userId }`
/// - 加密: AES-128-CBC + Hex（走 APIClient 主链路自动处理）
protocol UserCardServiceProtocol {
    func fetch(userId: String) async throws -> UserCardInfo
    func follow(userId: String) async throws
    func unfollow(userId: String) async throws
    func block(userId: String) async throws
    func unblock(userId: String) async throws
}

/// Fakes 实现（Level B 视觉走通用）
struct UserCardServiceFakes: UserCardServiceProtocol {
    func fetch(userId: String) async throws -> UserCardInfo {
        try await Task.sleep(nanoseconds: 200_000_000)
        return UserCardInfo(
            userId: userId,
            nickname: "User_\(userId)",
            avatarUrl: nil,
            gender: .female,
            age: 24,
            countryEmoji: "🇨🇳",
            level: 12,
            levelName: "Lv.12 Rising",
            isVip: true,
            followerCount: 1234,
            followingCount: 56,
            giftWalls: [
                GiftWallItem(id: "g1", iconUrl: nil, count: 12),
                GiftWallItem(id: "g2", iconUrl: nil, count: 8),
                GiftWallItem(id: "g3", iconUrl: nil, count: 5),
                GiftWallItem(id: "g4", iconUrl: nil, count: 3),
            ],
            isBlocked: false,
            isFollowed: false
        )
    }

    func follow(userId: String) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    func unfollow(userId: String) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    func block(userId: String) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    func unblock(userId: String) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

/// 真 API 实现（H 里程碑接入）
struct UserCardServiceReal: UserCardServiceProtocol {
    func fetch(userId: String) async throws -> UserCardInfo {
        // TODO H 里程碑：POST /api/user/getAnchorPersonalCard body: { searchValue: userId }
        try await UserCardServiceFakes().fetch(userId: userId)
    }
    func follow(userId: String) async throws {
        try await UserCardServiceFakes().follow(userId: userId)
    }
    func unfollow(userId: String) async throws {
        try await UserCardServiceFakes().unfollow(userId: userId)
    }
    func block(userId: String) async throws {
        try await UserCardServiceFakes().block(userId: userId)
    }
    func unblock(userId: String) async throws {
        try await UserCardServiceFakes().unblock(userId: userId)
    }
}
