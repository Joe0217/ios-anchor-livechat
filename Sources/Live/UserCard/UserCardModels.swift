import Foundation

/// 拉起名片卡时调用方已经持有的用户资料。
///
/// 列表、公屏和房间状态通常已包含头像、昵称、等级等基础字段。名片卡在详情接口返回前
/// 优先显示这些内容，其余区域用骨架占位；详情返回后再替换为完整的 `UserCardInfo`。
struct UserCardPreview: Equatable {
    let userId: String
    var nickname: String? = nil
    var avatarUrl: String? = nil
    var headwearUrl: String? = nil
    /// H5 `cardFrame`：透明中部的资料卡边框图，详情接口返回前可由调用方预先传入。
    var cardFrameUrl: String? = nil
    var gender: UserCardInfo.Gender? = nil
    var age: Int? = nil
    var countryEmoji: String? = nil
    var level: Int? = nil
    var levelName: String? = nil
    var isVip: Bool? = nil
    var userType: Int? = nil
    var isActiveTycoon: Bool? = nil

    init(
        userId: String,
        nickname: String? = nil,
        avatarUrl: String? = nil,
        headwearUrl: String? = nil,
        cardFrameUrl: String? = nil,
        gender: UserCardInfo.Gender? = nil,
        age: Int? = nil,
        countryEmoji: String? = nil,
        level: Int? = nil,
        levelName: String? = nil,
        isVip: Bool? = nil,
        userType: Int? = nil,
        isActiveTycoon: Bool? = nil
    ) {
        self.userId = userId
        self.nickname = nickname
        self.avatarUrl = avatarUrl
        self.headwearUrl = headwearUrl
        self.cardFrameUrl = cardFrameUrl
        self.gender = gender
        self.age = age
        self.countryEmoji = countryEmoji
        self.level = level
        self.levelName = levelName
        self.isVip = isVip
        self.userType = userType
        self.isActiveTycoon = isActiveTycoon
    }
}

/// UserCard model(对齐 H5 `views/liveSetting/components/userCard.vue` L87 `getAnchorPersonalCard` 返回)。
///
/// **iOS 主播端定位**: 覆盖主播查看用户或其他主播的基础资料。
/// 主播类目标沿用同一张资料卡，但不提供拉黑操作；完整主播房资料布局仍留待后续里程碑。
struct UserCardInfo: Equatable {
    let userId: String
    /// H5 后端字段:1=用户 / 2=主播 / 3=虚拟主播 / 4=机器人。主播类名片不显示拉黑操作。
    let userType: Int
    let nickname: String
    let avatarUrl: String?
    /// 头饰道具框 URL(H5 `<head-frame>` 对应 `headwear` / `headFrame`)。为 nil 时 AvatarView 不叠加。
    let headwearUrl: String?
    /// H5 `cardFrame`：透明中部的资料卡边框图，覆盖在卡片渐变背景之上、资料内容之下。
    let cardFrameUrl: String?
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
    /// Party 房内角色。普通用户卡接口不返回时为 nil；Party 管理操作优先用麦位实时角色。
    var roomRoleType: Int? = nil

    enum Gender: Equatable {
        case male, female, unknown
    }

    /// 主播与虚拟主播共用主播类名片权限。
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
