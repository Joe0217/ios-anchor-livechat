import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "UserProfileService")

/// 用户详情数据层（spec §2.1）。
///
/// **step 1c 真实现**：getUserDetail / followUser / blockUser 三接口对齐 H5。
/// 5 路 decode fallback 抽到 `decodeDetail(from:)` static，单测直测（参 BlocklistService 模式）。
final class UserProfileService: UserProfileServiceProtocol {

    static let shared = UserProfileService()

    private init() {}

    /// 拉取用户详情（spec §1.1 + §2.1）。
    func fetchDetail(userId: Int) async throws -> UserDetail {
        let body: [String: Any] = ["userId": userId]
        let data = try await APIClient.shared.post("/api/index/getUserDetail", body: body)
        guard let detail = Self.decodeDetail(from: data) else {
            throw APIError(code: "decode", message: "Failed to decode user detail")
        }
        logger.info("fetchDetail uid=\(userId, privacy: .private) ok")
        return detail
    }

    /// 关注 / 取关（spec §2.1，trial #3 step 3 真机反悔 #2 修订）。
    /// **字段名 `followUserId` + `followType`**（H5 type.ts:58 FollowUserOpt 真契约）。
    ///
    /// **v16 全局 toast**（对齐 H5 `stores/modules/user.js followOrNo` L355-359）：
    /// followType=1 → 弹"关注成功"；followType=2 → 弹"取消关注成功"。
    func follow(request: FollowUserRequest) async throws {
        let body: [String: Any] = [
            "followUserId": request.followUserId,
            "followType": request.followType
        ]
        _ = try await APIClient.shared.post("/api/user/followUser", body: body)
        logger.info("follow uid=\(request.followUserId, privacy: .private) followType=\(request.followType) ok")
        // 全局 toast —— 与 H5 `followOrNo` 语义一致：1/2 弹，其他（3=拉黑）不弹
        if request.followType == 1 || request.followType == 2 {
            await MainActor.run {
                AppToastCenter.shared.show(
                    request.followType == 1 ? L10n.commonFollowSuccess : L10n.commonUnfollowSuccess
                )
            }
        }
    }

    /// 拉黑（spec §1.5 / §2.1）。**含 isLive 字段，与 BlocklistService.removeBlock 不同 body**。
    func block(request: BlockUserRequest) async throws {
        let body: [String: Any] = [
            "userId": request.userId,
            "type": request.type,
            "yxAccid": request.yxAccid,
            "isLive": request.isLive
        ]
        _ = try await APIClient.shared.post("/api/user/blockUser", body: body)
        logger.info("block uid=\(request.userId, privacy: .private) isLive=\(request.isLive) ok")
    }

    // MARK: - Decode 5 路 fallback（spec §2.3 / R-2）

    /// 解 envelope `result` 字段为 `UserDetail?`。
    ///
    /// 5 路 fallback：
    /// 1. `"null"` 字面量 → nil（APIClient 在 result=null 时返回 Data("null".utf8)）
    /// 2. 顶层是含 `userId` 的字典 → 直接 parse
    /// 3. 顶层是字典且含 `data/result/profile/user` 任一 wrapped key → 取内层 parse
    /// 4. 顶层字典无识别 key → nil + warn（让 step 3 真集成暴露）
    /// 5. 非 JSON → nil + error
    ///
    /// `userId` **严格 String fail-loud**（与 BlocklistItem 对齐，red team #1 落地的契约纪律）。
    static func decodeDetail(from data: Data) -> UserDetail? {
        // 1. null 字面量
        if String(data: data, encoding: .utf8) == "null" {
            return nil
        }

        // 2/3. 用 JSONSerialization 拿到 dict（避开 Codable 自动机制——thumbs 派生需要手解）
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            // 5. 非 JSON
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            logger.error("decodeDetail: cannot parse, preview=\(preview, privacy: .private)")
            return nil
        }

        guard let topDict = obj as? [String: Any] else {
            logger.warning("decodeDetail: top-level is not dict")
            return nil
        }

        // 顶层含 userId → 直接 parse（路径 2）
        if topDict["userId"] != nil {
            return parseDetail(from: topDict)
        }

        // 顶层 wrapped key（路径 3）
        for key in ["data", "result", "profile", "user"] {
            if let inner = topDict[key] as? [String: Any] {
                logger.info("decodeDetail matched wrapped key=\(key)")
                return parseDetail(from: inner)
            }
        }

        // 路径 4：无识别 key
        logger.warning("decodeDetail: dict without userId/data/result/profile/user, keys=\(topDict.keys.sorted().joined(separator: ","))")
        return nil
    }

    /// 从 dict 解析 UserDetail。
    ///
    /// **userId 兼容 String/Int**（spec v3 修订，trial #3 step 3 真机反悔 #1）：
    /// H5 `type.ts:139` 声明 `userId: string` 不是接口真契约——实际后端返 `__NSCFNumber`（如 1000001877）。
    /// 不参 H5 TypeScript 类型声明，按运行时实际类型解 + 兼容 String/Int（同 LiveListAnchor 模式）。
    /// 详见 `.claude/rules/ios-decode-userid-compat.md`。
    static func parseDetail(from dict: [String: Any]) -> UserDetail? {
        var userIdStr: String?
        if let s = dict["userId"] as? String, !s.isEmpty {
            userIdStr = s
        } else if let n = dict["userId"] as? NSNumber {
            // 排除 Bool 桥接（trial #3 step 1c 教训：NSNumber 含 Bool/Int 两态）
            let cType = String(cString: n.objCType)
            if cType != "c" && cType != "B" {
                userIdStr = n.stringValue
            }
        }
        guard let userId = userIdStr, !userId.isEmpty else {
            // P2-17：userId 是 PII，privacy:.private 防 release 日志泄漏
            logger.warning("parseDetail: userId missing or invalid, raw=\(String(describing: dict["userId"]), privacy: .private)")
            return nil
        }

        let nickname = dict["nickname"] as? String ?? ""
        let icon = dict["icon"] as? String
        let gender = dict["gender"] as? Int
        let age = dict["age"] as? Int
        let countryId = dict["countryId"] as? String
        let yxAccid = dict["yxAccid"] as? String
        // followed 严格 Bool（spec §1.2 v2 修正 + red team #1）；缺失 / 类型偏移 → false 兜底（R-21）。
        // **注意**：Foundation JSON 把 `1/0` 桥接成 NSNumber，再 `as? Bool` 会被解为 true/false。
        // 必须用 objCType 区分真 Bool（"c"/"B"）vs Int（"i"/"q"），否则 H5 followFlag bug 行为会被错收。
        let followed: Bool = {
            guard let raw = dict["followed"] as? NSNumber else { return false }
            let cType = String(cString: raw.objCType)
            return (cType == "c" || cType == "B") ? raw.boolValue : false
        }()
        // isBlocked Int? 三态（nil / 0 / 1）—— R-22
        let isBlocked = dict["isBlocked"] as? Int

        // connRate H5 类型不稳：可能 String 也可能 number（spec §2.2 宽松收 String）
        var connRate: String?
        if let s = dict["connRate"] as? String {
            connRate = s
        } else if let n = dict["connRate"] as? Int {
            connRate = String(n)
        } else if let n = dict["connRate"] as? Double {
            connRate = String(n)
        }

        // thumbs 解析（spec §2.3 + R-4）：thumbs[0].num → like / thumbs[1].num → favorite
        // 缺失 / 非数组 / 元素非 dict / num 非 Int → 0 兜底
        var like = 0
        var favorite = 0
        if let thumbs = dict["thumbs"] as? [[String: Any]] {
            if thumbs.indices.contains(0), let n = thumbs[0]["num"] as? Int {
                like = n
            }
            if thumbs.indices.contains(1), let n = thumbs[1]["num"] as? Int {
                favorite = n
            }
        }

        // giftList 解析（trial #3 step 3 反悔 #7）。H5 type.ts 仅声明 {giftId, num}，
        // 模板用 giftImg || icon / giftName / giftCount || num —— 两套字段名都兜底
        var giftList: [Gift] = []
        if let rawList = dict["giftList"] as? [[String: Any]] {
            giftList = rawList.compactMap(parseGift(from:))
        }
        let guardianList = GuardianResponseAdapter.profileGuardians(from: dict["guardianList"])

        return UserDetail(
            userId: userId,
            nickname: nickname,
            icon: icon,
            gender: gender,
            age: age,
            countryId: countryId,
            connRate: connRate,
            yxAccid: yxAccid,
            followed: followed,
            isBlocked: isBlocked,
            like: like,
            favorite: favorite,
            giftList: giftList,
            guardianList: guardianList
        )
    }

    /// 解析单个礼物（H5 模板 `giftImg || icon` / `giftName` / `giftCount || num` 兼容）。
    static func parseGift(from dict: [String: Any]) -> Gift? {
        // giftId 必填（类比 userId fail-loud），支持 String/Int 同款兼容
        var giftId: Int?
        if let n = dict["giftId"] as? Int {
            giftId = n
        } else if let s = dict["giftId"] as? String, let n = Int(s) {
            giftId = n
        }
        guard let giftId = giftId else { return nil }

        // icon URL：giftImg 优先 → icon fallback
        let iconUrl = (dict["giftImg"] as? String) ?? (dict["icon"] as? String)
        // 名称：giftName
        let name = dict["giftName"] as? String
        // 数量：giftCount 优先 → num fallback
        let count = (dict["giftCount"] as? Int) ?? (dict["num"] as? Int) ?? 0

        return Gift(giftId: giftId, iconUrl: iconUrl, name: name, count: count)
    }
}

/// 保留 enum 给 Preview 用（生产代码不再 throw）。
enum UserProfileServiceError: Error, LocalizedError {
    case stubNotImplemented
    var errorDescription: String? { "UserProfileService: preview-only stub error" }
}
