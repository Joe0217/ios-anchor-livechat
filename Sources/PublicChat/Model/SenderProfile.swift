import Foundation

/// 公屏中多用户消息（如 PK 贡献榜）的可点击用户标识。
struct PublicChatUserTarget: Equatable {
    let userId: String?
    let nickname: String
    let isSelf: Bool
}

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
    /// v3（2026-07-15）：头像框静态图 URL（对齐 H5 `head-frame` 组件消费的 `item.headFrame` 字段）。
    /// 派对房用户虚拟道具 itemType=1 头饰佩戴后返回；nil = 无头像框。
    var headFrame: String? = nil
    /// v4（B1 活跃大R）：ActiveTycoonBadge 显示门禁；由 IM `activeTycoon` 字段透传（H5 messageScroller.vue L373 等 8 处）。
    /// 视觉铁律：**仅主态直播** rendering，客态/派对房/私聊 row 一律不渲染（Row 内可读但 caller 控制 caller 逻辑）。
    var isActiveTycoon: Bool = false
    /// 守护等级。0 = 无守护；直播公屏用其展示守护徽章。
    var guardianLevel: Int = 0
}
