import Foundation

/// 主播周榜排名周期（对齐 H5 `girlWeeklyRank.vue` rankType='week'/'lastWeek'）
enum RankPeriod: String, CaseIterable {
    case week       // 本周
    case lastWeek   // 上周
}

/// 单条排名条目（对齐 H5 receiveRankV3 返回体）
struct RankEntry: Identifiable, Equatable {
    let id: String              // userId 作为 identity
    let rank: Int               // 排名（1-based）
    let userId: String
    let nickname: String
    let avatarUrl: String?
    let level: Int              // 等级（用于徽章）
    let diamond: Int64          // 本周期贡献钻石数
}

/// Rank 列表页 + 主播自己排名信息（对齐 H5 底部吸附条 anchor own rank）
struct RankListPage: Equatable {
    let entries: [RankEntry]
    /// 主播自己当前排名（nil = 未上榜）
    let anchorOwnRank: Int?
    /// 距上一名的差值（nil = 未上榜 or 已第一名）
    let diffToPrevious: Int64?
    /// 主播自己昵称/头像（顶部展示）
    let anchorNickname: String
    let anchorAvatarUrl: String?

    static let empty = RankListPage(entries: [], anchorOwnRank: nil, diffToPrevious: nil,
                                     anchorNickname: "", anchorAvatarUrl: nil)
}
