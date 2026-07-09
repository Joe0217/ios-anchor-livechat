import Foundation

/// 跨场景通用发送者画像。各场景填充策略：
/// - Live：userId = nil；senderNickname 直提；nicknameColor = .anchor(主播) / .default(用户)
/// - Call：userId = nil；1v1 无需 ID 消歧
/// - Party：userId 从 NIM remoteExt["userId"] 兼容 String/Int（见 ios-decode-userid-compat.md）
struct SenderProfile: Equatable {
    var userId: String?
    var nickname: String
    var avatarURL: String?
    var userLevel: Int?
    var isVip: Bool = false
    var isHost: Bool = false
    var role: PartyRole? = nil
    var medals: [String] = []
    var chatBubble: String? = nil       // VIP 花式气泡 borderImage URL
    var isPlatformAdmin: Bool = false   // Party 独有
    var isSelf: Bool = false
    var isNewUser: Bool = false         // Live H5 isNewUser 分支
    var nicknameColor: NicknameColor = .default
}
