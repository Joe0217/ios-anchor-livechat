import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "CircleService")

/// 数据层 protocol — Store 通过它依赖，单测/步 1c Fakes 通过 mock instance 注入。
///
/// 设计为 instance protocol (非 static) 是为了单测可替换；
/// `CircleService.shared` 为生产单例，static 便捷接口走 `shared` 转发，兼容现有 Profile 调用方。
protocol CircleServiceProtocol {
    func getMyMoments(userId: Int, pageSize: Int, currentPage: Int) async throws -> MomentPage
    func getAllMoments(pageSize: Int, currentPage: Int) async throws -> MomentPage
    func getOfficialMoments(pageSize: Int, currentPage: Int) async throws -> MomentPage
    func like(postId: Int, optionType: Int) async throws
    /// 拉某条 post 的评论列表（对齐 H5 `comments.vue`）。
    /// - parameter postId: 帖子 id（H5 keyword 字段）
    /// - 默认拉最近 7 天、最多 100 条（H5 行为）
    func getComments(postId: Int, pageSize: Int, currentPage: Int) async throws -> [MomentComment]
    /// 删除我发的朋友圈（对齐 H5 `mine/index.vue:117-125` → `postDelete({ searchValue: id })`）。
    /// - parameter postId: 帖子 id（H5 `searchValue` 字段值）
    func deletePost(postId: Int) async throws
}

/// 朋友圈接口集 (对应 H5 `friendsCircle/*`，蓝本 02-11 §2.1)。
///
/// trial #1 (A-spec-Circle朋友圈tab) 重命名自 MomentService，统一 Profile/Home Circle 共用。
/// path 修复 (现存 bug)：旧版缺 `/expand` 前缀，H5 真实 path 是 `/api/expand/friendsCircle/*`。
final class CircleService: CircleServiceProtocol {

    static let shared = CircleService()

    /// 拉取「我的」动态列表：`officalType=3` + `keyword=<userId>`。
    func getMyMoments(userId: Int,
                      pageSize: Int = 20,
                      currentPage: Int) async throws -> MomentPage {
        let body: [String: Any] = [
            "officalType": 3,
            "keyword": "\(userId)",
            "pageSize": pageSize,
            "currentPage": currentPage,
        ]
        let data = try await APIClient.shared.post("/api/expand/friendsCircle/v2/queryList", body: body)
        let posts = Self.extractPosts(from: data)
        let hasMore = posts.count >= pageSize
        logger.info("getMyMoments userId=\(userId) page=\(currentPage) got=\(posts.count) hasMore=\(hasMore)")
        return MomentPage(posts: posts, currentPage: currentPage, hasMore: hasMore)
    }

    /// 拉取「全站」动态列表 (Circle Moment 子 tab)：`officalType=2`，无 keyword。
    func getAllMoments(pageSize: Int = 20,
                       currentPage: Int) async throws -> MomentPage {
        let body: [String: Any] = [
            "officalType": 2,
            "pageSize": pageSize,
            "currentPage": currentPage,
        ]
        let data = try await APIClient.shared.post("/api/expand/friendsCircle/v2/queryList", body: body)
        let posts = Self.extractPosts(from: data)
        let hasMore = posts.count >= pageSize
        logger.info("getAllMoments page=\(currentPage) got=\(posts.count) hasMore=\(hasMore)")
        return MomentPage(posts: posts, currentPage: currentPage, hasMore: hasMore)
    }

    /// 拉取「官方」动态列表 (Circle Official 子 tab)：`officalType=1`, `keyword=""`。
    /// 对齐 H5 `circle/official.vue`。
    func getOfficialMoments(pageSize: Int = 20,
                            currentPage: Int) async throws -> MomentPage {
        let body: [String: Any] = [
            "officalType": 1,
            "keyword": "",
            "pageSize": pageSize,
            "currentPage": currentPage,
        ]
        let data = try await APIClient.shared.post("/api/expand/friendsCircle/v2/queryList", body: body)
        let posts = Self.extractPosts(from: data)
        let hasMore = posts.count >= pageSize
        logger.info("getOfficialMoments page=\(currentPage) got=\(posts.count) hasMore=\(hasMore)")
        return MomentPage(posts: posts, currentPage: currentPage, hasMore: hasMore)
    }

    /// 点赞 / 取消点赞。`optionType: 1=点赞, 0=取消`。
    /// trial #1 仅成功路径：接口 200 视为成功；失败回滚移 trial 后扩展项。
    func like(postId: Int, optionType: Int) async throws {
        let body: [String: Any] = ["id": postId, "optionType": optionType]
        _ = try await APIClient.shared.post("/api/expand/friendsCircle/like", body: body)
        logger.info("like postId=\(postId) optionType=\(optionType) ok")
    }

    /// 删除动态（对齐 H5 `api/circle/index.ts:12` `postDelete({ searchValue: id })`）。
    /// 200 视为成功；调用方（`MomentFeedStore.deletePost`）负责成功后本地移除 —— 对齐 H5 `.then(filter)`
    /// 悲观 UI 语义，避免请求失败时错删数据。
    func deletePost(postId: Int) async throws {
        let body: [String: Any] = ["searchValue": postId]
        _ = try await APIClient.shared.post("/api/expand/friendsCircle/del", body: body)
        logger.info("deletePost postId=\(postId) ok")
    }

    /// 拉某条 post 的评论列表（对齐 H5 `comments.vue` + `/api/expand/friendsCircle/getComments`）。
    ///
    /// H5 参数：`pageSize=100, currentPage=1, startTime=7天前, endTime=今天, keyword=postId`
    /// —— 即"只拉最近 7 天"。iOS 对齐此行为。
    func getComments(postId: Int, pageSize: Int = 100, currentPage: Int = 1) async throws -> [MomentComment] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let body: [String: Any] = [
            "pageSize": pageSize,
            "currentPage": currentPage,
            "startTime": formatter.string(from: weekAgo),
            "endTime": formatter.string(from: now),
            "keyword": postId,
        ]
        let data = try await APIClient.shared.post("/api/expand/friendsCircle/getComments", body: body)
        let comments = Self.extractComments(from: data)
        logger.info("getComments postId=\(postId, privacy: .public) got=\(comments.count, privacy: .public)")
        return comments
    }

    /// 复用 extractPosts 同款兼容多种容器结构。
    private static func extractComments(from data: Data) -> [MomentComment] {
        let decoder = JSONDecoder()
        // 顶层 array
        if let arr = try? decoder.decode([MomentComment].self, from: data) {
            return arr
        }
        // 兼容 wrapped { list / rows / data / items }
        if let wrapped = try? decoder.decode([String: [MomentComment]].self, from: data) {
            for key in ["list", "rows", "data", "items"] {
                if let list = wrapped[key] { return list }
            }
        }
        return []
    }

    /// 兼容多种容器：顶层数组 / .list / .rows / .data / .items 子键。
    private static func extractPosts(from data: Data) -> [MomentPost] {
        let decoder = JSONDecoder()

        // 路径 1: 顶层是 array (H5 moment.vue 直接 spread res 用法)
        do {
            return try decoder.decode([MomentPost].self, from: data)
        } catch {
            #if DEBUG
            logger.warning("extractPosts: 顶层 array decode 失败 \(String(describing: error))")
            #endif
        }

        // 路径 2: 顶层是 object，遍历兜底 keys
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            logger.warning("extractPosts: JSON 反序列化失败")
            return []
        }

        if let dict = obj as? [String: Any] {
            for key in ["list", "rows", "data", "items"] {
                if let arr = dict[key] as? [[String: Any]],
                   let raw = try? JSONSerialization.data(withJSONObject: arr),
                   let posts = try? decoder.decode([MomentPost].self, from: raw) {
                    return posts
                }
            }
            #if DEBUG
            logger.warning("extractPosts: 顶层 object keys=\(dict.keys.sorted().joined(separator: ","))")
            #endif
        } else if let arr = obj as? [[String: Any]] {
            // 顶层是 [[String: Any]] 但 MomentPost decode 失败 — 打印第 1 个 item 的字段名 + 类型让排查
            #if DEBUG
            if let first = arr.first {
                let schema = first.map { "\($0.key)=\(type(of: $0.value))" }.sorted().joined(separator: ",")
                logger.warning("extractPosts: 顶层 array 但 item decode 失败 schema=\(schema)")
            } else {
                logger.warning("extractPosts: 顶层 array 但为空")
            }
            #endif
        }

        logger.warning("extractPosts: 未找到 posts 数组")
        return []
    }
}

// MARK: - Static 便捷接口 (兼容现有 Profile 调用方)

extension CircleService {
    /// 转发到 `shared`，让现有 `CircleService.getMyMoments(...)` 调用方不必改。
    static func getMyMoments(userId: Int,
                             pageSize: Int = 20,
                             currentPage: Int) async throws -> MomentPage {
        try await shared.getMyMoments(userId: userId, pageSize: pageSize, currentPage: currentPage)
    }
}
