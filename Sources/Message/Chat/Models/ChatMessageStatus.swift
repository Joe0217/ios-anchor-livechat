import Foundation

/// P2P 私聊消息发送状态（H-2 spec §2.2，6 态）。
///
/// **状态迁移**：
/// ```
/// .sending ──直发── SDK send ──→ .sent ──receipt.ts ≥ msg.ts── .read
///     │                              │
///     │─需上传─→ .uploading ─── SDK send ──┘
///     │
///     └──error 7101──→ .refused (禁重发)
///     └──error other──→ .failed (可重发)
/// ```
enum ChatMessageStatus: Equatable, Hashable {
    case sending
    /// audio 必经；image/video 若外链发送失败 fallback 时经此态
    case uploading(progress: Double)
    case sent
    case read
    /// 网络 / SDK 通用错误 —— 可重发
    case failed(errorCode: String?)
    /// 7101 被对端拉黑等 —— **禁重发**（UI 层隐藏红叹号）
    case refused(reason: String)
}
