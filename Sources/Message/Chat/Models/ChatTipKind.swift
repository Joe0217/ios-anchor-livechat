import Foundation

/// 回复积分 tip 类型（H-3 spec §1.2 / §2.5 / §F-42）。
///
/// **4 case**（跳过 H5 死代码 `replyPointTip`，对齐 spec §1.2.4）：
/// - `guide` — 引导（首次进页 or >24h 距上次；文案 `chat.guideTip`）
/// - `stimulate` — 刺激（用户发付费消息 ≥10 触发；文案 `chat.stimulateTip`）
/// - `replyPointGuide` — 回复积分引导（用户已发未回复；文案 `chat.replyFastTip`；时间戳 `lastUserMsg.time + 1`）
/// - `replyRemind` — 回复提醒（最后用户消息 ≥15min；文案 `chat.replyRemindTip`；replyRemindSent 会话 sticky）
///
/// **stableSortKey 优先级**（v2 Major-7 / Minor-3）：guide=1 > replyPointGuide=2 > replyRemind=3 > stimulate=4
enum ChatTipKind: Equatable, Hashable {
    case guide
    case stimulate
    case replyPointGuide
    case replyRemind

    /// stableSortKey tieBreaker（v2 Major-7 / Minor-3）：真实消息 tieBreaker=0，tip 按此顺序。
    /// 用于 `messagesData` 混合排序 `timestamp * 100 + tieBreaker` 保稳定。
    var tieBreaker: Int {
        switch self {
        case .guide: return 1
        case .replyPointGuide: return 2
        case .replyRemind: return 3
        case .stimulate: return 4
        }
    }
}
