import Foundation

/// UserCard model(对齐 H5 `views/liveSetting/components/userCard.vue` L87 `getAnchorPersonalCard` 返回)。
///
/// **iOS 主播端定位**: 只覆盖 H5 主播端 `views/liveSetting/` 场景(主播看用户)。
/// H5 `views/liveRoom/`(主播看别的主播房)场景对应的 `isAnchor=true` 分支本项目不实现;
/// `userType` 保留字段供未来"看别的主播房"里程碑再启用。
struct UserCardInfo: Equatable {
    let userId: String
    /// H5 后端字段:1=用户 / 2=主播 / 3=虚拟主播 / 4=机器人。本期 UI 不据此分支。
    let userType: Int
    let nickname: String
    let avatarUrl: String?
    /// 头饰道具框 URL(H5 `<head-frame>` 对应 `headwear` / `headFrame`)。为 nil 时 AvatarView 不叠加。
    let headwearUrl: String?
    /// 云信账号,Message/Block 请求必需。为 nil 时 Message/Block 按钮 disabled(R-3)。
    let yxAccid: String?
    let gender: Gender
    let age: Int?
    /// 派生:H5 `giftData.country`(country code)→ emoji flag。用 `AnchorInfoStore.flagEmoji(from:)` 派生。
    let countryEmoji: String?
    let level: Int
    let levelName: String?
    let isVip: Bool
    /// 粉丝数(H5 `fans` 字段)
    let followerCount: Int
    /// 关注数(H5 `follow` 字段)
    let followingCount: Int
    /// 主播欢迎语(H5 `liveWelcome`)。为空时不显示。
    let liveWelcome: String?
    /// 勋章列表(H5 `medals[].medalImageUrl`)。为空时不显示。
    let medals: [Medal]
    /// 礼物墙(top N)
    let giftWalls: [GiftWallItem]
    /// 是否已被本主播拉黑。optimistic toggle,var
    var isBlocked: Bool
    /// 是否已关注本用户。optimistic toggle,var
    var isFollowed: Bool
    /// 活跃大 R 标识（B1）：来自 getAnchorPersonalCard 响应 `activeTycoon` 字段，
    /// 若后端未返回则 fallback false（UI 无 badge，不 crash）。iOS 真机首次抓 log 后可能需
    /// 关联 SendRankService.isActiveTycoon 二次兜底（当前不做，等真机验证）。
    var isActiveTycoon: Bool = false

    enum Gender: Equatable {
        case male, female, unknown
    }

    /// 保留派生但**本期 UI 不用**(方便未来"看别的主播房"启用)
    var isAnchor: Bool { userType == 2 || userType == 3 }
}

/// 勋章图 row 项(H5 comment:"后端 medal.id 非全量必传,混合 id/index 作 key 会导致重复键与 patch 错乱,
/// 展示为只读列表无需稳定标识,统一用 index 作 key")—— iOS 同款用 index-based id。
struct Medal: Identifiable, Equatable {
    let id: String
    let imageUrl: String?
}

/// 礼物墙单项。H5 template 用 `giftImg || icon` / `giftName` / `giftCount || num` 双字段兜底;
/// iOS decode 同款兜底(见 UserCardService.decodeCard)。
struct GiftWallItem: Identifiable, Equatable {
    let id: String        // giftId
    let iconUrl: String?  // giftImg / icon
    let name: String?     // giftName
    let count: Int        // giftCount / num
}
