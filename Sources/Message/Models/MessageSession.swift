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

/// 会话业务扩展字段（`session.ext`）。对齐安卓 `MsgMainFragment.isFlame()` + H5 `session.js`。
///
/// **Flame 通道 A**（安卓 #6-9）：
/// - `receivedGift == true` （安卓 #7）
/// - `called == true` （安卓 #8）
/// - `received && sended` （安卓 #9，双向互动 boolean AND）
/// - `activeTycoon == true` （安卓 #6，profile 为空时的 ext 兜底）
struct MessageSessionExt: Equatable, Hashable {
    let receivedGift: Bool
    let called: Bool
    let received: Bool
    let sended: Bool
    /// 活跃神豪 ext 兜底（安卓 #6：`extension["activeTycoon"] == true`）
    let activeTycoon: Bool

    /// 显式 init 让 `activeTycoon` 有默认值 false（兼容旧调用点未指定 activeTycoon 的场景）
    init(receivedGift: Bool, called: Bool, received: Bool, sended: Bool, activeTycoon: Bool = false) {
        self.receivedGift = receivedGift
        self.called = called
        self.received = received
        self.sended = sended
        self.activeTycoon = activeTycoon
    }

    /// Flame 通道 A 判定：任一 ext 字段命中即 Flame（对齐安卓 MsgMainFragment.isFlame #6-9）
    var isFlameByExt: Bool {
        receivedGift || called || (received && sended) || activeTycoon
    }

    /// 空 ext 兜底（新 session 尚无任何互动标记）
    static let empty = MessageSessionExt(receivedGift: false, called: false, received: false, sended: false, activeTycoon: false)
}
