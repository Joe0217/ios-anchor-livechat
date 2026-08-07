import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "FollowListService")

/// 关注 / 粉丝 / 朋友 列表接口（对应 H5 `apiGetFriendList`）。
/// 接口：`POST /api/user/v2/userFriend`，参数 `{type, pageSize, currentPage}`（蓝本 08 §3.2）。
enum FollowListService {

    /// 关注 / 取关 / 拉黑：`/api/user/followUser`（蓝本 02-11 §2.2 / 08 §3.2）。
    /// `followType`：1=关注 / 2=取关 / 3=拉黑（与 H5/安卓对齐）。
    /// 接口本身仅校验后端状态,不返回业务数据；非 0000 由 APIClient 抛 APIError。
    ///
    /// **v16 全局 toast**（对齐 H5 `stores/modules/user.js followOrNo` L355-359）：
    /// followType=1 → 弹"关注成功"；followType=2 → 弹"取消关注成功"；
    /// followType=3 拉黑 → 不弹 follow toast（拉黑另有独立提示）。
    static func followUser(followUserId: Int, followType: Int) async throws {
        let body: [String: Any] = [
            "followUserId": followUserId,
            "followType": followType,
        ]
        _ = try await APIClient.shared.post("/api/user/followUser", body: body)
        logger.info("followUser uid=\(followUserId) type=\(followType) ok")
        // 全局 toast —— 与 H5 `followOrNo` 语义一致：1 关注 / 2 取关成功后统一弹
        if followType == 1 || followType == 2 {
            await MainActor.run {
                AppToastCenter.shared.show(
                    followType == 1 ? L10n.commonFollowSuccess : L10n.commonUnfollowSuccess
                )
            }
        }
    }

    /// 单页拉取。H5 实际读取 `result.friendData`；同时兼容历史数组容器。
    static func getUserFriend(type: Int,
                              pageSize: Int = 20,
                              currentPage: Int) async throws -> FollowListPage {
        let body: [String: Any] = [
            "type": type,
            "pageSize": pageSize,
            "currentPage": currentPage,
        ]
        let data = try await APIClient.shared.post("/api/user/v2/userFriend", body: body)

        let users = try decodeUsers(from: data)

        let hasMore = users.count >= pageSize
        logger.info("getUserFriend type=\(type) page=\(currentPage) gotUsers=\(users.count) hasMore=\(hasMore)")
        return FollowListPage(users: users, currentPage: currentPage, hasMore: hasMore)
    }

    /// 解码接口数据。找不到列表容器时抛错，避免把契约错误伪装成“暂无用户”。
    static func decodeUsers(from data: Data) throws -> [FollowUser] {
        let decoder = JSONDecoder()

        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let items = findUserItems(in: object) else {
            logger.error("decodeUsers: response has no supported user array")
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "userFriend response has no supported user array")
            )
        }

        var users: [FollowUser] = []
        var firstDecodeError: Error?
        var skippedCount = 0
        users.reserveCapacity(items.count)

        // 单条脏数据不能拖垮整页；但整页均不可解时仍 fail-loud，避免伪装成空列表。
        for item in items {
            guard JSONSerialization.isValidJSONObject(item) else {
                skippedCount += 1
                continue
            }
            do {
                let itemData = try JSONSerialization.data(withJSONObject: item)
                users.append(try decoder.decode(FollowUser.self, from: itemData))
            } catch {
                firstDecodeError = firstDecodeError ?? error
                skippedCount += 1
            }
        }

        if users.isEmpty, !items.isEmpty, let firstDecodeError {
            throw firstDecodeError
        }
        if users.isEmpty, !items.isEmpty, skippedCount == items.count {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "userFriend array contains no user objects")
            )
        }
        if skippedCount > 0 {
            logger.notice("decodeUsers skipped malformedItems=\(skippedCount) decodedUsers=\(users.count)")
        }
        return users
    }

    /// 支持接口直返数组、`friendData` 契约，以及历史分页/网关包装层。
    private static func findUserItems(in object: Any) -> [Any]? {
        if object is NSNull { return [] }
        if let items = object as? [Any] { return items }
        guard let dictionary = object as? [String: Any] else { return nil }

        var sawNullList = false
        for key in ["friendData", "list", "records", "rows", "items"] {
            guard let nested = dictionary[key] else { continue }
            if nested is NSNull {
                sawNullList = true
            } else if let items = nested as? [Any] {
                return items
            }
        }

        for key in ["data", "result", "content", "page"] {
            guard let nested = dictionary[key] else { continue }
            if let items = findUserItems(in: nested) { return items }
        }
        return sawNullList ? [] : nil
    }
}
