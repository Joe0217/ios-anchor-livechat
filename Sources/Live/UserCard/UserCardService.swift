import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "UserCardService")

/// UserCard 数据源 protocol。
///
/// **真 API 契约**(对齐 H5 `userCard.vue` L87 + `api/user/index.ts`):
/// - fetch: `POST /api/user/getAnchorPersonalCard` body `{searchValue: userId}` → UserCardInfo
/// - follow/unfollow: 复用 `UserProfileService.shared.follow`(内自带 AppToast + notification)
///
/// **block/unblock 不走本 protocol**:blockUser 需 `isLive` 派生 + yxAccid,
/// removeBlock 需 yxAccid — 直接由 `UserCardStore` 调 `UserProfileService.shared.block`
/// / `BlocklistService.shared.removeBlock`,protocol 保持简单单参 signature。
protocol UserCardServiceProtocol {
    func fetch(userId: String) async throws -> UserCardInfo
    func follow(userId: String) async throws
    func unfollow(userId: String) async throws
}

// MARK: - Real 实现

/// 生产实现。fetch 走真接口 + 5 路 decode fallback;follow/unfollow 委托 UserProfileService。
struct UserCardServiceReal: UserCardServiceProtocol {

    func fetch(userId: String) async throws -> UserCardInfo {
        let body: [String: Any] = ["searchValue": userId]
        let data = try await APIClient.shared.post("/api/user/getAnchorPersonalCard", body: body)
        guard let info = Self.decodeCard(from: data) else {
            throw APIError(code: "decode", message: "Failed to decode user card")
        }
        logger.info("fetch uid=\(userId, privacy: .private) ok userType=\(info.userType)")
        return info
    }

    func follow(userId: String) async throws {
        guard let uid = Int(userId) else {
            throw APIError(code: "invalid_uid", message: "userId not Int")
        }
        try await UserProfileService.shared.follow(request: FollowUserRequest(followUserId: uid, followType: 1))
    }

    func unfollow(userId: String) async throws {
        guard let uid = Int(userId) else {
            throw APIError(code: "invalid_uid", message: "userId not Int")
        }
        try await UserProfileService.shared.follow(request: FollowUserRequest(followUserId: uid, followType: 2))
    }

    // MARK: - Decode(参 UserProfileService.decodeDetail 模板 + agent-recon-field-names-unverified rule)

    /// 5 路 fallback:
    /// 1. `"null"` 字面量 → nil
    /// 2. 顶层字典含 userId → 直接 parse
    /// 3. 顶层字典 wrapped in data/result/profile/user → 取内层
    /// 4. 顶层字典无识别 key → nil + warn
    /// 5. 非 JSON → nil + error(带 preview,PII private)
    ///
    /// **真机首拉必看 log**:grep `[UserCardService] raw=` 对齐字段名。
    /// 字段名从 H5 template 反推,可能不对齐真契约。
    static func decodeCard(from data: Data) -> UserCardInfo? {
        // 1. null
        if String(data: data, encoding: .utf8) == "null" { return nil }

        // 2/3. dict 提取
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            logger.error("decodeCard: cannot parse, preview=\(preview, privacy: .private)")
            return nil
        }
        guard let topDict = obj as? [String: Any] else {
            logger.warning("decodeCard: top-level not dict")
            return nil
        }

        if topDict["userId"] != nil || topDict["searchValue"] != nil {
            return parseCard(from: topDict)
        }

        for key in ["data", "result", "profile", "user"] {
            if let inner = topDict[key] as? [String: Any] {
                logger.info("decodeCard matched wrapped key=\(key)")
                return parseCard(from: inner)
            }
        }

        logger.warning("decodeCard: dict without userId, keys=\(topDict.keys.sorted().joined(separator: ","))")
        return nil
    }

    /// 从 dict 解析 UserCardInfo。字段名多路 alias(agent 从 H5 template 反推)。
    ///
    /// **userId 兼容 String/Int**(参 ios-decode-userid-compat.md + UserProfileService.parseDetail)
    static func parseCard(from dict: [String: Any]) -> UserCardInfo? {
        // userId(String/Int 双兼容,排除 Bool 桥接)
        var userIdStr: String?
        if let s = dict["userId"] as? String, !s.isEmpty {
            userIdStr = s
        } else if let n = dict["userId"] as? NSNumber {
            let cType = String(cString: n.objCType)
            if cType != "c" && cType != "B" { userIdStr = n.stringValue }
        }
        guard let userId = userIdStr, !userId.isEmpty else {
            logger.warning("parseCard: userId missing raw=\(String(describing: dict["userId"]), privacy: .private)")
            return nil
        }

        let userType = (dict["userType"] as? Int) ?? 1  // 缺失兜底 1=用户
        // H5 template 两种命名都用(userCard.vue L312 用 `nickName || nickname`)
        let nickname = (dict["nickname"] as? String)
                    ?? (dict["nickName"] as? String) ?? ""
        // 头像:H5 template `initData.userAvatar || giftData.icon`,后端字段主 `icon`
        let avatarUrl = (dict["icon"] as? String) ?? (dict["userIcon"] as? String)
        // 头饰:H5 <head-frame :user-data="giftData">,常见字段 `headwear` / `headFrame` / `headwearUrl`
        let headwearUrl = (dict["headwear"] as? String)
                       ?? (dict["headFrame"] as? String)
                       ?? (dict["headwearUrl"] as? String)
        let yxAccid = dict["yxAccid"] as? String

        // Gender:H5 template `isAnchor` 时用 female webp,否则 male webp — 我们不管这个,
        // 只解 gender 数字段(1=男/2=女/其他=unknown)
        let genderInt = dict["gender"] as? Int
        let gender: UserCardInfo.Gender = {
            switch genderInt {
            case 1: return .male
            case 2: return .female
            default: return .unknown
            }
        }()

        let age = dict["age"] as? Int
        // countryCode → emoji(复用 AnchorInfoStore.flagEmoji)
        let countryCode = dict["country"] as? String
        let countryEmoji: String? = {
            guard let c = countryCode, !c.isEmpty else { return nil }
            let emoji = AnchorInfoStore.flagEmoji(from: c)
            return emoji == "🌐" ? nil : emoji  // 未知国家 flag 不显示
        }()

        // level / levelName(H5 template `levelName` 数字或字符串;后端字段名可能是 `userLevel` / `level`)
        let level: Int = (dict["level"] as? Int)
                      ?? (dict["userLevel"] as? Int)
                      ?? {
                          // 兜底解 String 转 Int(如 "12")
                          if let s = (dict["userLevel"] as? String) ?? (dict["levelName"] as? String),
                             let n = Int(s) { return n }
                          return 0
                      }()
        let levelName: String? = (dict["levelName"] as? String) ?? {
            if let n = dict["levelName"] as? Int { return String(n) }
            return nil
        }()

        // VIP:H5 template `giftData.vip` bool
        let isVip: Bool = {
            if let b = dict["vip"] as? Bool { return b }
            if let n = dict["vip"] as? NSNumber {
                let cType = String(cString: n.objCType)
                if cType == "c" || cType == "B" { return n.boolValue }
                return n.intValue != 0  // Int(1/0) 兜底
            }
            return false
        }()

        let followerCount = (dict["fans"] as? Int) ?? (dict["followerCount"] as? Int) ?? 0
        let followingCount = (dict["follow"] as? Int) ?? (dict["followingCount"] as? Int) ?? 0
        let liveWelcome = (dict["liveWelcome"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // medals(H5 [{medalImageUrl}])
        var medals: [Medal] = []
        if let rawMedals = dict["medals"] as? [[String: Any]] {
            for (idx, m) in rawMedals.enumerated() {
                let img = (m["medalImageUrl"] as? String)
                       ?? (m["imageUrl"] as? String)
                       ?? (m["img"] as? String)
                medals.append(Medal(id: "medal-\(idx)", imageUrl: img))
            }
        }

        // giftWalls(H5 [{giftId, giftImg, giftName, giftCount}])
        var giftWalls: [GiftWallItem] = []
        if let rawGifts = dict["giftWalls"] as? [[String: Any]] {
            for g in rawGifts {
                var gid: String?
                if let s = g["giftId"] as? String, !s.isEmpty { gid = s }
                else if let n = g["giftId"] as? NSNumber { gid = n.stringValue }
                guard let giftId = gid else { continue }

                let iconUrl = (g["giftImg"] as? String) ?? (g["icon"] as? String)
                let name = g["giftName"] as? String
                let count = (g["giftCount"] as? Int) ?? (g["num"] as? Int) ?? 0
                giftWalls.append(GiftWallItem(id: giftId, iconUrl: iconUrl, name: name, count: count))
            }
        }

        // isBlocked / isFollowed:后端可能返 Bool 或 Int(1/0)
        let isBlocked: Bool = decodeBoolOrInt(dict["isBlocked"])
        let isFollowed: Bool = decodeBoolOrInt(dict["isFollow"]) || decodeBoolOrInt(dict["isFollowed"])

        // activeTycoon:H5 全项目透传 `activeTycoon` bool 字段(userCard.vue、messageScroller.vue、userWeeklyRank.vue);
        // 后端在 getAnchorPersonalCard 响应是否返回未真机验证 → fallback false(UI 无 badge、不 crash)。
        // 待真机 log:UserCardService raw= 抓一次 dump 后校对字段名。
        let isActiveTycoon: Bool = decodeBoolOrInt(dict["activeTycoon"])

        return UserCardInfo(
            userId: userId,
            userType: userType,
            nickname: nickname,
            avatarUrl: avatarUrl,
            headwearUrl: headwearUrl,
            yxAccid: yxAccid,
            gender: gender,
            age: age,
            countryEmoji: countryEmoji,
            level: level,
            levelName: levelName,
            isVip: isVip,
            followerCount: followerCount,
            followingCount: followingCount,
            liveWelcome: liveWelcome,
            medals: medals,
            giftWalls: giftWalls,
            isBlocked: isBlocked,
            isFollowed: isFollowed,
            isActiveTycoon: isActiveTycoon
        )
    }

    /// Bool 或 Int(0/1) 双兼容(NSNumber objCType 严判,防 Foundation 桥接把 Int 1 误判为 Bool)
    private static func decodeBoolOrInt(_ raw: Any?) -> Bool {
        guard let raw = raw else { return false }
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber {
            let cType = String(cString: n.objCType)
            if cType == "c" || cType == "B" { return n.boolValue }
            return n.intValue != 0
        }
        return false
    }
}

// MARK: - Fakes 实现(Preview / 单测用)

struct UserCardServiceFakes: UserCardServiceProtocol {
    var mockInfo: UserCardInfo? = nil

    func fetch(userId: String) async throws -> UserCardInfo {
        try await Task.sleep(for: .milliseconds(200))
        if let m = mockInfo { return m }
        return UserCardInfo(
            userId: userId,
            userType: 1,
            nickname: "User_\(userId)",
            avatarUrl: nil,
            headwearUrl: nil,
            yxAccid: "yx_\(userId)",
            gender: .female,
            age: 24,
            countryEmoji: "🇨🇳",
            level: 12,
            levelName: "12",
            isVip: true,
            followerCount: 1234,
            followingCount: 56,
            liveWelcome: "Welcome to my room!",
            medals: [
                Medal(id: "medal-0", imageUrl: nil),
                Medal(id: "medal-1", imageUrl: nil),
            ],
            giftWalls: [
                GiftWallItem(id: "g1", iconUrl: nil, name: "Rose", count: 12),
                GiftWallItem(id: "g2", iconUrl: nil, name: "Heart", count: 8),
                GiftWallItem(id: "g3", iconUrl: nil, name: "Kiss", count: 5),
                GiftWallItem(id: "g4", iconUrl: nil, name: "Star", count: 3),
            ],
            isBlocked: false,
            isFollowed: false,
            isActiveTycoon: false
        )
    }

    func follow(userId: String) async throws {
        try await Task.sleep(for: .milliseconds(100))
    }
    func unfollow(userId: String) async throws {
        try await Task.sleep(for: .milliseconds(100))
    }
}
