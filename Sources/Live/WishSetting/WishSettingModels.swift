import Foundation

/// 承诺档位（对齐 H5 `wishSetting/index.vue:22` TYPE 常量）。
///
/// - `.none`：不填承诺；`promiseTemplateId=0, promiseText=""`
/// - `.common`：平台模板；`promiseTemplateId` 是模板 id，`promiseText` 是模板 content
/// - `.private_`：私人模板（已审核通过的自由文案池条目）；同上
public enum PromiseType: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case common = 1
    case private_ = 2

    /// UI 展示文案 key —— 三种承诺类型 selector
    public var titleKey: String {
        switch self {
        case .none:     return "wishSetting.type.noText"
        case .common:   return "wishSetting.type.common"
        case .private_: return "wishSetting.type.private"
        }
    }
}

/// 心愿单单个礼物（对齐 H5 `wishStore.wishlist` 数组元素结构）。
///
/// - `giftId`：H5 冗余字段（== id），iOS 侧也保留，`beginLiveRoom` payload 需要
/// - `giftNum`：数量 1-99
/// - `sortWeight`：H5 序列化时按 index 赋值（左 0 → 右 N）；iOS 侧保存 wishlist 顺序即可，最终提交时按数组 index 赋权重
public struct WishGift: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64            // 与 GiftListData.id 一致
    public var giftId: Int64        // 冗余
    public var name: String
    public var giftPrice: Int64
    public var giftSmallImg: String
    public var giftNum: Int         // 1..99
    public var sortWeight: Int      // 序列化前重新赋值 = array index

    public init(from gift: GiftListData, giftNum: Int = 1, sortWeight: Int = 0) {
        self.id = gift.id
        self.giftId = gift.id
        self.name = gift.name
        self.giftPrice = gift.giftPrice
        self.giftSmallImg = gift.giftSmallImg.isEmpty ? gift.giftImg : gift.giftSmallImg
        self.giftNum = max(1, min(99, giftNum))
        self.sortWeight = sortWeight
    }
}

/// 承诺模板（Common template 或 Private template 共用结构）。
///
/// - Common template：`getWishTemplateList` 返回；`id` = 平台模板 id
/// - Private template：`getWishPromisePool` 返回；`id` = 池条目 id（可删）
public struct WishTemplate: Codable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let content: String

    public init(id: Int64, content: String) {
        self.id = id
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case id, content }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Int64 / String 双兼容（.claude/rules/ios-decode-userid-compat.md）
        if let i = try? c.decode(Int64.self, forKey: .id) {
            self.id = i
        } else if let s = try? c.decode(String.self, forKey: .id), let i = Int64(s) {
            self.id = i
        } else {
            self.id = 0
        }
        self.content = (try? c.decode(String.self, forKey: .content)) ?? ""
    }
}
