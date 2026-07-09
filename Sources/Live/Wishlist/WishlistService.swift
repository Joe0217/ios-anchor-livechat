import Foundation

/// Wishlist 数据源 protocol（H 里程碑接入真 API）
///
/// **真 API 契约**（对齐 H5 wishlist store）：
/// - 获取心愿单: POST `/api/agora/live/getAnchorWishlist`  body: `{ searchValue: anchorUserId }`
/// - Top6: POST `/api/live/wish/gifter/top6`  body: `{ liveRecordId, anchorId }`
/// - 加密: AES-128-CBC + Hex（走 APIClient 主链路自动处理）
protocol WishlistServiceProtocol {
    func fetchWishlist(anchorUserId: String) async throws -> [WishlistItem]
    func fetchTop6(liveRecordId: String, anchorId: String) async throws -> [WishlistTop6Item]
}

/// Fakes 实现（Level B）—— 3 条 wishlist：1 已完成 + 2 未完成
struct WishlistServiceFakes: WishlistServiceProtocol {
    func fetchWishlist(anchorUserId: String) async throws -> [WishlistItem] {
        try await Task.sleep(nanoseconds: 200_000_000)
        // v17 Fakes：Rose/Star/Crown 用真实图片 URL（H 期接真 API 时后端返回该字段）
        return [
            WishlistItem(id: "g1", giftName: "Rose",
                         giftIconUrl: "https://img.hnhily.link/mstatic/gift/rose_small.webp",
                         giftPrice: 100, targetCount: 100, completedCount: 100,
                         promiseText: "Complete rose wish for a special dance 💃"),
            WishlistItem(id: "g2", giftName: "Star",
                         giftIconUrl: "https://img.hnhily.link/mstatic/gift/star_small.webp",
                         giftPrice: 500, targetCount: 55, completedCount: 45,
                         promiseText: "Let's reach the star wish together!"),
            WishlistItem(id: "g3", giftName: "Crown",
                         giftIconUrl: "https://img.hnhily.link/mstatic/gift/crown_small.webp",
                         giftPrice: 2000, targetCount: 30, completedCount: 8,
                         promiseText: nil),
        ]
    }

    func fetchTop6(liveRecordId: String, anchorId: String) async throws -> [WishlistTop6Item] {
        try await Task.sleep(nanoseconds: 200_000_000)
        return [
            WishlistTop6Item(id: "u1", userId: "u1", nickname: "Alice",  avatarUrl: nil, totalDiamond: 12000, rank: 1),
            WishlistTop6Item(id: "u2", userId: "u2", nickname: "Bob",    avatarUrl: nil, totalDiamond: 8000,  rank: 2),
            WishlistTop6Item(id: "u3", userId: "u3", nickname: "Charlie", avatarUrl: nil, totalDiamond: 5500,  rank: 3),
            WishlistTop6Item(id: "u4", userId: "u4", nickname: "David",  avatarUrl: nil, totalDiamond: 2000,  rank: 4),
            .emptySlot(at: 5),
            .emptySlot(at: 6),
        ]
    }
}

/// 真 API 实现（H 里程碑接入）
struct WishlistServiceReal: WishlistServiceProtocol {
    func fetchWishlist(anchorUserId: String) async throws -> [WishlistItem] {
        try await WishlistServiceFakes().fetchWishlist(anchorUserId: anchorUserId)
    }
    func fetchTop6(liveRecordId: String, anchorId: String) async throws -> [WishlistTop6Item] {
        try await WishlistServiceFakes().fetchTop6(liveRecordId: liveRecordId, anchorId: anchorId)
    }
}
