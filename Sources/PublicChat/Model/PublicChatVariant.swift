import Foundation

enum PublicChatVariant: Equatable {
    case text(content: String, mentions: [Mention] = [], translation: String? = nil, replyToNick: String? = nil)
    case anchor(content: String, translation: String? = nil)
    case gift(iconURL: String?, name: String, count: Int)
    case luckyGift(iconURL: String?, count: Int, totalReward: Int64)
    case enterRoom(vehicleImg: String?, itemSmallImg: String?)
    case officialBoostEnter
    case pkNotify(richText: [RichSegment])
    case rpsWin(medalUrl: String?, medalHours: Int?)
    case wheelRes(resultText: String, resultHighlight: String?)
    case announcement(text: String, kind: AnnouncementKind)
    case winnerBroadcast(activityName: String, quantity: Int?, imageURL: String?, joinCTA: String?, avatar: String?)
    case wishlistEffect(text: String, iconURL: String?)
    case diamondGift(subType: DiamondGiftSubType)
    case gameWinNotify(payload: GameWinPayload)
    case partyModeSwitch(text: String, kind: ModeSwitchKind)
    case bonus(amount: Int)
    case system(text: String)

    enum Discriminator: String, CaseIterable {
        case text, anchor, gift, luckyGift, enterRoom, officialBoostEnter,
             pkNotify, rpsWin, wheelRes, announcement, winnerBroadcast,
             wishlistEffect, diamondGift, gameWinNotify, partyModeSwitch,
             bonus, system
    }

    var discriminator: Discriminator {
        switch self {
        case .text: return .text
        case .anchor: return .anchor
        case .gift: return .gift
        case .luckyGift: return .luckyGift
        case .enterRoom: return .enterRoom
        case .officialBoostEnter: return .officialBoostEnter
        case .pkNotify: return .pkNotify
        case .rpsWin: return .rpsWin
        case .wheelRes: return .wheelRes
        case .announcement: return .announcement
        case .winnerBroadcast: return .winnerBroadcast
        case .wishlistEffect: return .wishlistEffect
        case .diamondGift: return .diamondGift
        case .gameWinNotify: return .gameWinNotify
        case .partyModeSwitch: return .partyModeSwitch
        case .bonus: return .bonus
        case .system: return .system
        }
    }
}
