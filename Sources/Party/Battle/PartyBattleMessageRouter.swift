import Foundation

/// PartyBattle IM 分发器（spec §5.1 attachType 1100-1112 → PartyBattleStore action 映射）
///
/// 被 `PartyMessageRouter` 转发调用。首次真机 log 校对（F-1a milestone R-16）时
/// 在 `dispatch` 起始处打 `[battle] recv attachType=X dataKeys=[...]` 用于字段名核对。
///
/// 对齐 im-payload-real-log-over-code-assumption rule：字段名首次真机 log 抓取校对；
/// decode 失败 fallback 走 log warning，不 crash。
@MainActor
enum PartyBattleMessageRouter {

    /// 主分发入口。返回 true 表示已识别并分发（无论 payload decode 成败）
    @discardableResult
    static func dispatch(attachType: PartyAttachType, payload: [String: Any]) -> Bool {
        // 保持该 router 对非 Battle 号段的既有语义：不消费、不影响当前状态。
        guard isBattleAttachType(attachType) else { return false }

        // UI 隐藏不足以阻止 IM 延迟消息把 PK 状态重新写回。107（以及未来关闭
        // Party 游戏能力的账号）收到任何 Battle 号段时都必须丢弃，并清理残留状态。
        guard SelfPermissionBridge.shared.gate(.partyGames, action: "partyBattleMessage") else {
            PartyBattleStore.shared.reset()
            return true
        }

        // spec §5.3 首次真机 log 校对 —— dataKeys 一行 print 便于字段名对照
        AppLogger.party.info(
            "[Battle] recv attachType=\(attachType.rawValue, privacy: .public) dataKeys=\(Array(payload.keys).sorted().joined(separator: ","), privacy: .public)")

        let store = PartyBattleStore.shared

        switch attachType {
        case .battleSelectingStart:
            if let p: BattleSelectingStartPayload = decode(payload) {
                // 1100 后可能紧接 1101/1103；必须同一 MainActor turn 写入 SELECTING 态，
                // 否则异步 Task 排队会让后续成员变更因 state=nil 被丢弃。
                store.onSelectingStart(p)
                // H5 party.js:518-523 · 1100 公屏开战预告 · 独立视觉 kind=.selecting
                // 对齐 H5 chat-list.vue :340-343 + selectingMinutes（sec/60, min 1）
                let sec = p.selectingDurationSec ?? 60
                let minutes = max(1, sec / 60)
                PartyStore.shared.chatRouter.postSystemBattle(
                    kind: .selecting,
                    text: L10n.Party.Battle.chatSelectingStart(minutes),
                    highlight: nil
                )
            } else {
                warnDecode(attachType, payload: payload)
            }
            return true

        case .battleTeamMemberChange:
            if let p: BattleTeamMemberChangePayload = decode(payload) {
                store.onTeamMemberChange(p)
            } else {
                warnDecode(attachType, payload: payload)
            }
            return true

        case .battleApplyReceived:
            if let p: BattleApplyPushedPayload = decode(payload) {
                store.upsertApplication(p)
            } else {
                warnDecode(attachType, payload: payload)
            }
            return true

        case .battleRunningStart:
            if let p: BattleRunningStartPayload = decode(payload) {
                store.onRunningStart(p)
            } else {
                warnDecode(attachType, payload: payload)
            }
            return true

        case .battleLeaderboardUpdate:
            if let p: BattleLeaderboardMergedPayload = decode(payload) {
                store.onLeaderboardUpdate(p)
            } else {
                warnDecode(attachType, payload: payload)
            }
            return true

        case .battleCrownHolderUpdate:
            if let p: BattleCrownHolderUpdatePayload = decode(payload) {
                store.onCrownHolderUpdate(p)
            } else {
                warnDecode(attachType, payload: payload)
            }
            return true

        case .battleEnd:
            let p: BattleEndPayload? = decode(payload)
            store.onEnd(p)
            return true

        case .battleBroadcast:
            // 1110 走公屏 kind 分发（对齐 H5 party.js:543-576）
            if let p: BattleBroadcastPayload = decode(payload) {
                AppLogger.party.info("[Battle] 1110 broadcast kind=\(p.kind ?? "nil", privacy: .public)")
                dispatchBroadcast(payload: p)
            } else {
                warnDecode(attachType, payload: payload)
            }
            return true

        case .battleCooldownEnd:
            // 1112 无 payload
            store.onCooldownEnd()
            return true

        case .battleHeartbeat, .battleGiftNotify, .battleForceEndConfirm, .battleApplyPendingNotice:
            // 1104 / 1107 / 1108 / 1111 保留占位（H5/spec 未消费）
            AppLogger.party.warning(
                "[Battle] unhandled reserved attachType=\(attachType.rawValue, privacy: .public) dataKeys=\(Array(payload.keys).sorted().joined(separator: ","), privacy: .public)")
            return true

        default:
            return false  // 非 battle 号段
        }
    }

    private static func isBattleAttachType(_ attachType: PartyAttachType) -> Bool {
        switch attachType {
        case .battleSelectingStart, .battleTeamMemberChange, .battleApplyReceived,
             .battleRunningStart, .battleLeaderboardUpdate, .battleCrownHolderUpdate,
             .battleEnd, .battleBroadcast, .battleCooldownEnd,
             .battleHeartbeat, .battleGiftNotify, .battleForceEndConfirm, .battleApplyPendingNotice:
            return true
        default:
            return false
        }
    }

    /// 1110 broadcast kind 分发（对齐 H5 party.js:543-576 + chat-list.vue :348-392）
    ///
    /// H5 4 kind 完整文案：
    /// - `victory`：team=1|2 → "{Red|Blue Team} wins! Total score {N}" · 其他 → "This is a draw!"
    /// - `force_ended`：文案 "The room ended this PK early"
    /// - `mvp`：文案 "This MVP: {name} ({team}) Personal Gift {total}"
    /// - `selecting_started`：由 1100 单独消息驱动，1110 内忽略避免重复
    private static func dispatchBroadcast(payload p: BattleBroadcastPayload) {
        let router = PartyStore.shared.chatRouter
        switch p.kind {
        case "victory":
            // H5 chat-list.vue :355-361 · winnerTeam=1|2 有文案；否则 "This is a draw!"
            if p.winnerTeam == 1 || p.winnerTeam == 2 {
                let teamLabel = p.winnerTeam == 2 ? L10n.Party.Battle.blueTeam : L10n.Party.Battle.redTeam
                let score = winScoreText(payload: p)
                router.postSystemBattle(
                    kind: .normalEnd,
                    text: "\(L10n.Party.Battle.chatTeamWin(teamLabel)) {h}",
                    highlight: score
                )
            } else {
                router.postSystemBattle(kind: .normalEnd, text: L10n.Party.Battle.chatTie, highlight: nil)
            }
        case "force_ended":
            router.postSystemBattle(kind: .forceEnd, text: L10n.Party.Battle.chatForceEnd, highlight: nil)
        case "mvp":
            // H5 chat-list.vue :387 · "This MVP: {name} ({team}) Personal Gift {total}"
            let name = p.mvpName ?? p.mvpNickname ?? ""
            let teamLabel = p.team == 2 ? L10n.Party.Battle.blueTeam : L10n.Party.Battle.redTeam
            let total = totalGiftText(payload: p)
            router.postSystemBattle(
                kind: .mvp,
                text: "\(L10n.Party.Battle.chatMvp(name: name, team: teamLabel)) {h}",
                highlight: total
            )
        case "selecting_started":
            // 由 1100 单独消息驱动，忽略避免重复（H5 party.js:575 同款注释）
            break
        default:
            AppLogger.party.notice("[Battle] 1110 unhandled kind=\(p.kind ?? "nil", privacy: .public)")
        }
    }

    /// 对齐 H5 chat-list.vue battleWinScore：gems 优先回落 raw score，2 位小数去尾 0
    private static func winScoreText(payload p: BattleBroadcastPayload) -> String {
        // 1110 自带 red/blue score 与 gems（H5 party.js:550-555）。优先读当前消息，
        // 因为它可以早于 1109 到达；仅为历史灰度 payload 回退到 store。
        let store = PartyBattleStore.shared
        let isRedWinner = p.winnerTeam == 1
        let broadcastScore = isRedWinner
            ? (p.redGems?.doubleValue ?? p.redScore?.doubleValue)
            : (p.blueGems?.doubleValue ?? p.blueScore?.doubleValue)
        let settlementScore = isRedWinner
            ? (store.lastSettlement?.redGems?.doubleValue ?? store.lastSettlement?.redScore?.doubleValue)
            : (store.lastSettlement?.blueGems?.doubleValue ?? store.lastSettlement?.blueScore?.doubleValue)
        let currentScore = isRedWinner
            ? (store.state?.redGems?.doubleValue ?? store.state?.redScore.doubleValue)
            : (store.state?.blueGems?.doubleValue ?? store.state?.blueScore.doubleValue)
        let raw = broadcastScore ?? settlementScore ?? currentScore ?? 0
        return trimFractionZero(raw)
    }

    /// mvp 卡 total 文案；1110 的 `total` 是权威值，旧 payload 再回退结算态。
    private static func totalGiftText(payload p: BattleBroadcastPayload) -> String {
        // H5 chat-list.vue :388 · item.total 由 party.js:572 `Number(payload?.total) || 0` 派生。
        let val = p.total?.doubleValue
            ?? PartyBattleStore.shared.lastSettlement?.giftReceiveMvp?.displayValue
            ?? 0
        return trimFractionZero(val)
    }

    /// 保留最多 2 位小数并去尾 0（对齐 H5 `+(n).toFixed(2)` 语义）
    private static func trimFractionZero(_ n: Double) -> String {
        if n.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(n)) }
        let s = String(format: "%.2f", n)
        // 去尾 0
        var trimmed = s
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    /// Codable payload decode 兜底（[String: Any] → Data → Decodable）
    private static func decode<T: Decodable>(_ payload: [String: Any]) -> T? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func warnDecode(_ attachType: PartyAttachType, payload: [String: Any]) {
        AppLogger.party.warning(
            "[Battle] decode failed attachType=\(attachType.rawValue, privacy: .public) dataKeys=\(Array(payload.keys).sorted().joined(separator: ","), privacy: .public)")
    }
}
