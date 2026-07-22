import Foundation

/// 贡献榜 Tab（对齐 H5 liveContributionPop.vue 双 Tab: Ranking / Record）
enum ContributionTab: String, CaseIterable {
    case ranking    // 贡献榜（本场排名）
    case record     // 礼物记录（本场明细）
}

/// 单条贡献榜条目（本场 + 过去90天）
struct ContributionEntry: Identifiable, Equatable {
    let id: String              // userId
    let rank: Int
    let userId: String
    let nickname: String
    let avatarUrl: String?
    let level: Int
    let isVip: Bool
    let countryId: String?
    let thisLiveDiamond: Int64  // 本场直播贡献
    let last90DaysDiamond: Int64 // 过去 90 天累计
}

/// 单条礼物记录（本场礼物明细）
struct GiftRecord: Identifiable, Equatable {
    let id: String              // 后端记录 id
    let time: Int64             // ms timestamp
    let userId: String
    let userNickname: String
    let userAvatarUrl: String?
    let giftName: String
    let giftIconUrl: String?
    let quantity: Int           // 送礼数量
    let diamondEach: Int64      // 单个钻石价
    /// H5 直接展示后端的 `formattedTime`；缺失时才回退本地相对时间。
    let formattedTime: String?
    var totalDiamond: Int64 { Int64(quantity) * diamondEach }
}

/// 贡献榜分页容器（H5 后端返回）
struct ContributionRankPage: Equatable {
    let entries: [ContributionEntry]
    /// 本场累计收入（顶部大数字显示）
    let totalIncome: Int64
    static let empty = ContributionRankPage(entries: [], totalIncome: 0)
}

/// 礼物记录分页容器
struct GiftRecordPage: Equatable {
    let records: [GiftRecord]
    let hasMore: Bool
    let nextPage: Int
    static let empty = GiftRecordPage(records: [], hasMore: false, nextPage: 1)
}
