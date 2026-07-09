import Foundation

/// P2P 私聊消息 model（H-2 spec §3.3）。
///
/// **主键策略**：
/// - `id` = NIM `messageId`（SDK 唯一，跨端一致）—— loaded 期 delegate 事件用它去重
/// - `clientMsgId` = 本地乐观发送时临时生成（sent 后 SDK 回填 messageId；用于本地"发送中/失败"这条与 SDK 回执 join）
///
/// **不变量**：
/// - `isOutgoing == (from == 自己 yxAccId)`
/// - `timestamp` 单位为毫秒
struct ChatMessage: Identifiable, Equatable, Hashable {
    /// NIM messageId（乐观发送 sending 阶段可能为空字符串，sent 后回填）
    let id: String
    /// 本地乐观 UUID（仅 outgoing 且 sending/uploading/failed/refused 期间有值）
    let clientMsgId: String?
    let from: String
    let to: String
    let content: ChatMessageContent
    var status: ChatMessageStatus
    let timestamp: Int64
    let isOutgoing: Bool

    // MARK: - H-3 新增（spec §3.2 / §3.3 / §3.4）
    // 用 var + 默认 nil 避免炸多处显式构造点（P2PChatStore.sendText/Image/Video 等）；
    // Codable 层由 NIMChatAdapter mapper 从 remoteExt 解出并注入。

    /// 主播穿戴的气泡装扮 URL；对方发的消息从 `remoteExt.chatBubble` 解出（单源，非 serverExt Web quirk）。
    /// 仅 `.text` case 有效渲染（TextBubbleView 用 NinePatchImageView 背景）。
    var chatBubble: URL? = nil

    /// 私密消息业务 ID（来自 `remoteExt.data.privateId`）；仅 `.privateImage / .privateVideo` case 非 nil。
    /// **注意**：privateId 是后端派发的业务 id，**不是** NIM messageId；`checkPrivateInfo` 入参就是 privateIds 集合。
    var privateId: String? = nil

    /// Batch 6.4：ForEach / scrollTo 稳定 identity —— clientMsgId 优先（发送前后不变）,SDK 回填 messageId 时不 dismantle row
    /// 对齐 H5 msgItem :key 优先 `idClient` 语义（chat/index.vue:1017）
    var stableId: String { clientMsgId ?? id }
}
