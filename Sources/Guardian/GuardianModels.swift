import Foundation

/// 主播守护等级。服务端数值越大等级越高，界面固定按金、银、铜展示。
enum GuardianLevel: Int, CaseIterable, Identifiable {
    case bronze = 1
    case silver = 2
    case gold = 3

    var id: Int { rawValue }

    static let displayOrder: [GuardianLevel] = [.gold, .silver, .bronze]

    static func decoded(_ rawValue: Int?) -> GuardianLevel {
        guard let rawValue, let level = GuardianLevel(rawValue: rawValue) else {
            return .bronze
        }
        return level
    }
}

/// 守护详情固定展示的七项权益。后端只下发部分开关，未知时使用 H5 的等级矩阵兜底。
enum GuardianPrivilege: String, CaseIterable, Identifiable {
    case badge
    case frame
    case chat
    case notice
    case highlight
    case mount
    case gift

    var id: String { rawValue }

    static func fallbackAvailability(for level: GuardianLevel) -> Set<GuardianPrivilege> {
        switch level {
        case .gold:
            return Set(allCases)
        case .silver, .bronze:
            return [.badge, .frame, .chat, .highlight, .notice]
        }
    }
}

struct GuardianPrice: Equatable, Identifiable {
    let durationDays: Int
    let price: Int64?
    let originalPrice: Int64?
    let discountPercent: Int?
    let isHot: Bool

    var id: Int { durationDays }
}

struct GuardianReward: Equatable {
    let type: String
    let staticImageURL: String?
    let dynamicImageURL: String?
    let sort: Int
}

struct GuardianLevelConfiguration: Equatable, Identifiable {
    let level: GuardianLevel
    let levelName: String?
    let prices: [GuardianPrice]
    let availablePrivileges: Set<GuardianPrivilege>
    let rewards: [GuardianReward]

    var id: GuardianLevel { level }

    func price(for durationDays: Int) -> GuardianPrice? {
        prices.first { $0.durationDays == durationDays }
    }

    func reward(for privilege: GuardianPrivilege) -> GuardianReward? {
        let rewardType: String?
        switch privilege {
        case .badge: rewardType = "medal"
        case .frame: rewardType = "avatarFrame"
        case .chat: rewardType = "chatBubble"
        case .mount: rewardType = "mount"
        case .highlight, .notice, .gift: rewardType = nil
        }
        guard let rewardType else { return nil }
        return rewards.first { $0.type == rewardType }
    }
}

struct GuardianTopUser: Equatable {
    let userId: String?
    let nickname: String?
    let avatarURL: String?
    let level: GuardianLevel?
}

struct GuardianListItem: Equatable, Identifiable {
    let id: String
    let nickname: String
    let avatarURL: String?
    let level: GuardianLevel
    let remainingDays: Int
    let userLevel: Int?
    let gender: Int?
    let age: Int?
    let isVIP: Bool
}

/// 用户资料接口内嵌的“该用户守护的主播”条目。H5 只展示前 3 个，空数组时整卡隐藏。
struct UserGuardianAnchor: Equatable, Identifiable {
    let anchorId: String
    let nickname: String
    let iconURL: String?

    var id: String { anchorId }
}

struct GuardianPanel: Equatable {
    let anchorId: Int64
    var levels: [GuardianLevelConfiguration]
    var topGuardian: GuardianTopUser?
    let topAvatarURLs: [String]
    let guardianCount: Int

    static func fallback(anchorId: Int64) -> GuardianPanel {
        GuardianPanel(
            anchorId: anchorId,
            levels: GuardianLevel.displayOrder.map {
                GuardianLevelConfiguration(
                    level: $0,
                    levelName: nil,
                    prices: [],
                    availablePrivileges: GuardianPrivilege.fallbackAvailability(for: $0),
                    rewards: []
                )
            },
            topGuardian: nil,
            topAvatarURLs: [],
            guardianCount: 0
        )
    }

    func configuration(for level: GuardianLevel) -> GuardianLevelConfiguration {
        levels.first { $0.level == level }
            ?? GuardianLevelConfiguration(
                level: level,
                levelName: nil,
                prices: [],
                availablePrivileges: GuardianPrivilege.fallbackAvailability(for: level),
                rewards: []
            )
    }
}

struct GuardianListPage: Equatable {
    let items: [GuardianListItem]
    let total: Int
    let page: Int
    let pageSize: Int
    let hasMore: Bool
}

// MARK: - H5 raw VO adapter

/// `guardian` 服务的真实 VO 长期存在数字/字符串混发和字段迁移。
/// 这里按 H5 `adapter.ts` 集中适配，页面与 Store 只消费稳定模型。
enum GuardianResponseAdapter {
    static func panel(from data: Data, requestedAnchorId: Int64) throws -> GuardianPanel {
        guard let root = try object(from: data) else {
            // H5 adapter 明确将 `panel: null` 适配为可用的空面板，而不是错误页。
            return GuardianPanel.fallback(anchorId: requestedAnchorId)
        }
        let rawAnchorId = int64(root["anchorId"]) ?? requestedAnchorId
        let levels = array(root["levels"]).compactMap(adaptLevel)
        let topGuardian = adaptTopGuardian(root)
        let topAvatarURLs = array(root["top3Avatars"]).compactMap(string)
        let guardianCount = max(0, int(root["guardianCount"]) ?? 0)

        return GuardianPanel(
            anchorId: rawAnchorId,
            levels: levels.isEmpty ? GuardianPanel.fallback(anchorId: rawAnchorId).levels : levels,
            topGuardian: topGuardian,
            topAvatarURLs: topAvatarURLs,
            guardianCount: guardianCount
        )
    }

    static func list(from data: Data, page: Int, pageSize: Int) throws -> GuardianListPage {
        let root = try object(from: data) ?? [:]
        let rawItems = array(root["list"])
        let items = rawItems.compactMap(adaptListItem)
        let total = max(rawItems.count, int(root["total"]) ?? rawItems.count)
        // H5 adapter 不消费 `hasMore`，而是以本页原始条数和 `total` 判定分页。
        // 这样后端在 total 尚未同步时给出陈旧 hasMore=false 也不会截断守护榜。
        let hasMore = rawItems.count >= pageSize && page * pageSize < total

        return GuardianListPage(
            items: items,
            total: total,
            page: page,
            pageSize: pageSize,
            hasMore: hasMore
        )
    }

    /// H5 `getUserDetail.guardianList` 的前 3 个主播。不复用 guardian/list，避免多一次请求和竞态。
    static func profileGuardians(from value: Any?) -> [UserGuardianAnchor] {
        array(value).compactMap { value in
            guard let raw = dictionary(value),
                  let anchorId = string(raw["anchorId"]), !anchorId.isEmpty else { return nil }
            return UserGuardianAnchor(
                anchorId: anchorId,
                nickname: string(raw["anchorNickname"]) ?? "",
                iconURL: string(raw["anchorIcon"])
            )
        }
    }

    private static func adaptLevel(_ value: Any) -> GuardianLevelConfiguration? {
        guard let raw = dictionary(value) else { return nil }
        let privilege = dictionary(raw["levelPrivilege"]) ?? [:]
        guard let rawLevel = int(privilege["levelCode"]) ?? int(raw["levelCode"]),
              let level = GuardianLevel(rawValue: rawLevel) else {
            return nil
        }
        let rewards = array(privilege["rewards"])
            .compactMap(adaptReward)
            .sorted { $0.sort < $1.sort }

        let rewardTypes = Set(rewards.map(\.type))
        var availability = Set<GuardianPrivilege>()
        if rewardTypes.contains("medal") { availability.insert(.badge) }
        if rewardTypes.contains("avatarFrame") { availability.insert(.frame) }
        if rewardTypes.contains("chatBubble") { availability.insert(.chat) }
        if (int(privilege["broadcastRangeCode"]) ?? 0) > 0 { availability.insert(.highlight) }
        if int(privilege["roomNoticeFlag"]) == 1 { availability.insert(.notice) }
        if rewardTypes.contains("mount") { availability.insert(.mount) }
        if bool(privilege["hasGuardianGift"]) == true { availability.insert(.gift) }

        return GuardianLevelConfiguration(
            level: level,
            levelName: string(privilege["levelName"]),
            prices: array(raw["prices"]).compactMap(adaptPrice),
            availablePrivileges: availability,
            rewards: rewards
        )
    }

    private static func adaptPrice(_ value: Any) -> GuardianPrice? {
        guard let raw = dictionary(value),
              let durationDays = int(raw["durationDays"]) else { return nil }
        let price = int64(raw["diamondPrice"])
        let originalPrice = int64(raw["originalPrice"]).flatMap { $0 > 0 ? $0 : nil }
        let discountPercent: Int?
        if let price, let originalPrice, price < originalPrice {
            discountPercent = Int(((1 - Double(price) / Double(originalPrice)) * 100).rounded())
        } else {
            discountPercent = nil
        }
        return GuardianPrice(
            durationDays: durationDays,
            price: price,
            originalPrice: originalPrice,
            discountPercent: discountPercent,
            isHot: int(raw["hotFlag"]) == 1
        )
    }

    private static func adaptReward(_ value: Any) -> GuardianReward? {
        guard let raw = dictionary(value),
              let type = string(raw["type"]), !type.isEmpty else { return nil }
        return GuardianReward(
            type: type,
            staticImageURL: string(raw["staticImg"]),
            dynamicImageURL: string(raw["dynamicImg"]),
            sort: int(raw["sort"]) ?? 0
        )
    }

    private static func adaptTopGuardian(_ raw: [String: Any]) -> GuardianTopUser? {
        let nickname = string(raw["top1Nickname"])
        let avatarURL = string(raw["top1Avatar"])
        guard nickname != nil || avatarURL != nil else { return nil }
        return GuardianTopUser(
            userId: string(raw["top1UserId"]),
            nickname: nickname,
            avatarURL: avatarURL,
            level: int(raw["top1LevelCode"]).flatMap(GuardianLevel.init(rawValue:))
        )
    }

    private static func adaptListItem(_ value: Any) -> GuardianListItem? {
        guard let raw = dictionary(value),
              let userId = string(raw["userId"]), !userId.isEmpty,
              let rawLevel = int(raw["currentLevelCode"]),
              let level = GuardianLevel(rawValue: rawLevel) else { return nil }
        return GuardianListItem(
            id: userId,
            nickname: string(raw["nickname"]) ?? "",
            avatarURL: string(raw["avatar"]),
            level: level,
            remainingDays: max(0, int(raw["remainDays"]) ?? 0),
            userLevel: int(raw["userLevel"]),
            gender: int(raw["genderCode"]),
            age: int(raw["age"]),
            isVIP: bool(raw["isVip"]) ?? false
        )
    }

    private static func object(from data: Data) throws -> [String: Any]? {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if json is NSNull { return nil }
        guard let object = json as? [String: Any] else {
            throw GuardianResponseError.invalidPayload
        }
        return object
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as Int64: return Int(exactly: value)
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int64: return value
        case let value as Int: return Int64(value)
        case let value as NSNumber: return value.int64Value
        case let value as String: return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: return value
        case let value as NSNumber: return value.intValue != 0
        case let value as String:
            switch value.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}

enum GuardianResponseError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        "Guardian response could not be decoded."
    }
}
