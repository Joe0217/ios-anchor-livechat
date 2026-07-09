import Foundation

/// 公屏一条消息（v8 扩展：对齐 H5 messageScroller.vue 结构化字段）。
///
/// **v22 Phase 1**：从 `NIMChatroomManager.swift` 抽出到独立文件（Phase 1 T8），
/// 方便 `LivePublicChatAdapter` 单元测试进入 HilyTests 白名单（NIMChatroomManager 依赖 NIMSDK 不入白名单）。
///
/// Phase 1 内 adapter 直接读 `messageType` 派 `PublicChatVariant`；结构无 breaking change。
struct PublicChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isSystem: Bool
    // v8 结构化扩展（可选，向后兼容旧构造点）
    let senderNickname: String?
    let senderAvatar: String?
    let userLevel: Int?
    let isHost: Bool
    let isVip: Bool
    let messageType: PublicChatMessageType

    init(text: String,
         isSystem: Bool,
         senderNickname: String? = nil,
         senderAvatar: String? = nil,
         userLevel: Int? = nil,
         isHost: Bool = false,
         isVip: Bool = false,
         messageType: PublicChatMessageType = .regular) {
        self.text = text
        self.isSystem = isSystem
        self.senderNickname = senderNickname
        self.senderAvatar = senderAvatar
        self.userLevel = userLevel
        self.isHost = isHost
        self.isVip = isVip
        self.messageType = messageType
    }
}
