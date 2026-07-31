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
        guard Self.messageRewardsAvailable else { return false }
        guard let list = sessions[peer]?.messageBoxList else { return false }
        return !list.isEmpty
    }

    /// 派生 view 用的 tip 列表；ChatDetailView 混入 messagesData 按 stableSortKey 排序
    func tips(for peer: String) -> [ChatTip] {
        guard Self.messageRewardsAvailable else { return [] }
        return sessions[peer]?.tips ?? []
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
        guard Self.gateMessageRewards(action: "replyPointsBeginSession") else {
            endSession(peer: peer)
            return
        }
        do {
            let list = try await service.fetchMessageBoxList(userYxAccid: peer)
            guard Self.messageRewardsAvailable else {
                endSession(peer: peer)
                return
            }
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
        guard Self.messageRewardsAvailable,
              !isGift,
              isOpenPaidMessage(peer: peer) else { return }
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
    /// **P1-1 修**：`msgType` 参数删除 —— API 期望的是**用户上一条消息**的 pay/free 属性
    /// （对齐 H5 `message.js:1108` `msgType: lastMsg.msgType`），不是主播这次回复的媒介类型。
    /// 内部从 `last.msgType` 派生传给后端。
    func onSendAnchorMsg(peer: String) async {
        guard var state = sessions[peer],
              let last = state.lastUserMsgInfo
        else { return }

        guard Self.messageRewardsAvailable else {
            state.lastUserMsgInfo = nil
            sessions[peer] = state
            return
        }

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
                msgType: last.msgType   // P1-1：传用户消息的 pay/free（对齐 H5 line 1108 lastMsg.msgType），已在 onReceiveUserMsg 里 ?? "pay" 兜底
            )
            guard Self.messageRewardsAvailable else { return }
            if res.settled {
                // M-7:整块回写 stale state 会覆盖并发的 autoClaimIfNeeded / checkReplyRemindTrigger 修改
                // (settle 挂起窗口内 messageBoxList 可能被 auto-claim 改成 .claimed / tips 追加 replyRemind)
                // 只更新本次结算相关的 3 个字段,从 sessions[peer] 读最新态,避免整块覆盖
                var s = sessions[peer] ?? state
                s.currentProgress = res.currentTotalPoints       // 权威覆盖
                s.hasHistoryReply = true
                s.replyRemindBaseTs = nil                          // 取消 15min timer
                sessions[peer] = s
                pendingSettleResult = res                              // 触发 view 跳跃动画
                logger.info("[ReplyPoints] settle success peer=\(peer, privacy: .private) points=\(res.points) total=\(res.currentTotalPoints)")
                // P1-4：settle 成功后重新拉 messageBoxList 检查跨节点变 claimable → auto-claim
                // 对齐 H5 rewardProgress.vue:81-89 watch(currentProgress) → handleGetMessageBox → getAnchorMessageBox
                await refreshMessageBoxAndAutoClaim(peer: peer)
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
        guard Self.messageRewardsAvailable else { return }
        guard let items = sessions[peer]?.messageBoxList else { return }
        var totalClaimedDiamond = 0
        for (idx, item) in items.enumerated() where item.status == .claimable {
            guard Self.messageRewardsAvailable else { return }
            do {
                let diamond = try await service.claimTreasureBox(userYxAccid: peer)
                guard Self.messageRewardsAvailable else { return }
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

    // MARK: - 历史消息 hydrate（P1-2：对齐 H5 initReplyRemindOnEnter）

    /// **P1-2 修**：进入会话时从 P2PChatStore.load 拉到的历史消息补 lastUserMsgInfo，
    /// 对齐 H5 `chat/index.vue:788-836 initReplyRemindOnEnter`。
    ///
    /// **调用时机**：P2PChatStore.load 成功后（`state = .loaded(msgs)` 之后）。
    ///
    /// **短路条件**：
    /// - `sessions[peer] == nil` —— beginSession 未跑或非付费会话（下次 begin/receive 会补）
    /// - `state.lastUserMsgInfo != nil` —— 实时收到过用户消息，不覆盖已有值
    ///
    /// **行为**：
    /// 1. 从 msgs 反向找 last `!isOutgoing && !isGift` 消息作为 "用户上一条消息"
    /// 2. 派生 hasHistoryReply（该消息之后是否有主播回复，对齐 H5 line 807-813）
    /// 3. 赋 lastUserMsgInfo / replyRemindBaseTs 到 sessions[peer]
    /// 4. 重跑 tryInjectReplyPointGuideTip + tryInjectReplyRemindTip 判定
    func hydrateLastUserMsgFromHistory(
        peer: String,
        msgs: [ChatMessage],
        tipTexts: ReplyPointsTipTexts,
        now: Date = Date()
    ) {
        guard Self.messageRewardsAvailable else { return }
        guard var state = sessions[peer] else { return }
        guard state.lastUserMsgInfo == nil else { return }
        guard let last = msgs.reversed().first(where: { m in
            !m.isOutgoing && !Self.isGiftContent(m.content)
        }) else { return }

        // hasHistoryReply：last 消息之后是否有主播回复（H5 chat/index.vue:807-813）
        if let idx = msgs.lastIndex(where: { $0.id == last.id }),
           msgs.index(after: idx) < msgs.endIndex {
            state.hasHistoryReply = msgs[msgs.index(after: idx)...].contains(where: { $0.isOutgoing })
        }
        state.lastUserMsgInfo = LastUserMsgInfo(
            msgId: last.id,
            timestamp: last.timestamp,
            msgType: last.msgType ?? "pay",   // 缺失兜底 pay（对齐 H5 line 802 `|| 'pay'`）
            isGift: false
        )
        state.replyRemindBaseTs = last.timestamp
        sessions[peer] = state

        if isOpenPaidMessage(peer: peer) {
            tryInjectReplyPointGuideTip(peer: peer, text: tipTexts.replyPointGuide, now: now)
            tryInjectReplyRemindTip(peer: peer, text: tipTexts.replyRemind, now: now)
        }
    }

    private static func isGiftContent(_ content: ChatMessageContent) -> Bool {
        if case .systemGift = content { return true }
        return false
    }

    // MARK: - 跨节点 auto-claim（P1-4：对齐 H5 rewardProgress watch(currentProgress)）

    /// **P1-4 修**：settle 成功后重新拉 messageBoxList，把可能刚跨过阈值变 `.claimable` 的节点领掉。
    /// 对齐 H5 `rewardProgress.vue:81-89 watch(currentProgress) → handleGetMessageBox → getAnchorMessageBox`。
    ///
    /// 失败静默：下次 settle 再重试；网络错也不打断主结算成功日志。
    private func refreshMessageBoxAndAutoClaim(peer: String) async {
        guard Self.messageRewardsAvailable else { return }
        do {
            let list = try await service.fetchMessageBoxList(userYxAccid: peer)
            guard Self.messageRewardsAvailable else { return }
            guard var state = sessions[peer] else { return }
            // 只更新 messageBoxList,currentProgress 已由 settle 权威覆盖不动
            state.messageBoxList = list.pointInfoList
            sessions[peer] = state
            await autoClaimIfNeeded(peer: peer)
        } catch {
            logger.warning("[ReplyPoints] refreshMessageBox failed peer=\(peer, privacy: .private): \(String(describing: error), privacy: .public)")
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
        guard Self.messageRewardsAvailable else { return }
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

    /// 回复奖励会结算并领取钻石，107 及未来关闭虚拟道具的账号一律不进入该业务流。
    private static var messageRewardsAvailable: Bool {
        #if HILY_TESTS
        return true
        #else
        return SelfPermissionBridge.shared.canVirtualItemsSnapshot
        #endif
    }

    private static func gateMessageRewards(action: String) -> Bool {
        #if HILY_TESTS
        return true
        #else
        return SelfPermissionBridge.shared.gate(.virtualItems, action: action)
        #endif
    }

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
