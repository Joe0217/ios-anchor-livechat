import Foundation

/// P2P 会话（H-1 MVP）。
///
/// 来源：NIM SDK `NIMRecentSession` 归一化 + 补 SessionStore 缓存的对端 nickname/avatar。
/// SDK 依赖仅在 `NIMSessionAdapter`（Step 1c 落地），本 model 纯 Foundation，可入 HilyTests。
struct MessageSession: Identifiable, Equatable, Hashable {
    /// yxAccid（NIM session id）；跨端稳定标识
    let id: String
    let peerNickname: String
    let peerAvatarURL: String?
    /// 最后一条消息文本摘要（图片/语音/礼物等已归一化占位如 "[图片]"）
    let lastMessage: String
    /// 毫秒时间戳
    let lastMessageTimestamp: Int64
    let unreadCount: Int
    let isTop: Bool
    let ext: MessageSessionExt
}

/// 会话业务扩展字段（`session.ext`）。H5 `session.js` 的 `ext` 结构逐字对齐。
///
/// **boolean 语义**（v2 修订，red team C-1）：
/// - `received` / `sended` 是 **Bool 不是 Int**（H5 源码 `session.js:34-48`）
/// - Flame 通道 A：`receivedGift || called || (received && sended)`—— 双向消息互动是 AND 不是 OR
struct MessageSessionExt: Equatable, Hashable {
    let receivedGift: Bool
    let called: Bool
    let received: Bool
    let sended: Bool

    /// H5 `checkSessionExtraIsFlame` 通道 A 判定。
    /// **不含**通道 B（flameUserIdList）——scope 排除留 H-2，见 spec §1.2 + R-6。
    var isFlameByExt: Bool {
        receivedGift || called || (received && sended)
    }

    /// 空 ext 兜底（新 session 尚无任何互动标记）
    static let empty = MessageSessionExt(receivedGift: false, called: false, received: false, sended: false)
}
