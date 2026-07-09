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
                sender: nil,
                variant: .system(text: m.text)
            )
        }
        let sender = SenderProfile(
            userId: nil,   // Live model 未持 userId（@ mention 落地时再补）
            nickname: m.senderNickname ?? "",
            avatarURL: m.senderAvatar,
            userLevel: m.userLevel,
            isVip: m.isVip,
            isHost: m.isHost,
            role: nil,
            medals: [],
            chatBubble: nil,
            isPlatformAdmin: false,
            isSelf: false,
            isNewUser: false,
            nicknameColor: m.isHost ? .anchor : .default
        )
        return UnifiedPublicChatMessage(
            sender: sender,
            variant: mapVariant(m)
        )
    }

    private static func mapVariant(_ m: PublicChatMessage) -> PublicChatVariant {
        switch m.messageType {
        case .anchor:
            return .anchor(content: m.text)
        case .regular:
            return .text(content: m.text)
        case .gift(let iconUrl, let name, let count):
            return .gift(iconURL: iconUrl, name: name, count: count)
        case .luckyGift(let iconUrl, let count, let total):
            return .luckyGift(iconURL: iconUrl, count: count, totalReward: total)
        case .enterRoom:
            return .enterRoom(vehicleImg: nil, itemSmallImg: nil)
        case .officialBoostEnter:
            return .officialBoostEnter
        case .pkNotify:
            return .pkNotify(richText: [.text(m.text, color: .white)])
        case .rpsWin(let url, let hours):
            return .rpsWin(medalUrl: url, medalHours: hours)
        case .wheelRes:
            return .wheelRes(resultText: m.text, resultHighlight: nil)
        case .announcement:
            return .announcement(text: m.text, kind: .liveOfficial)
        case .winnerBroadcast(let activity, let qty):
            return .winnerBroadcast(activityName: activity, quantity: qty,
                                    imageURL: nil, joinCTA: nil, avatar: nil)
        case .wishlistEffect:
            return .wishlistEffect(text: m.text, iconURL: nil)
        case .diamondGift(let oldSubType):
            return .diamondGift(subType: convertDiamondSubType(oldSubType))
        }
    }

    /// 旧 `DiamondGiftSubType`（PublicChatMessageType.swift）→ 新 `PublicChatDiamondGiftSubType`
    private static func convertDiamondSubType(_ old: DiamondGiftSubType) -> PublicChatDiamondGiftSubType {
        switch old {
        case .send(let senderName, let tierName, let totalDiamonds):
            return .send(senderName: senderName, tierName: tierName, totalDiamonds: totalDiamonds)
        case .claim(let userName, let diamonds):
            return .claim(userName: userName, diamonds: diamonds)
        case .settled(let topUserName, let topDiamonds):
            return .settled(topUserName: topUserName, topDiamonds: topDiamonds)
        case .expired(let senderName, let refundDiamonds):
            return .expired(senderName: senderName, refundDiamonds: refundDiamonds)
        }
    }
}
