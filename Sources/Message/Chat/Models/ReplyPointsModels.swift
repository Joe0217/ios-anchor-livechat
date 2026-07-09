import Foundation

/// H-3 回复积分数据契约（spec §3.1 / §3.2）。
///
/// **3 个后端接口**（H5 `api/chat/index.ts:13-35`）：
/// - `getMessagePoint`  `/api/im/getMessagePoint`  `{userYxAccid}` → MessageBoxList
/// - `treasurePointBox` `/api/im/treasurePointBox` `{userYxAccid}` → `{diamond: Int}`
/// - `settleReplyPoints` `/api/im/settleReplyPoints` `{userYxAccid, userMsgId, msgType?}` → SettleReplyPointsResult

/// 单个宝箱节点（H-3 spec §3.2 / §2.3）。
///
/// **status 语义**（H5 `rewardProgress.vue:196-208`）：
/// - `.notReached` (0) — 用户消息进度未达到；节点灰态
/// - `.claimed` (1)    — 已领奖；节点蒙 `get-icon.webp`
/// - `.claimable` (2)  — **进页 auto-claim 触发**（Critical-6：领奖时机是拉 messageBoxList 时 status==2，非本地进度到点）
struct MessageBoxItem: Decodable, Equatable, Hashable {
    let points: Int
    let diamond: Int
    let status: BoxStatus
}

/// 宝箱状态（v2 Major-5 建议：用 enum 替代 raw Int 提升表达力）。
enum BoxStatus: Int, Decodable, Equatable, Hashable {
    case notReached = 0
    case claimed = 1
    case claimable = 2
}

/// getMessagePoint 响应。**S1 spike 已从 H5 源码闭环确认字段**，无需抓包。
struct MessageBoxList: Decodable, Equatable {
    let pointInfoList: [MessageBoxItem]
    let anchorPoint: Int
}

/// settleReplyPoints 响应（H5 `rewardProgress.vue` 消费字段）。
///
/// **关键字段**（H-3 spec §2.3 结算逻辑）：
/// - `settled` — 是否本次结算成功
/// - `currentTotalPoints` — 服务端权威覆盖本地 currentProgress
/// - `multiplier` — 后端返回，前端不算档位（v3 §1.2.11）
/// - `points`（本次积分） / `basePoints`（基准分） / `message`（tip 文案兜底）
struct SettleReplyPointsResult: Decodable, Equatable {
    let settled: Bool
    let points: Int
    let multiplier: Double
    let basePoints: Int
    let currentTotalPoints: Int
    let message: String?
}

/// 最后一条用户消息记录（H-3 spec §2.3 `lastUserMsgInfo`）。
///
/// **不变量**（v2 Critical-5 / v3 §8.2 #5）：
/// - `onSendAnchorMsg` 里**无论 settleReplyPoints 成功 / 失败 / isGift 短路**，都在 try/finally 里清 `lastUserMsgInfo = nil`
/// - 未清 → 用户 1 条消息主播 N 次重复调 settle 触发后端风控
struct LastUserMsgInfo: Equatable, Hashable {
    let msgId: String        // NIM messageId
    let timestamp: Int64     // ms
    let msgType: String      // "pay" / "free"（v3 Major-6：msg.ext.msgType 缺失时默认 "pay"）
    let isGift: Bool         // isGift=true 时不参与 settleReplyPoints
}

/// 单一 tip 记录（会话内 sticky；混入 messagesData 按 `stableSortKey` 排序）。
///
/// **stableSortKey**（v3 Major-7 + Minor-3）：`timestamp * 100 + kind.tieBreaker`
/// - 真实消息 tieBreaker=0
/// - guide=1 > replyPointGuide=2 > replyRemind=3 > stimulate=4
struct ChatTip: Identifiable, Equatable, Hashable {
    let id: UUID
    let kind: ChatTipKind
    let text: String
    let timestamp: Int64

    var stableSortKey: Int64 {
        timestamp * 100 + Int64(kind.tieBreaker)
    }

    init(id: UUID = UUID(), kind: ChatTipKind, text: String, timestamp: Int64) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }
}

/// 单会话 peer 状态（ReplyPointsStore.sessions[peer]）。
///
/// **生命周期**（spec §Q7 "会话内 sticky，pop 即清"）：
/// - `beginSession(peer)` 时创建 / 覆盖
/// - `endSession(peer)` 时 remove（pop 回列表即清）
/// - **跨会话保留**字段（如 currentUserSendPaidMessageCount）不放这里，放 Store 顶层
struct PeerReplyPointsState: Equatable {
    var messageBoxList: [MessageBoxItem]?
    var currentProgress: Int = 0                  // == anchorPoint 初始 + 累加
    var lastUserMsgInfo: LastUserMsgInfo? = nil
    var replyRemindSent: Bool = false              // 会话内一次性 sticky
    var hasHistoryReply: Bool = false              // 主播是否已回复过（首次结算成功后 true）
    var replyRemindBaseTs: Int64? = nil            // 最后用户消息 timestamp，配合 Date 差值判 15min（Minor-4：不用 Timer）
    var tips: [ChatTip] = []                       // 已注入 tip 列表（会话粒度）

    /// 从 anchorPoint 派生初始 progress
    init(from list: MessageBoxList) {
        self.messageBoxList = list.pointInfoList
        self.currentProgress = list.anchorPoint
    }

    init() {}
}
