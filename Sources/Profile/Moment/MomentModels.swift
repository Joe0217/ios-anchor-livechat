import Foundation

/// 朋友圈/动态 一条 post 的模型（对应 H5 friendsCircle item，蓝本 08 §3.1 / 02-11 §2.1）。
///
/// 字段全部 Optional：H5 字段较多但 iOS 仅渲染必要字段（textContent / imgUrls / 时间 / 赞评 / 作者）。
/// 真机响应字段名/类型有偏差时迭代调整。
struct MomentPost: Codable, Identifiable, Hashable {
    let postId: Int?           // 接口字段：id
    let userId: Int?           // 作者
    let nickname: String?
    let icon: String?
    let textContent: String?
    let imgUrls: [String]?
    let createTime: Int?       // 毫秒时间戳
    let likeCount: Int?
    let commentCount: Int?
    let likeFlag: Int?         // 1=已赞 0=未赞（蓝本 02-11 §4 乐观更新）
    let displayRange: Int?     // 1=全部 2=私密 3=朋友

    var id: String { "\(postId ?? -1)-\(createTime ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case postId = "id"
        case userId, nickname, icon, textContent, imgUrls, createTime
        case likeCount, commentCount, likeFlag, displayRange
    }
}

/// 一页动态数据 + 是否还有下一页。
struct MomentPage {
    let posts: [MomentPost]
    let currentPage: Int
    let hasMore: Bool

    static let empty = MomentPage(posts: [], currentPage: 0, hasMore: false)
}
