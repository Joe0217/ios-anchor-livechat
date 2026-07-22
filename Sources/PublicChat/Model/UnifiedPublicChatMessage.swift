import Foundation

/// 服务端消息定位信息。大多数公屏场景不需要；Party 房房主/房管删除文本时使用。
struct PublicChatMessageSource: Equatable {
    /// 云信客户端消息 ID；H5 删除接口字段名虽为 `msgIdServer`，实际传该值。
    let messageId: String
    /// 云信时间戳（毫秒），对应 H5 `msgTimetag`。
    let timetag: Int64
    /// 发送者云信 accid，对应 H5 `fromAccid`。
    let fromAccid: String
}

struct UnifiedPublicChatMessage: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let sender: SenderProfile?      // nil = 系统消息
    let variant: PublicChatVariant
    /// 远端消息的服务端定位信息；本地系统消息和未获云信 ID 的乐观回显为 nil。
    let source: PublicChatMessageSource?

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         sender: SenderProfile? = nil,
         variant: PublicChatVariant,
         source: PublicChatMessageSource? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.variant = variant
        self.source = source
    }
}
