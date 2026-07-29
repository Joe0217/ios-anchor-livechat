import Foundation

/// 心愿单通用逻辑索引工具。
enum WishlistCarouselIndex {
    /// 逻辑上的下一项：末项回到首项，供不需要视觉连续性的调用使用。
    static func next(after currentIndex: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (max(0, currentIndex) + 1) % count
    }

}

/// 心愿单单条 item（对齐 H5 `currentLiveInfo.wishlist[]` 字段）
struct WishlistItem: Identifiable, Equatable {
    let id: String           // giftId
    let giftName: String
    let giftIconUrl: String? // H5 `giftSmallImg`
    let giftPrice: Int
    let targetCount: Int     // H5 `giftNum` 目标数量
    let completedCount: Int  // H5 `compelteGiftNum` 已完成数量
    /// 后端可直接下发 `completed=true`，H5 将其视为完成，即使计数不完整也要保留。
    let isMarkedCompleted: Bool
    /// 承诺文案（多礼物共享首条，可为空）
    let promiseText: String?

    var progress: Double {
        if isMarkedCompleted { return 1 }
        guard targetCount > 0 else { return 0 }
        return min(1.0, Double(completedCount) / Double(targetCount))
    }
    var isCompleted: Bool { isMarkedCompleted || (completedCount >= targetCount && targetCount > 0) }

    func updatingCompletedCount(_ value: Int) -> WishlistItem {
        let normalizedCount = max(0, min(targetCount, value))
        return WishlistItem(
            id: id,
            giftName: giftName,
            giftIconUrl: giftIconUrl,
            giftPrice: giftPrice,
            targetCount: targetCount,
            completedCount: normalizedCount,
            // H5 用 attachType 50 的权威 `compelteGiftNum` 重算 completed，
            // 因此不能让一次旧的完成事件永久锁定该状态。
            isMarkedCompleted: targetCount > 0 && normalizedCount >= targetCount,
            promiseText: promiseText
        )
    }

    func markingCompleted() -> WishlistItem {
        WishlistItem(
            id: id,
            giftName: giftName,
            giftIconUrl: giftIconUrl,
            giftPrice: giftPrice,
            targetCount: targetCount,
            completedCount: targetCount,
            isMarkedCompleted: true,
            promiseText: promiseText
        )
    }
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
