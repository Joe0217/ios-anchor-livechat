import Foundation

/// 心愿单单条 item（对齐 H5 `currentLiveInfo.wishlist[]` 字段）
struct WishlistItem: Identifiable, Equatable {
    let id: String           // giftId
    let giftName: String
    let giftIconUrl: String? // H5 `giftSmallImg`
    let giftPrice: Int
    let targetCount: Int     // H5 `giftNum` 目标数量
    let completedCount: Int  // H5 `compelteGiftNum` 已完成数量
    /// 承诺文案（多礼物共享首条，可为空）
    let promiseText: String?

    var progress: Double {
        guard targetCount > 0 else { return 0 }
        return min(1.0, Double(completedCount) / Double(targetCount))
    }
    var isCompleted: Bool { completedCount >= targetCount && targetCount > 0 }
}

/// Top6 贡献者单条（对齐 H5 `wishlist-anchor-panel.vue` fetchTop6）
struct WishlistTop6Item: Identifiable, Equatable {
    let id: String            // userId 或槽位序号（空槽用 "empty_<i>"）
    let userId: String?
    let nickname: String?
    let avatarUrl: String?
    let totalDiamond: Int64   // 该用户贡献总钻石
    let rank: Int             // 1-6

    static func emptySlot(at rank: Int) -> WishlistTop6Item {
        WishlistTop6Item(id: "empty_\(rank)", userId: nil, nickname: nil,
                         avatarUrl: nil, totalDiamond: 0, rank: rank)
    }
    var isEmpty: Bool { userId == nil }
}
