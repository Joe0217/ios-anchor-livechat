import Foundation

enum NicknameColor: Equatable {
    case `default`   // Live #1AFFCD 青绿 / Party #fff 白
    case anchor      // #FE00DE 粉
    case her         // #EE7A50 橙（Call 对方主播）
    case special     // 亮粉（SS）
    case host        // 房主橙
}

enum PartyRole: Int, Equatable { case owner = 1, manager = 2 }

enum AnnouncementKind: Equatable { case liveOfficial, partyRoom }

enum ModeSwitchKind: Equatable { case mode, application, authUpdate, videoSeatInvite }

struct Mention: Equatable, Hashable {
    let userId: String
    let userName: String
}

enum DiamondGiftSubType: Equatable {
    case send(senderName: String, tierName: String?, totalDiamonds: Int64)
    case claim(userName: String, diamonds: Int64)
    case settled(topUserName: String, topDiamonds: Int64)
    case expired(senderName: String, refundDiamonds: Int64)
}

/// H5 源：`livechat-h5/src/components/common/game-win-public-msg.vue` L56-63
struct GameWinPayload: Equatable {
    let avatar: String?
    let nickname: String        // 青绿 #1AFFCD
    let winAmount: String       // 粉 #FE00DE
    let gameName: String        // 白色 [xxx]
    let gameIcon: String?       // h20 w20
}
