import Foundation

/// Party 礼物公屏所需的收礼人信息。Live 礼物不传该字段，保持原有展示。
struct PublicChatGiftRecipient: Equatable {
    let userId: String?
    let nickname: String?
    let avatarURL: String?
}

enum PublicChatVariant: Equatable {
    case text(content: String, mentions: [Mention] = [], translation: String? = nil, replyToNick: String? = nil)
    case anchor(content: String, translation: String? = nil)
    case gift(iconURL: String?, name: String, count: Int, recipients: [PublicChatGiftRecipient] = [])
    case luckyGift(iconURL: String?, count: Int, totalReward: Int64)
    case enterRoom(vehicleImg: String?, itemSmallImg: String?)
    case officialBoostEnter
    case pkNotify(richText: [RichSegment])
    case pkTopContributors(users: [PublicChatUserTarget])
    case rpsWin(medalUrl: String?, medalHours: Double?, gameType: LiveSmallGameType)
    case wheelRes(resultText: String, resultHighlight: String?)
    case announcement(text: String, kind: AnnouncementKind)
    case firstGiftMoment(backgroundURL: String?, renderedText: String, giftIconURL: String?, isFirstGift: Bool)
    case winnerBroadcast(activityName: String, quantity: Int?, messageImageURL: String?, prizeImageURL: String?, joinCTA: String?, avatar: String?, validDays: Int?, nicknameColorHex: String?, prizeColorHex: String?, cardType: String?)
    /// 心愿单 TOP1 变更。昵称和 userId 由消息 sender 承载，便于点击打开资料卡。
    case wishlistEffect
    case diamondGift(subType: PublicChatDiamondGiftSubType)
    case gameWinNotify(payload: GameWinPayload)
    case partyModeSwitch(text: String, kind: ModeSwitchKind)
    /// Party 房 1050 抽数 / 1051 中奖公屏。发送者资料由 `sender` 承载，复用用户公屏头部。
    case partyLuckyNumber(number: Int, didWin: Bool)
    /// Party 房 Battle Team PK 系统消息（对齐 H5 chat-list.vue :333-392 · 4 kind 独立视觉）
    /// - `text`：主文案
    /// - `highlight`：高亮数字/名字（H5 用 #FFE600 黄色）· nil 表示无高亮
    case partyBattle(kind: PartyBattleSystemKind, text: String, highlight: String?)
    case bonus(amount: Int)
    case system(text: String)

    enum Discriminator: String, CaseIterable {
        case text, anchor, gift, luckyGift, enterRoom, officialBoostEnter,
             pkNotify, pkTopContributors, rpsWin, wheelRes, announcement, winnerBroadcast,
             firstGiftMoment, wishlistEffect, diamondGift, gameWinNotify, partyModeSwitch,
             partyLuckyNumber, partyBattle, bonus, system
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
        case .pkTopContributors: return .pkTopContributors
        case .rpsWin: return .rpsWin
        case .wheelRes: return .wheelRes
        case .announcement: return .announcement
        case .firstGiftMoment: return .firstGiftMoment
        case .winnerBroadcast: return .winnerBroadcast
        case .wishlistEffect: return .wishlistEffect
        case .diamondGift: return .diamondGift
        case .gameWinNotify: return .gameWinNotify
        case .partyModeSwitch: return .partyModeSwitch
        case .partyLuckyNumber: return .partyLuckyNumber
        case .partyBattle: return .partyBattle
        case .bonus: return .bonus
        case .system: return .system
        }
    }
}
