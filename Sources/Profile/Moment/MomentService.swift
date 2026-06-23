import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "MomentService")

/// 朋友圈/动态接口（对应 H5 `friendsCircle`，蓝本 08 §3.1 / 02-11 §2.1）。
enum MomentService {

    /// 拉取「我的」动态列表：`officalType=3` + `keyword=<userId>`。
    /// 与 H5 `apiGetQueryList` 同源（src/api/circle）。
    static func getMyMoments(userId: Int,
                             pageSize: Int = 20,
                             currentPage: Int) async throws -> MomentPage {
        let body: [String: Any] = [
            "officalType": 3,
            "keyword": "\(userId)",
            "pageSize": pageSize,
            "currentPage": currentPage,
        ]
        let data = try await APIClient.shared.post("/api/friendsCircle/v2/queryList", body: body)

        let posts = Self.extractPosts(from: data)
        let hasMore = posts.count >= pageSize
        logger.info("getMyMoments userId=\(userId) page=\(currentPage) gotPosts=\(posts.count) hasMore=\(hasMore)")
        return MomentPage(posts: posts, currentPage: currentPage, hasMore: hasMore)
    }

    /// 兼容多种容器：顶层数组 / .list / .rows / .data / .items 子键。
    private static func extractPosts(from data: Data) -> [MomentPost] {
        if let array = try? JSONDecoder().decode([MomentPost].self, from: data) {
            return array
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let decoder = JSONDecoder()

        if let dict = obj as? [String: Any] {
            for key in ["list", "rows", "data", "items"] {
                if let arr = dict[key] as? [[String: Any]],
                   let raw = try? JSONSerialization.data(withJSONObject: arr),
                   let posts = try? decoder.decode([MomentPost].self, from: raw) {
                    return posts
                }
            }
        }
        logger.warning("extractPosts: 未找到 posts 数组")
        return []
    }
}
