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
    // trial step 3 真集成反悔：实测真机响应 createTime 是 String (H5 type.ts:25 也是 string)，
    // 步 1a 写成 Int? 是 spec §1.4 第 3 项遗留 bug；步 1c 抓包确认后修正。
    let createTime: String?
    // trial #1：likeFlag / likeCount 改为 var，支持乐观点赞就地切换；
    // 其他字段保持 let (只读)，避免业务无关字段被误改。
    var likeCount: Int?
    let commentCount: Int?
    var likeFlag: Int?         // 1=已赞 0=未赞（蓝本 02-11 §4 乐观更新）
    let displayRange: Int?     // 1=全部 2=私密 3=朋友

    var id: String { "\(postId ?? -1)-\(createTime ?? "")" }

    /// 判断 `imgUrls` 里的某个 URL 是否是视频（对齐 H5 `circleContent.vue:isVideo`）。
    ///
    /// H5 后端把视频 URL 塞在 `imgUrls` 数组里（不单独 videoUrl 字段），
    /// 客户端按扩展名 + "video" 关键字识别。
    static func isVideo(url: String) -> Bool {
        let lower = url.lowercased()
        let videoExts = [".mp4", ".webm", ".ogg", ".mov", ".avi", ".flv", ".wmv", ".mkv"]
        if videoExts.contains(where: { lower.hasSuffix($0) }) { return true }
        // H5 fallback：URL 含 "video" 关键字（如 CDN 路径带 /video/）
        return lower.contains("video")
    }

    enum CodingKeys: String, CodingKey {
        // trial #1 (A-spec §1.4) 修复：H5 真实字段是 likeNum / commentNum，
        // 旧版无 CodingKey 别名 → Codable 直接按属性名匹配，结果 likeCount/commentCount 永远 nil。
        case postId = "id"
        case userId, nickname, icon, textContent, imgUrls, createTime
        case likeCount = "likeNum"
        case commentCount = "commentNum"
        case likeFlag, displayRange
    }
}

/// 朋友圈评论（对齐 H5 `comments.vue` + 后端 `getComments` 响应）。
///
/// 字段全 optional：H5 只用 nickname + commentContent 展示，其他字段 iOS 暂不消费。
struct MomentComment: Codable, Identifiable, Hashable {
    let commentId: Int?
    let commentContent: String?
    let nickname: String?
    let createTime: String?

    var id: String { "\(commentId ?? -1)-\(createTime ?? "")" }

    enum CodingKeys: String, CodingKey {
        case commentId = "id"
        case commentContent, nickname, createTime
    }
}

/// 一页动态数据 + 是否还有下一页。
struct MomentPage {
    let posts: [MomentPost]
    let currentPage: Int
    let hasMore: Bool

    static let empty = MomentPage(posts: [], currentPage: 0, hasMore: false)
}

/// 朋友圈数据源：决定 MomentFeedStore 拉哪种数据（对齐 H5 `circle/{official,moment,me}.vue` 三入口）。
///
/// 后端 `officalType` 编码：
/// - `.official` → `officalType=1`, `keyword=""`（官方圈）
/// - `.moment`   → `officalType=2`（全站圈，无 keyword）
/// - `.me(uid)`  → `officalType=3`, `keyword=uid`（我的动态）
enum MomentSource: Hashable {
    case official
    case moment
    case me(userId: Int)
}

#if DEBUG
extension MomentPost {
    /// Preview 用工厂。trial #1 PreviewProvider 覆盖空/含图/无图等场景用。
    /// 注：单测请用 `TestPostFactory.make`（Tests/HilyTests/Circle/）。
    static func mock(
        postId: Int = 1,
        nickname: String = "Sarah",
        icon: String? = nil,
        textContent: String? = "Hello, world! This is a sample moment.",
        imgUrls: [String]? = nil,
        createTime: String = "2024-01-15 12:00:00",
        likeFlag: Int = 0,
        likeCount: Int = 12,
        commentCount: Int = 3
    ) -> MomentPost {
        MomentPost(
            postId: postId,
            userId: 100,
            nickname: nickname,
            icon: icon,
            textContent: textContent,
            imgUrls: imgUrls,
            createTime: createTime,
            likeCount: likeCount,
            commentCount: commentCount,
            likeFlag: likeFlag,
            displayRange: 1
        )
    }
}
#endif
