import Foundation

struct UnifiedPublicChatMessage: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let sender: SenderProfile?      // nil = 系统消息
    let variant: PublicChatVariant

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         sender: SenderProfile? = nil,
         variant: PublicChatVariant) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.variant = variant
    }
}
