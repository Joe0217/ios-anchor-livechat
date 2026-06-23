import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "FollowListService")

/// 关注 / 粉丝 / 朋友 列表接口（对应 H5 `apiGetFriendList`）。
/// 接口：`POST /api/user/v2/userFriend`，参数 `{type, pageSize, currentPage}`（蓝本 08 §3.2）。
enum FollowListService {

    /// 关注 / 取关 / 拉黑：`/api/user/followUser`（蓝本 02-11 §2.2 / 08 §3.2）。
    /// `followType`：1=关注 / 2=取关 / 3=拉黑（与 H5/安卓对齐）。
    /// 接口本身仅校验后端状态，不返回业务数据；非 0000 由 APIClient 抛 APIError。
    static func followUser(followUserId: Int, followType: Int) async throws {
        let body: [String: Any] = [
            "followUserId": followUserId,
            "followType": followType,
        ]
        _ = try await APIClient.shared.post("/api/user/followUser", body: body)
        logger.info("followUser uid=\(followUserId) type=\(followType) ok")
    }

    /// 单页拉取。返回 (users, hasMore)；hasMore 判定：返回数组长度 < pageSize。
    /// 接口实际响应字段未明确（蓝本仅列入参），用 raw JSON 兜底兼容多种形态：
    /// - `result` 为数组 → 直接取数组
    /// - `result.list` 数组 → 取 .list
    /// - `result.rows` 数组 → 取 .rows
    static func getUserFriend(type: Int,
                              pageSize: Int = 20,
                              currentPage: Int) async throws -> FollowListPage {
        let body: [String: Any] = [
            "type": type,
            "pageSize": pageSize,
            "currentPage": currentPage,
        ]
        let data = try await APIClient.shared.post("/api/user/v2/userFriend", body: body)

        // 兼容多种容器形态
        let users: [FollowUser]
        if let array = try? JSONDecoder().decode([FollowUser].self, from: data) {
            users = array
        } else if let wrapped = try? JSONDecoder().decode([String: [FollowUser]].self, from: data),
                  let list = wrapped["list"] ?? wrapped["rows"] ?? wrapped["data"] {
            users = list
        } else {
            // 兜底解析：先做 JSON 字典再手动取容器
            let obj = try JSONSerialization.jsonObject(with: data)
            users = Self.extractUsers(from: obj)
        }

        let hasMore = users.count >= pageSize
        logger.info("getUserFriend type=\(type) page=\(currentPage) gotUsers=\(users.count) hasMore=\(hasMore)")
        return FollowListPage(users: users, currentPage: currentPage, hasMore: hasMore)
    }

    /// 从未知容器形态的 JSON 对象里抽取 `[FollowUser]`：
    /// 顶层是数组 → 直接解；顶层是字典 → 找 list/rows/data 子键再解。
    /// 找不到合理位置则返回空数组（不抛错），由调用方按"空页"处理。
    private static func extractUsers(from obj: Any) -> [FollowUser] {
        let decoder = JSONDecoder()

        if let arr = obj as? [[String: Any]] {
            guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
            return (try? decoder.decode([FollowUser].self, from: data)) ?? []
        }

        if let dict = obj as? [String: Any] {
            for key in ["list", "rows", "data", "items"] {
                if let arr = dict[key] as? [[String: Any]],
                   let data = try? JSONSerialization.data(withJSONObject: arr),
                   let users = try? decoder.decode([FollowUser].self, from: data) {
                    return users
                }
            }
        }

        logger.warning("extractUsers: 未在响应中找到用户数组")
        return []
    }
}
