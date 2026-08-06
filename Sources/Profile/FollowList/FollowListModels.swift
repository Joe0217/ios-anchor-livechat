import Foundation

/// 关注 / 粉丝 / 朋友三种关系，对应 H5 enumType（蓝本 08 §3.2 / 02-11 §2.2）。
///
/// 后端 type 枚举：1=Friends（双向）/ 2=Followers（粉丝）/ 3=Following（我关注的）。
/// 顺序按设计稿/H5 视觉惯例：Following → Followers → Friends。
enum FollowSegment: Int, CaseIterable, Hashable, Identifiable {
    case following = 3
    case followers = 2
    case friends   = 1

    var id: Int { rawValue }

    /// 接口 `type` 参数值
    var apiType: Int { rawValue }

    var title: String {
        switch self {
        case .following: return L10n.profileFollowing
        case .followers: return L10n.profileFollowers
        case .friends:   return L10n.profileFriends
        }
    }
}

/// 关注 / 粉丝 / 朋友列表行的用户对象。
///
/// 字段全部 Optional 与 AnchorInfo 同策略：H5/安卓蓝本未明列出 `/api/user/v2/userFriend`
/// 返回字段清单，先列出渲染所需核心字段，真机响应有偏差时迭代调整。
struct FollowUser: Codable, Identifiable, Hashable {
    let userId: Int?
    let nickname: String?
    let icon: String?
    let sex: Int?              // 1=男 2=女
    let age: Int?
    let countryCode: String?
    let level: Int?
    let levelName: String?
    let signature: String?
    /// `/api/user/v2/userFriend` 当前契约字段。
    let followed: Bool?
    /// 历史响应/本地关系变更字段：1=已关注，0=未关注。
    let followFlag: Int?

    var isFollowing: Bool {
        if let followFlag { return followFlag == 1 }
        return followed == true
    }

    /// SwiftUI ForEach 主键：用 userId 兜底，全空时 fallback 到 nickname+icon 组合
    var id: String { "\(userId ?? -1)-\(nickname ?? "")" }
}

extension FollowUser {
    /// 返回 followFlag 被替换的副本（FollowUser 是 immutable struct，必须重建）。
    /// 用于乐观更新/回滚时更换关注状态而保留其他字段。
    func withFollowFlag(_ flag: Int) -> FollowUser {
        FollowUser(
            userId: userId, nickname: nickname, icon: icon,
            sex: sex, age: age, countryCode: countryCode,
            level: level, levelName: levelName, signature: signature,
            followed: flag == 1,
            followFlag: flag
        )
    }
}

/// 一页关注/粉丝/朋友数据 + 是否还有下一页。
/// 「下一页判定」：返回数组长度 < pageSize 即到底（蓝本 02-11 §4）。
struct FollowListPage {
    let users: [FollowUser]
    let currentPage: Int
    let hasMore: Bool

    static let empty = FollowListPage(users: [], currentPage: 0, hasMore: false)
}

// `.followRelationChanged` 已抽到 `FollowRelationNotification.swift`（让 HilyTests 可编译）
