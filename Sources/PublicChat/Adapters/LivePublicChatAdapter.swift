import Foundation

/// Live 场景公屏消息适配器。将 `PublicChatMessage`（[LivePublicChatPayload.swift](../../Live/PublicScreen/LivePublicChatPayload.swift)）
/// 映射为跨场景统一的 `UnifiedPublicChatMessage`。
///
/// Phase 1 内直接读 `messageType`（旧 UI 分派枚举），复用其已有变体信息；
/// 无需修改现有 15+ 处 `PublicChatMessage(...)` 构造点。
enum LivePublicChatAdapter {

    static func adapt(_ m: PublicChatMessage) -> UnifiedPublicChatMessage {
        if m.isSystem {
            return UnifiedPublicChatMessage(
                id: m.id,
                sender: nil,
                variant: .system(text: m.text)
            )
        }
        let sender = SenderProfile(
            userId: m.senderUserId,   // v24 B4：ext.userId 透传
            nickname: m.senderNickname ?? "",
            avatarURL: m.senderAvatar,
            userLevel: m.userLevel,
            isVip: m.isVip,
            isHost: m.isHost,
            role: nil,
            medals: [],
            chatBubble: m.chatBubble,
            isPlatformAdmin: false,
            isSelf: m.isSelf,          // v24 B4：主播自发消息不弹 hi 气泡
            isNewUser: m.isNewUser,
            nicknameColor: m.isHost ? .anchor : .default,
            headFrame: nil,
            isActiveTycoon: m.isActiveTycoon,   // v24 B1：大 R 徽章门禁
            guardianLevel: m.guardianLevel
        )
        return UnifiedPublicChatMessage(
            id: m.id,
            sender: sender,
            variant: mapVariant(m),
            actionURL: m.actionURL
        )
    }

    private static func mapVariant(_ m: PublicChatMessage) -> PublicChatVariant {
        switch m.messageType {
        case .anchor:
            return .anchor(content: m.text)
        case .regular:
            return .text(content: m.text, mentions: [], translation: nil, replyToNick: m.replyToNick)
        case .gift(let iconUrl, let name, let count):
            return .gift(iconURL: iconUrl, name: name, count: count)
        case .luckyGift(let iconUrl, let count, let total):
            return .luckyGift(iconURL: iconUrl, count: count, totalReward: total)
        case .enterRoom:
            return .enterRoom(vehicleImg: nil, itemSmallImg: m.itemSmallImg)
        case .officialBoostEnter:
            return .officialBoostEnter
        case .pkNotify:
            return .pkNotify(richText: [.text(m.text, color: .white)])
        case .pkTopContributors(let users):
            return .pkTopContributors(users: users)
        case .rpsWin(let url, let hours, let gameType):
            return .rpsWin(medalUrl: url, medalHours: hours, gameType: gameType)
        case .wheelRes:
            return .wheelRes(resultText: m.text, resultHighlight: nil)
        case .announcement:
            return .announcement(text: m.text, kind: .liveOfficial)
        case .firstGiftMoment(let backgroundURL, let renderedText, let giftIconURL, let isFirstGift):
            return .firstGiftMoment(
                backgroundURL: backgroundURL,
                renderedText: renderedText,
                giftIconURL: giftIconURL,
                isFirstGift: isFirstGift
            )
        case .winnerBroadcast(let activity, let qty):
            return .winnerBroadcast(activityName: activity, quantity: qty,
                                    messageImageURL: m.winnerMessageImageURL,
                                    prizeImageURL: m.winnerPrizeImageURL,
                                    joinCTA: m.winnerJoinImageURL,
                                    avatar: m.senderAvatar,
                                    validDays: m.winnerValidDays,
                                    nicknameColorHex: m.winnerNicknameColorHex,
                                    prizeColorHex: m.winnerPrizeColorHex,
                                    cardType: m.winnerCardType)
        case .wishlistEffect:
            return .wishlistEffect
        case .diamondGift(let oldSubType):
            return .diamondGift(subType: convertDiamondSubType(oldSubType))
        }
    }

    /// 旧 `DiamondGiftSubType`（PublicChatMessageType.swift）→ 新 `PublicChatDiamondGiftSubType`
    private static func convertDiamondSubType(_ old: DiamondGiftSubType) -> PublicChatDiamondGiftSubType {
        switch old {
        case .send(let giftId, let senderId, let senderName, let tierName, let totalDiamonds):
            return .send(giftId: giftId, senderId: senderId, senderName: senderName,
                         tierName: tierName, totalDiamonds: totalDiamonds)
        case .claim(let giftId, let userId, let userName, let diamonds):
            return .claim(giftId: giftId, userId: userId, userName: userName, diamonds: diamonds)
        case .settled(let giftId, let topUserId, let topUserName, let topUserAvatarURL, let topDiamonds):
            return .settled(giftId: giftId, topUserId: topUserId, topUserName: topUserName,
                            topUserAvatarURL: topUserAvatarURL, topDiamonds: topDiamonds)
        case .expired(let giftId, let senderId, let senderName, let refundDiamonds):
            return .expired(giftId: giftId, senderId: senderId, senderName: senderName, refundDiamonds: refundDiamonds)
        }
    }
}
