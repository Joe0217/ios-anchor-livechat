import Foundation

/// 2049 派对房礼物广播的视觉消费模型。
///
/// H5 `party.js:newGiftMessage` 使用的字段与通用直播礼物不同：发送人位于
/// `sendUser`，收礼人来自 `receiveUserList`，静态缩略图是 `smallImg`。
/// 将这层映射独立出来，避免派对房继续复用直播 payload 的猜测字段。
struct PartyGiftEffectRecipient: Identifiable, Equatable {
    let id: String
    let nickname: String?
    let avatarURL: String?
}

/// Lucky Gift 中奖广播的全屏效果数据。
///
/// H5 仅在非发送者收到 `totalReward > 0 && rewardPool.winningStyle` 时播放；动画资源固定，
/// 发送者头像、昵称和中奖金额作为覆盖文字内容。
struct PartyLuckyGiftWinEffect: Equatable {
    static let animationURL = "https://img.hnhily.link//appId/default/1757412641079.svga"

    let senderUserId: String?
    let senderNickname: String?
    let senderAvatarURL: String?
    let totalReward: Int

    static func from(payload: [String: Any], myUserId: String?) -> PartyLuckyGiftWinEffect? {
        guard let totalReward = PartyValueNormalizer.intify(payload["totalReward"]), totalReward > 0,
              hasWinningStyle(payload["rewardPool"])
        else { return nil }

        let sendUser = payload["sendUser"] as? [String: Any]
        let senderUserId = sendUser.flatMap { string($0["userId"]) }
        // H5：发送者本地已经在送礼结果链路播放，不再消费 IM 回环的 guest 动画。
        if let myUserId, senderUserId == myUserId { return nil }

        return PartyLuckyGiftWinEffect(
            senderUserId: senderUserId,
            senderNickname: sendUser.flatMap { string($0["nickname"]) },
            senderAvatarURL: sendUser.flatMap {
                // H5 中奖文字使用 `sendUser.avatar`。
                firstNonEmpty($0["avatar"], $0["icon"], $0["userAvatar"])
            },
            totalReward: totalReward
        )
    }

    private static func hasWinningStyle(_ rewardPool: Any?) -> Bool {
        let pool = rewardPool as? [String: Any]
        guard let value = pool?["winningStyle"] else { return false }
        if let string = string(value) { return !string.isEmpty }
        if let number = value as? NSNumber { return number.boolValue }
        return !(value is NSNull)
    }

    private static func firstNonEmpty(_ values: Any?...) -> String? {
        values.lazy.compactMap(string).first
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = PartyValueNormalizer.stringify(value) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct PartyGiftEffectItem: Identifiable, Equatable {
    let id: UUID
    let giftId: Int64
    let giftName: String
    let giftCount: Int
    /// 原始动效资源。仅 `.svga` / `.mp4` 会交给跨场景播放器。
    let animationURL: String?
    /// H5 的 `smallImg`，用于中央静态礼物、麦位收礼与飘屏。
    let thumbnailURL: String?
    let senderUserId: String?
    let senderNickname: String?
    let senderAvatarURL: String?
    let senderUserType: Int?
    let senderLevel: Int?
    let senderIsVip: Bool
    let senderMedalURLs: [String]
    let senderRoomRoleType: Int?
    let recipients: [PartyGiftEffectRecipient]
    /// 消息直接携带的幸运礼物标记；礼物架分类兜底由 coordinator 补充。
    let isLuckyHint: Bool

    var receiverUserIds: [String] { recipients.map(\.id) }
    var giftCountTotal: Int { giftCount * recipients.count }

    var hasPlayableAnimation: Bool {
        guard let animationURL else { return false }
        let ext = URL(string: animationURL)?.pathExtension.lowercased() ?? ""
        return ext == "svga" || ext == "mp4"
    }

    /// 静态礼物没有 `smallImg` 时才退化到非动效的 `giftIcon`。
    var staticImageURL: String? {
        if let thumbnailURL { return thumbnailURL }
        return hasPlayableAnimation ? nil : animationURL
    }

    /// H5 `gift-animator-receiver` uses `giftImg`, which is the original 2049
    /// `giftIcon`; the center and floating row use `smallImg` instead.
    /// SVGA/MP4 resources belong to the global player and cannot be rendered as an image here.
    var receiverImageURL: String? {
        guard !hasPlayableAnimation else { return nil }
        return animationURL ?? thumbnailURL
    }

    static func from(payload: [String: Any]) -> PartyGiftEffectItem? {
        guard let giftId = int64(payload["giftId"]), giftId != 0 else { return nil }

        let sendUser = payload["sendUser"] as? [String: Any]
        let rawRecipients: [[String: Any]] = (payload["receiveUserList"] as? [[String: Any]]) ?? []
        let recipients: [PartyGiftEffectRecipient] = rawRecipients.compactMap { receiver in
            guard let id = string(receiver["userId"]), !id.isEmpty else { return nil }
            return PartyGiftEffectRecipient(
                id: id,
                nickname: string(receiver["nickname"]),
                avatarURL: firstNonEmpty(receiver["icon"], receiver["avatar"], receiver["userAvatar"])
            )
        }

        return PartyGiftEffectItem(
            id: UUID(),
            giftId: giftId,
            giftName: string(payload["giftName"]) ?? "",
            giftCount: int(payload["giftNum"]) ?? 1,
            animationURL: string(payload["giftIcon"]),
            thumbnailURL: firstNonEmpty(payload["smallImg"], payload["giftSmallImg"], payload["giftImg"]),
            senderUserId: sendUser.flatMap { string($0["userId"]) },
            senderNickname: sendUser.flatMap { string($0["nickname"]) },
            senderAvatarURL: sendUser.flatMap {
                // H5 floating-message-item 使用 `sendUser.icon`；avatar 是兼容字段兜底。
                firstNonEmpty($0["icon"], $0["avatar"], $0["userAvatar"])
            },
            senderUserType: sendUser.flatMap { int($0["userType"]) },
            senderLevel: sendUser.flatMap { int($0["levelName"] ?? $0["userLevel"] ?? $0["level"]) },
            senderIsVip: bool(sendUser?["isVip"]) || bool(payload["isVip"]),
            senderMedalURLs: nonEmptyStrings(sendUser?["medalList"] ?? payload["userMedals"]),
            senderRoomRoleType: int(payload["roomRoleType"]),
            recipients: recipients,
            isLuckyHint: int(payload["giftTypeV2"]) == 6 || bool(payload["luckyGift"])
        )
    }

    private static func firstNonEmpty(_ values: Any?...) -> String? {
        values.lazy.compactMap(string).first
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = PartyValueNormalizer.stringify(value) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ value: Any?) -> Int? {
        PartyValueNormalizer.intify(value)
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let value = int(value) else { return nil }
        return Int64(value)
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = string(value) { return value.lowercased() == "true" || value == "1" }
        return int(value) == 1
    }

    private static func nonEmptyStrings(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap(string)
    }
}
