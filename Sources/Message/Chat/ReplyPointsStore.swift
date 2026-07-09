import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "reply-points-store")

/// H-3 回复积分状态机（spec §2.3 / §4.4-4.6）。
///
/// **架构决策**：
/// - `@MainActor` 单例（对齐 SessionStore/AnchorInfoStore 模式）
/// - **跨会话保留**字段（`currentUserSendPaidMessageCount` / `lastGuideTipAt`）—— 对齐 H5 chatStore 全局态（Major-6）
/// - **每会话 sticky**字段（`replyRemindSent` / `lastUserMsgInfo` / `hasHistoryReply` / `tips`）—— 存 `sessions[peer]`
/// - **pop 即清**（spec §Q7）—— `endSession(peer)` 移除 `sessions[peer]`；下次进 same peer 视作新会话
///
/// **文案 L10n 由 caller 提供**（Store 属 Model 层，不 import L10n / SwiftUI）：
/// - `ReplyPointsTipTexts` 参数一次性传入 4 条文案；Store 内部只判 condition + 组装 ChatTip
///
/// **Tip 排序**（Major-7 + Minor-3）：`ChatTip.stableSortKey = timestamp * 100 + kind.tieBreaker`；view 层把
/// tips 与真实消息按此 key 混合排序显示。
///
/// **不变量清单**（v3 §8.2）：
/// - #5 `lastUserMsgInfo` 无论成功/失败/isGift 都在 `onSendAnchorMsg` 结尾清（try/finally / defer）
/// - #6 isGift 消息不参与 settleReplyPoints
/// - #13 auto-claim 在 `beginSession → fetchMessageBoxList` 后 filter `status == .claimable` 触发
/// - #17 `currentUserSendPaidMessageCount` 跨会话保留（切换 peer 不清）
/// - #19 tip 排序用 `stableSortKey`（timestamp * 100 + tieBreaker）
/// - #20 15min timer 用 Date 差值判定（`checkReplyRemindTrigger`），不用 Timer.fire
/// Config 依赖抽象（Store 层不引具体 `ReplyPointsConfigBridge`，单测可 stub）。
/// `ReplyPointsConfigBridge` conform 此 protocol；Store 用 protocol 依赖注入。
@MainActor
protocol ReplyPointsConfigBridging {
    var isLoaded: Bool { get }
    var payMsgPoints: Int? { get }
    var freeMsgPoints: Int? { get }
}

@MainActor
final class ReplyPointsStore: ObservableObject {
    static let shared = ReplyPointsStore(service: ReplyPointsHTTPService.shared, configBridge: ReplyPointsConfigBridge())

    // MARK: - 跨会话字段（Major-6）

    @Published private(set) var currentUserSendPaidMessageCount: Int = 0
    private var lastGuideTipAt: Date? = nil

    // MARK: - 每会话字段

    @Published private(set) var sessions: [String: PeerReplyPointsState] = [:]

    /// 最后一次 settle 成功结果；view 层订阅触发进度条跳跃动画（H5 rewardProgress `.reply-point-jump`）
    /// 消费后 view 层清 nil（对齐 H5 `@animationend="chatStore.replyPointSettleResult = null"`）
    @Published var pendingSettleResult: SettleReplyPointsResult? = nil

    /// Batch 6.3.1：待展示的钻石领取数量（auto-claim 成功后累加；view 层订阅弹 DiaReceivePopup）
    /// 用户 tap Get 后 view 层清 nil；多次 claim 会累加到同一弹窗
    @Published var pendingClaimDiamond: Int? = nil

    // MARK: - 依赖

    private let service: ReplyPointsServiceProtocol
    private let configBridge: ReplyPointsConfigBridging

    init(service: ReplyPointsServiceProtocol, configBridge: ReplyPointsConfigBridging) {
        self.service = service
        self.configBridge = configBridge
    }

    // MARK: - 派生

    /// 会话是否开启付费消息（H-3 §1.2.1）：拉到 messageBoxList 且非空
    func isOpenPaidMessage(peer: String) -> Bool {
        guard let list = sessions[peer]?.messageBoxList else { return false }
        return !list.isEmpty
    }

    /// 派生 view 用的 tip 列表；ChatDetailView 混入 messagesData 按 stableSortKey 排序
    func tips(for peer: String) -> [ChatTip] {
        sessions[peer]?.tips ?? []
    }

    // MARK: - 会话生命周期

    /// 进入 chat 页时调用。拉 messageBoxList + auto-claim + inject initial tips。
    ///
    /// - Parameters:
    ///   - peer: 对方 yxAccId
    ///   - initialLastUserMsg: 从历史消息推的最后一条用户消息（caller ChatDetailContainer 从
    ///     P2PChatStore.messagesData 找 last incoming msg）；nil = 无历史用户消息，跳过
    ///     replyPointGuide/replyRemind tip 注入
    ///   - tipTexts: 4 条 L10n 文案（caller 从 L10n 拉）
    ///   - now: 当前时间（测试注入；生产传 `Date()`）
    func beginSession(
        peer: String,
        initialLastUserMsg: LastUserMsgInfo? = nil,
        tipTexts: ReplyPointsTipTexts,
        now: Date = Date()
    ) async {
        do {
            let list = try await service.fetchMessageBoxList(userYxAccid: peer)
            var state = PeerReplyPointsState(from: list)
            if let last = initialLastUserMsg {
                state.lastUserMsgInfo = last
                state.replyRemindBaseTs = last.timestamp
            }
            sessions[peer] = state

            // Critical-6：auto-claim 时机在 fetchMessageBoxList 时按 status==2 触发（非本地进度到点）
            await autoClaimIfNeeded(peer: peer)

            // Tip 注入判定
            if isOpenPaidMessage(peer: peer) {
                tryInjectGuideTip(peer: peer, text: tipTexts.guide, now: now)
                tryInjectReplyPointGuideTip(peer: peer, text: tipTexts.replyPointGuide, now: now)
                tryInjectReplyRemindTip(peer: peer, text: tipTexts.replyRemind, now: now)
            }
        } catch {
            logger.warning("[ReplyPoints] beginSession fetch failed peer=\(peer, privacy: .private): \(String(describing: error), privacy: .public)")
            // 失败兜底：留空 sessions[peer]（isOpenPaidMessage=false，全流程跳过）
        }
    }

    /// 离开 chat 页时调用（对齐 spec §Q7 "pop 即清"）。跨会话字段（count / lastGuideTipAt）保留。
    func endSession(peer: String) {
        sessions[peer] = nil
    }

    /// logout 时调用（挂 session-scoped rule）。全清含跨会话字段。
    func clear() {
        currentUserSendPaidMessageCount = 0
        lastGuideTipAt = nil
        sessions.removeAll()
        pendingSettleResult = nil
    }

    // MARK: - 用户消息累加

    /// 用户发消息到达（P2PChatStore.forward）。
    ///
    /// **条件**（H-3 §2.3）：
    /// - `!isGift` && `isOpenPaidMessage(peer)` && `configBridge.isLoaded && payMsgPoints/freeMsgPoints` non-nil
    /// - msgType 缺失默认 "pay"（Major-6，对齐 H5 `message.js:903`）
    ///
    /// **副作用**：
    /// - `currentProgress += points`
    /// - `currentUserSendPaidMessageCount += 1`；≥10 触发 stimulateTip + count 清 0
    /// - `lastUserMsgInfo = {msgId, ts, msgType, isGift: false}`
    /// - `replyRemindBaseTs = ts`（15min timer 基准，Minor-4 用 Date 差值判定）
    func onReceiveUserMsg(
        peer: String,
        msgId: String,
        timestamp: Int64,
        msgType: String?,
        isGift: Bool,
        stimulateTipText: String,
        now: Date = Date()
    ) {
        guard !isGift, isOpenPaidMessage(peer: peer) else { return }
        guard configBridge.isLoaded,
              let payPoints = configBridge.payMsgPoints,
              let freePoints = configBridge.freeMsgPoints
        else {
            // R-10：AppConfigStore 未 loaded → 不累加 currentProgress（下次 loaded 后由 view 重刷）
            logger.info("[ReplyPoints] config not loaded, skip accumulate for peer=\(peer, privacy: .private)")
            return
        }

        let type = msgType ?? "pay"      // Major-6
        let points = (type == "pay") ? payPoints : freePoints

        var state = sessions[peer] ?? PeerReplyPointsState()
        state.currentProgress += points
        state.lastUserMsgInfo = LastUserMsgInfo(msgId: msgId, timestamp: timestamp, msgType: type, isGift: false)
        state.replyRemindBaseTs = timestamp
        sessions[peer] = state

        currentUserSendPaidMessageCount += 1
        if currentUserSendPaidMessageCount >= 10 {
            let ts = Int64(now.timeIntervalSince1970 * 1000)
            appendTip(peer: peer, kind: .stimulate, text: stimulateTipText, timestamp: ts)
            currentUserSendPaidMessageCount = 0
        }
    }

    // MARK: - 主播回复结算

    /// 主播消息发送成功后调用（P2PChatStore.forward）。
    ///
    /// **不变量**（v2 Critical-5 / v3 §8.2 #5）：无论成功 / 失败 / isGift 短路，`lastUserMsgInfo = nil`
    /// 在 defer 里执行 —— 防用户 1 条消息主播 N 次重复调 settle 触发风控。
    func onSendAnchorMsg(peer: String, msgType: String) async {
        guard var state = sessions[peer],
              let last = state.lastUserMsgInfo
        else { return }

        // isGift 短路也清（对齐 H5 line 1090-1092）
        guard !last.isGift else {
            state.lastUserMsgInfo = nil
            sessions[peer] = state
            return
        }

        // defer 兜底：无论 try 内如何返回都清 lastUserMsgInfo（Critical-5）
        defer {
            var s = sessions[peer] ?? state
            s.lastUserMsgInfo = nil
            sessions[peer] = s
        }

        do {
            let res = try await service.settleReplyPoints(
                userYxAccid: peer,
                userMsgId: last.msgId,
                msgType: msgType
            )
            if res.settled {
                state.currentProgress = res.currentTotalPoints       // 权威覆盖
                state.hasHistoryReply = true
                state.replyRemindBaseTs = nil                          // 取消 15min timer
                sessions[peer] = state
                pendingSettleResult = res                              // 触发 view 跳跃动画
                logger.info("[ReplyPoints] settle success peer=\(peer, privacy: .private) points=\(res.points) total=\(res.currentTotalPoints)")
            } else {
                logger.info("[ReplyPoints] settle returned settled=false (isGift/未开付费) peer=\(peer, privacy: .private)")
            }
        } catch {
            logger.warning("[ReplyPoints] settle failed peer=\(peer, privacy: .private): \(String(describing: error), privacy: .public)")
            // 失败静默；lastUserMsgInfo 仍在 defer 里清（防重放）
        }
    }

    // MARK: - Auto-claim（Critical-6）

    /// 拉 messageBoxList 完成后，对所有 `.claimable` 节点依次调 apiTreasurePointBox。
    /// 失败 → toast + node status 不变（下次进页重试）；view 层订阅 sessions 感知领奖弹窗时机。
    private func autoClaimIfNeeded(peer: String) async {
        guard let items = sessions[peer]?.messageBoxList else { return }
        var totalClaimedDiamond = 0
        for (idx, item) in items.enumerated() where item.status == .claimable {
            do {
                let diamond = try await service.claimTreasureBox(userYxAccid: peer)
                logger.info("[ReplyPoints] auto-claim ok peer=\(peer, privacy: .private) idx=\(idx) diamond=\(diamond)")
                // 更新本地 status → .claimed（避免下次 onReceive 时误重复触发）
                if var list = sessions[peer]?.messageBoxList, idx < list.count {
                    list[idx] = MessageBoxItem(points: item.points, diamond: item.diamond, status: .claimed)
                    sessions[peer]?.messageBoxList = list
                }
                totalClaimedDiamond += diamond
            } catch {
                logger.warning("[ReplyPoints] auto-claim failed peer=\(peer, privacy: .private) idx=\(idx): \(String(describing: error), privacy: .public)")
            }
        }
        // Batch 6.3.1：所有 claim 完累加显示；多次 claim 累加到同一弹窗（用户 tap Get 后 view 清 nil）
        if totalClaimedDiamond > 0 {
            pendingClaimDiamond = (pendingClaimDiamond ?? 0) + totalClaimedDiamond
        }
    }

    // MARK: - 15min timer（Minor-4：用 Date 差值判定，不用 Timer.fire）

    /// view 层定期调（或滚动 / 消息更新时机）。判定 replyRemindTip 是否应注入。
    ///
    /// 触发条件：
    /// - `isOpenPaidMessage(peer)`
    /// - `!replyRemindSent`
    /// - `!hasHistoryReply`
    /// - `replyRemindBaseTs` 存在 && `now - baseTs >= 15min`
    func checkReplyRemindTrigger(peer: String, tipText: String, now: Date = Date()) {
        guard isOpenPaidMessage(peer: peer) else { return }
        guard var state = sessions[peer] else { return }
        guard !state.replyRemindSent, !state.hasHistoryReply else { return }
        guard let baseTs = state.replyRemindBaseTs else { return }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let elapsed = nowMs - baseTs
        let threshold: Int64 = 15 * 60 * 1000
        guard elapsed >= threshold else { return }

        // inject replyRemindTip（时间戳 = baseTs + 15min 位置）
        let tipTs = baseTs + threshold
        let tip = ChatTip(kind: .replyRemind, text: tipText, timestamp: tipTs)
        state.tips.append(tip)
        state.replyRemindSent = true                                // 会话内一次性 sticky
        sessions[peer] = state
        logger.info("[ReplyPoints] replyRemindTip injected peer=\(peer, privacy: .private) tipTs=\(tipTs)")
    }

    // MARK: - 内部：初始 tip 条件判定

    /// guideTip：首次 or 距上次 >24h（对齐 H5 pushPayMsgTip 语义）。跨会话去重。
    private func tryInjectGuideTip(peer: String, text: String, now: Date) {
        let shouldInject: Bool = {
            guard let last = lastGuideTipAt else { return true }
            return now.timeIntervalSince(last) > 24 * 3600
        }()
        guard shouldInject else { return }

        let ts = Int64(now.timeIntervalSince1970 * 1000)
        appendTip(peer: peer, kind: .guide, text: text, timestamp: ts)
        lastGuideTipAt = now
    }

    /// replyPointGuideTip：会话内一次；触发条件 `isOpenPaidMessage && lastUserMsgInfo 存在 && !hasHistoryReply`
    /// 时间戳用 `lastUserMsg.timestamp + 1`（H5 chat/index.vue:823）
    private func tryInjectReplyPointGuideTip(peer: String, text: String, now: Date) {
        guard var state = sessions[peer] else { return }
        guard !state.hasHistoryReply else { return }
        guard let last = state.lastUserMsgInfo else { return }
        // 会话内一次性（若已注入则跳过）
        guard !state.tips.contains(where: { $0.kind == .replyPointGuide }) else { return }

        let tipTs = last.timestamp + 1
        let tip = ChatTip(kind: .replyPointGuide, text: text, timestamp: tipTs)
        state.tips.append(tip)
        sessions[peer] = state
    }

    /// beginSession 时判定：若最后用户消息距今 ≥15min 且 !replyRemindSent → 直接注入
    private func tryInjectReplyRemindTip(peer: String, text: String, now: Date) {
        guard var state = sessions[peer], !state.replyRemindSent, !state.hasHistoryReply,
              let baseTs = state.replyRemindBaseTs else { return }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let threshold: Int64 = 15 * 60 * 1000
        guard nowMs - baseTs >= threshold else { return }

        let tipTs = baseTs + threshold
        let tip = ChatTip(kind: .replyRemind, text: text, timestamp: tipTs)
        state.tips.append(tip)
        state.replyRemindSent = true
        sessions[peer] = state
    }

    // MARK: - 内部：tip append

    private func appendTip(peer: String, kind: ChatTipKind, text: String, timestamp: Int64) {
        var state = sessions[peer] ?? PeerReplyPointsState()
        state.tips.append(ChatTip(kind: kind, text: text, timestamp: timestamp))
        sessions[peer] = state
    }

    // MARK: - 测试辅助（internal，非 public API）

    /// 单测直接注入 sessions[peer] 用于覆盖 replyPointGuide 触发条件（beginSession 无法制造 lastUserMsgInfo）
    func _testSeedSession(peer: String, _ state: PeerReplyPointsState) {
        sessions[peer] = state
    }
}

/// 4 tip L10n 文案打包（Store 层不 import L10n，caller ChatDetailContainer 传入）。
///
/// **对应 L10n key**（v3 §6.5）：
/// - `chat.guideTip`
/// - `chat.stimulateTip`
/// - `chat.replyFastTip` (== replyPointGuide)
/// - `chat.replyRemindTip`
struct ReplyPointsTipTexts: Equatable {
    let guide: String
    let stimulate: String
    let replyPointGuide: String
    let replyRemind: String
}
