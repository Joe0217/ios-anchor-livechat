import Foundation
import SwiftUI
import os

/// PartyBattle 状态机 Store（对齐 H5 partyBattle.ts 语义）
///
/// F-1a Task 8：骨架 + 派生 getter + effectiveRoomId + 5 态迁移守卫
/// Task 9 加：onSelectingStart 侵入 PartyStore.clearGiftValueCount
/// Task 10a-c 加：tickLeft / cooldown ticker / 200ms 聚合 / preservePersonal / onEnd 三分类
/// Task 10d 加：refreshIfNeeded / loadTemplatesIfNeeded 入口 action
///
/// **DI**：`service` 走 `PartyBattleServiceProtocol`；`roomEnv` 走 `PartyRoomEnvironment` 抽象访问 PartyStore.shared 单例，
/// 测试注入 `MockPartyRoomEnvironment` 隔离 PartyStore 依赖。
@MainActor
final class PartyBattleStore: ObservableObject {
    static let shared = PartyBattleStore()

    // MARK: - Published state

    @Published private(set) var state: PartyBattleState?
    @Published private(set) var pkId: String = ""
    @Published private(set) var selectingDurationSec: Int = 0
    @Published private(set) var durationSec: Int = 0
    @Published private(set) var leftSec: Int = 0
    @Published private(set) var templateName: String = ""
    @Published private(set) var cooldownLeftSec: Int = 0
    /// spec §1.1 兜底优先级：settlement.cooldownLeftSec > store.cooldownDurationSec > 60s FALLBACK
    @Published private(set) var cooldownDurationSec: Int = 60
    @Published private(set) var lastSettlement: PartyBattleSettlementResponse?
    @Published private(set) var showSettlement: Bool = false
    @Published private(set) var forceEnding: Bool = false
    @Published private(set) var pendingApplications: [PartyBattleApplication] = []
    @Published private(set) var totalSwitch: Int = 1
    @Published private(set) var templates: [PartyBattleTemplate] = []
    /// 最近一次 PK 操作失败原因。由对应交互留在原界面展示，避免失败后静默或误关闭弹窗。
    @Published private(set) var actionError: String?
    /// `roomEnv.selfRole` 是派生值，不会自行发出 Combine 事件；角色变更时递增以刷新仅观察 battleStore 的 PK 子视图。
    @Published private(set) var permissionRevision: Int = 0

    // MARK: - Internal side-effect state（Task 10a-c 填充）

    var cooldownTimer: Timer?
    var pendingLeaderboardPayload: BattleLeaderboardMergedPayload?
    var leaderboardFlushTask: Task<Void, Never>?
    /// 每次退房或新场 PK 开始时递增；异步 REST 回包必须命中同一版本才允许写回单例状态。
    private var stateRevision: UInt = 0

    // MARK: - DI

    let service: PartyBattleServiceProtocol
    let roomEnv: PartyRoomEnvironment

    init(
        service: PartyBattleServiceProtocol = PartyBattleService.shared,
        roomEnv: PartyRoomEnvironment = PartyStoreEnvironmentAdapter()
    ) {
        self.service = service
        self.roomEnv = roomEnv
    }

    // MARK: - 5 态派生 getter

    var isSelecting: Bool { state?.status == .selecting }
    var isRunning: Bool { state?.status == .running }
    var isEnded: Bool { state?.status == .ended }
    var isCoolingDown: Bool { cooldownLeftSec > 0 }
    var isFunctionEnabled: Bool { totalSwitch == 1 }

    // MARK: - Room fallback (spec §4.2)

    /// 房间 ID —— state.roomId=0 占位时 fallback 到 roomEnv.roomId
    var effectiveRoomId: Int64 {
        if let s = state, s.roomId > 0 { return s.roomId }
        return roomEnv.roomId
    }

    // MARK: - Permissions (spec §12 A1/A2)

    /// 是否可点 PK 入口：房主/房管 + roomTempId=1 (Battle Team 模板) + 全局开关 on + 非 running/cooldown
    var canStartPk: Bool {
        canManage
            && isFunctionEnabled
            && roomEnv.roomTempId == 1
            && !isRunning
            && !isCoolingDown
    }

    /// 是否可管理（发起/审批/强制结束 PK）
    var canManage: Bool {
        let r = roomEnv.selfRole
        return r == .owner || r == .admin
    }

    /// Party 房间收到角色变更广播后调用，确保 PK 管理控件立即按最新权限重绘。
    func refreshPermissions() {
        permissionRevision &+= 1
    }

    func clearActionError() {
        actionError = nil
    }

    // MARK: - Score display (spec §4.3 gems fallback getter)

    var redScoreDisplay: Double {
        let bothGems = state?.redGems != nil && state?.blueGems != nil
        return bothGems
            ? (state?.redGems?.doubleValue ?? 0)
            : (state?.redScore.doubleValue ?? 0)
    }

    var blueScoreDisplay: Double {
        let bothGems = state?.redGems != nil && state?.blueGems != nil
        return bothGems
            ? (state?.blueGems?.doubleValue ?? 0)
            : (state?.blueScore.doubleValue ?? 0)
    }

    // MARK: - Team members (UI 消费)

    var redMembers: [BattleMember] { state?.redTeam.members ?? [] }
    var blueMembers: [BattleMember] { state?.blueTeam.members ?? [] }

    /// 视频位红蓝色边（RUNNING 期）—— Task 20.5 落地时补 slotIdx ↔ seatIndex 映射；F-1a Task 8 返回 nil 占位
    func pkVideoSlotTeamClass(_ slotIdx: Int) -> Color? {
        // Task 20.5 依赖 Task 11.5 `PartyBattleSeatLayout` slot ↔ seatIndex 映射
        return nil
    }

    // MARK: - Sheet binding (SwiftUI)

    var showSettlementBinding: Binding<Bool> {
        Binding(
            get: { self.showSettlement },
            set: { self.showSettlement = $0 }
        )
    }

    // MARK: - State transition guard (spec §3.3)

    /// 应用 status 迁移；违反 §3.3 非法迁移矩阵仅 log warning 不 apply
    func applyStatus(_ target: PartyBattleStatus) {
        guard var s = state else {
            AppLogger.party.warning("[Battle] applyStatus \(target.rawValue) rejected: state nil")
            return
        }
        let from = s.status
        guard Self.isLegalTransition(from: from, to: target) else {
            AppLogger.party.warning(
                "[Battle] illegal transition \(from.rawValue) → \(target.rawValue)")
            return
        }
        s.status = target
        state = s
    }

    /// spec §3.3 状态迁移合法性判定
    static func isLegalTransition(
        from: PartyBattleStatus, to: PartyBattleStatus
    ) -> Bool {
        // 同态可以（用于 setStatus 校验）
        if from == to { return true }
        switch (from, to) {
        // RUNNING → SELECTING 明确非法（不允许倒退）
        case (.running, .selecting): return false
        // SELECTING → COOLDOWN 明确非法（必须先经 RUNNING）
        case (.selecting, .cooldown): return false
        // ENDED / FORCE_ENDED → RUNNING / SELECTING(除外 idle 重开)：spec §3.3
        //   ended → selecting ✅ (重开一场新 PK)
        //   ended → running ❌
        //   ended → forceEnded ❌ (不能从自然结束改强制)
        case (.ended, .running): return false
        case (.ended, .forceEnded): return false
        case (.forceEnded, .running): return false
        case (.forceEnded, .ended): return false
        // 其他默认合法
        default: return true
        }
    }
}

private extension PartyBattleStore {
    func invalidateStateRequests() {
        stateRevision &+= 1
    }

    func battleErrorMessage(_ error: Error, fallback: String) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }

    /// IM 可能在本场结束、重连或下一场开始后延迟抵达。无 pkId 的历史 payload 仍兼容，
    /// 但明确携带且与当前不同的 pkId 绝不能污染当前状态。
    func acceptsCurrentPkEvent(_ incomingPkId: String?) -> Bool {
        guard let incomingPkId, !incomingPkId.isEmpty else { return true }
        guard !pkId.isEmpty else { return true }
        guard incomingPkId == pkId else {
            AppLogger.party.notice(
                "[Battle] dropped stale event pkId=\(incomingPkId, privacy: .public) current=\(self.pkId, privacy: .public)")
            return false
        }
        return true
    }

    /// 1100 是新场开始事件；活跃场中收到另一 pkId 的 1100 视为延迟/错误消息，
    /// 避免清空正在进行的 PK。已结束或冷却中的新场则允许覆盖。
    func acceptsSelectingEvent(_ incomingPkId: String?) -> Bool {
        guard let incomingPkId, !incomingPkId.isEmpty else { return true }
        guard isSelecting || isRunning, !pkId.isEmpty, incomingPkId != pkId else { return true }
        AppLogger.party.notice(
            "[Battle] dropped stale selecting pkId=\(incomingPkId, privacy: .public) current=\(self.pkId, privacy: .public)")
        return false
    }

    func isCurrentAsyncRequest(revision: UInt, roomId: Int64, pkId expectedPkId: String? = nil) -> Bool {
        guard revision == stateRevision, roomId > 0, roomEnv.roomId == roomId else { return false }
        if let expectedPkId, !expectedPkId.isEmpty {
            return pkId == expectedPkId
        }
        return true
    }
}

// MARK: - PartyRoomEnvironment abstraction (spec §12 A1 依赖注入)

/// PartyBattleStore 对 PartyStore.shared 的依赖抽象层
///
/// 测试注入 `MockPartyRoomEnvironment` 隔离 PartyStore 具体实现（避免测试拉整个 PartyStore.selfRole 派生链）
protocol PartyRoomEnvironment: AnyObject {
    var selfRole: PartyRoomRoleType { get }
    var roomTempId: Int { get }
    var roomId: Int64 { get }
    /// H5 initiatePopup.vue :44-47：发起人是否已在麦（在麦时不显示队伍选择，队伍由麦位决定）
    var isSelfOnMic: Bool { get }
    /// H5 initiatePopup.vue :96-99：占位麦位人数（供提示文案 `initiateHint` 显示 lobbyMicCount）
    var lobbyMicCount: Int { get }
    /// F-1a v2 (2026-07-17)：清**所有已占麦位** giftValueCount（对齐 H5 partyBattle.ts:332-336）
    func resetAllSeatGiftValue()
}

/// 生产环境 adapter —— 直读 PartyStore.shared
final class PartyStoreEnvironmentAdapter: PartyRoomEnvironment {
    @MainActor
    var selfRole: PartyRoomRoleType { PartyStore.shared.selfRole }

    @MainActor
    var roomTempId: Int { PartyStore.shared.roomInfo?.roomTempIdInt ?? 0 }

    @MainActor
    var roomId: Int64 {
        guard let idStr = PartyStore.shared.roomInfo?.id, !idStr.isEmpty else { return 0 }
        return Int64(idStr) ?? 0
    }

    @MainActor
    var isSelfOnMic: Bool { PartyStore.shared.selfSeat != nil }

    @MainActor
    var lobbyMicCount: Int {
        PartyStore.shared.seatList.filter { $0.userId != nil }.count
    }

    @MainActor
    func resetAllSeatGiftValue() {
        PartyStore.shared.resetAllSeatGiftValue()
    }
}

// MARK: - DEBUG-only test hooks

// MARK: - Public actions（UI 调用）

extension PartyBattleStore {

    /// 房主发起 PK（InitiatePopup Confirm 时调）
    ///
    /// 对齐 H5 partyBattle.ts:120-142 `onInitiateSuccess`：成功后本地立即构造 SELECTING state
    /// 让 UI 立即响应（不必等 IM 1100 到达）；IM 1100 到达后 `onSelectingStart` 会 merge 覆盖完整字段。
    @discardableResult
    func start(templateId: String, durationSec: Int, hostInitialTeam: Int?) async -> Bool {
        clearActionError()
        guard canManage, isFunctionEnabled, roomEnv.roomTempId == 1 else {
            AppLogger.party.warning("[Battle] start rejected: insufficient permission or battle disabled")
            actionError = "PK is unavailable in this room."
            return false
        }
        let rid = effectiveRoomId
        guard rid > 0 else {
            AppLogger.party.warning("[Battle] start rejected: roomId=0")
            actionError = "Unable to start PK. Please re-enter the room and try again."
            return false
        }
        let requestRevision = stateRevision
        do {
            let req = PartyBattleStartRequest(
                roomId: String(rid),
                templateId: templateId,
                durationSec: durationSec,
                hostInitialTeam: hostInitialTeam
            )
            let resp = try await service.start(req)
            guard requestRevision == stateRevision, roomEnv.roomId == rid else {
                AppLogger.party.notice("[Battle] start response dropped: room/session changed")
                actionError = "Room changed. Please try again."
                return false
            }
            // 本地构造 SELECTING state（H5 partyBattle.ts:120-142 onInitiateSuccess 语义）
            // 关键字段全部从 response 拿（对齐 H5 line 122-126），入参兜底：
            // - selectingDurationSec：服务端 override 用户默认 60
            // - durationSec：服务端可能 override 用户选值
            // - templateName：HUD 展示用
            if let pk = resp?.pkId, !pk.isEmpty {
                AppLogger.party.info("[Battle] start OK templateId=\(templateId, privacy: .public) dur=\(durationSec, privacy: .public)")
                onInitiateSuccess(
                    pkId: pk,
                    battleId: resp?.battleId ?? 0,
                    templateId: Int(templateId),
                    templateName: resp?.templateName,
                    selectingDurationSec: resp?.selectingDurationSec ?? 60,
                    durationSec: resp?.durationSec ?? durationSec
                )
                return true
            }
            // 此端点在部分环境成功时只返回空 result，实际 PK 状态由 1100 IM 广播或
            // /state 同步提供。HTTP 成功不能因缺 pkId 被误报为发起失败并阻止关闭 sheet。
            AppLogger.party.notice("[Battle] start accepted without pkId; waiting for state sync")
            Task { [weak self] in
                await self?.refreshIfNeeded(roomId: String(rid))
            }
            return true
        } catch {
            AppLogger.party.error("[Battle] start failed: \(String(describing: error), privacy: .public)")
            actionError = battleErrorMessage(error, fallback: "Unable to start PK. Please try again.")
            return false
        }
    }

    /// H5 partyBattle.ts:120-142 onInitiateSuccess 语义 —— 房主本地构造 SELECTING state
    private func onInitiateSuccess(
        pkId: String,
        battleId: Int,
        templateId: Int?,
        templateName: String?,
        selectingDurationSec: Int,
        durationSec: Int
    ) {
        _resetForNewBattle()
        self.pkId = pkId
        self.selectingDurationSec = selectingDurationSec
        self.durationSec = durationSec
        self.templateName = templateName ?? ""
        self.leftSec = selectingDurationSec
        // roomId=0 占位（H5 partyBattle.ts:129），后续 refresh 或 IM 1100 会覆盖真实值
        state = Self.makeSelectingState(
            pkId: pkId, battleId: battleId, roomId: 0, hostUid: 0, hostRole: 1,
            templateId: templateId, templateName: templateName,
            selectingDurationSec: selectingDurationSec, durationSec: durationSec, leftSec: selectingDurationSec,
            redTeam: BattleTeam(count: 0, members: []),
            blueTeam: BattleTeam(count: 0, members: []),
            neutral: BattleTeam(count: 0, members: []),
            redTop: [], blueTop: []
        )
    }

    /// 切队（观众/主播端参战方在 SELECTING/RUNNING 期切红蓝）
    func switchTeam(targetTeam: Int) async {
        guard !pkId.isEmpty, targetTeam == 1 || targetTeam == 2,
              isSelecting || isRunning else { return }
        do {
            try await service.switchTeam(PartyBattleSwitchTeamRequest(pkId: pkId, targetTeam: targetTeam))
        } catch {
            AppLogger.party.error("[Battle] switchTeam failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 房主提前进入 RUNNING（SELECTING 期 "Start Now"）
    @discardableResult
    func startNow() async -> Bool {
        clearActionError()
        guard !pkId.isEmpty, canManage, isSelecting else {
            actionError = "This PK is no longer waiting to start."
            return false
        }
        let requestPkId = pkId
        let requestRevision = stateRevision
        do {
            try await service.startNow(requestPkId)
            guard requestRevision == stateRevision, pkId == requestPkId else {
                AppLogger.party.notice("[Battle] startNow response dropped: PK/session changed")
                actionError = "PK state changed. Please try again."
                return false
            }
            // 与主播端一致：不等待可能延迟或丢失的 1103，先本地切 RUNNING，随后 /state 对账。
            onRunningStart(BattleRunningStartPayload(
                pkId: requestPkId,
                durationSec: durationSec,
                leftSec: durationSec
            ))
            let rid = effectiveRoomId
            if rid > 0 {
                await refreshIfNeeded(roomId: String(rid))
            }
            return true
        } catch {
            AppLogger.party.error("[Battle] startNow failed: \(String(describing: error), privacy: .public)")
            actionError = battleErrorMessage(error, fallback: "Unable to start PK. Please try again.")
            return false
        }
    }

    /// 房主强制结束（RUNNING 期 ForceEndConfirm）
    @discardableResult
    func forceEnd() async -> Bool {
        clearActionError()
        guard !pkId.isEmpty, canManage, isRunning else {
            actionError = "This PK is no longer active."
            return false
        }
        let requestPkId = pkId
        let requestRevision = stateRevision
        forceEnding = true
        defer { forceEnding = false }
        do {
            try await service.forceEnd(requestPkId)
            guard requestRevision == stateRevision, pkId == requestPkId else {
                AppLogger.party.notice("[Battle] forceEnd response dropped: PK/session changed")
                actionError = "PK state changed. Please try again."
                return false
            }
            // 主播端在接口成功后立刻展示结算；不能只等 1109，否则 IM 延迟时仍停在 RUNNING。
            do {
                let settlement = try await service.fetchSettlement(requestPkId)
                guard requestRevision == stateRevision, pkId == requestPkId else {
                    AppLogger.party.notice("[Battle] forceEnd settlement dropped: PK/session changed")
                    return true
                }
                onEnd(BattleEndPayload(
                    pkId: settlement.pkId,
                    winnerTeam: settlement.winnerTeam,
                    endedEarly: settlement.endedEarly,
                    cooldownLeftSec: settlement.cooldownLeftSec,
                    durationSec: settlement.durationSec,
                    redScore: settlement.redScore,
                    blueScore: settlement.blueScore,
                    redGems: settlement.redGems,
                    blueGems: settlement.blueGems
                ))
                // `onEnd` 先处理状态和副作用；随后回填 API 的完整 MVP / Top3 数据，避免结算页首帧缺失。
                lastSettlement = settlement
                showSettlement = true
            } catch {
                AppLogger.party.warning("[Battle] forceEnd settlement unavailable; await IM end: \(String(describing: error), privacy: .private)")
                // 接口已成功结束，先关闭 PK 主态和清理本场麦位收礼值；1109 会补齐完整结算。
                onEnd(nil)
            }
            return true
        } catch {
            AppLogger.party.error("[Battle] forceEnd failed: \(String(describing: error), privacy: .public)")
            actionError = battleErrorMessage(error, fallback: "Unable to end PK. Please try again.")
            return false
        }
    }

    /// 房主审批观众申请（同意/拒绝）
    ///
    /// H5 partyBattle.ts:267-275：**RUNNING 阶段 approve 通过后主动 refresh 一次**
    /// 因后端 RUNNING 期审核通过后无专门推送（1101 仅 SELECTING），refresh 拉回 redTeam/blueTeam 让 UI 立刻看到新人
    func approveApply(applyId: Int, approve: Bool) async {
        guard !pkId.isEmpty, applyId > 0, canManage else { return }
        do {
            try await service.approveApply(
                PartyBattleApproveApplyRequest(pkId: pkId, applyId: applyId, approve: approve))
            pendingApplications.removeAll { $0.applyId == applyId }
            // RUNNING 期 approve 通过后主动 refresh 拉最新 redTeam/blueTeam
            if approve && isRunning {
                let rid = effectiveRoomId
                if rid > 0 { await refreshIfNeeded(roomId: String(rid)) }
            }
        } catch {
            AppLogger.party.error("[Battle] approveApply failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// H5 partyBattle.ts:211-225 loadApplications —— 房主/房管拉取待审申请列表
    /// 权限不足后端返空 list，前端统一覆盖；接口异常保留本地 IM 累加不覆盖
    func loadApplications(roomId: String) async {
        guard let requestedRoomId = Int64(roomId), requestedRoomId > 0 else { return }
        let requestRevision = stateRevision
        let requestPkId = pkId
        do {
            let resp = try await service.fetchApplications(roomId)
            guard isCurrentAsyncRequest(
                revision: requestRevision,
                roomId: requestedRoomId,
                pkId: requestPkId
            ) else {
                AppLogger.party.notice("[Battle] applications response dropped: room/PK changed")
                return
            }
            pendingApplications = resp.list
        } catch {
            AppLogger.party.error("[Battle] loadApplications failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 观众申请上麦（PartyRoomView 观众端麦位排队入口调）
    func applyMic(desiredTeam: Int?, desiredMicId: Int?) async {
        guard !pkId.isEmpty else { return }
        do {
            _ = try await service.applyMic(
                PartyBattleApplyMicRequest(pkId: pkId, desiredTeam: desiredTeam, desiredMicId: desiredMicId))
        } catch {
            AppLogger.party.error("[Battle] applyMic failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 1102 到达时更新 pendingApplications（观众端也收但 UI 层由 canManage 门控）
    func upsertApplication(_ payload: BattleApplyPushedPayload) {
        guard acceptsCurrentPkEvent(payload.pkId) else { return }
        guard let applyId = payload.applyId, let uid = payload.uid else { return }
        let item = PartyBattleApplication(
            applyId: applyId,
            uid: uid,
            nickname: payload.nickname,
            avatar: payload.avatar,
            desiredTeam: payload.desiredTeam,
            desiredMicId: payload.desiredMicId,
            createdAt: payload.createdAt
        )
        if let i = pendingApplications.firstIndex(where: { $0.applyId == applyId }) {
            pendingApplications[i] = item
        } else {
            pendingApplications.append(item)
        }
    }

    /// F-1a 全局开关拉取（PartyStore 进房 enterRoom 成功后调）
    func loadGlobalConfig() async {
        do {
            if let cfg = try await service.fetchGlobalConfig() {
                totalSwitch = cfg.totalSwitch
                if let cd = cfg.cooldownDurationSec { cooldownDurationSec = cd }
            }
        } catch {
            AppLogger.party.error("[Battle] loadGlobalConfig failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Task 10a · tickLeft + cooldown ticker

extension PartyBattleStore {

    /// F-1a Task 10a：View 层每秒调，SELECTING/RUNNING 期 leftSec 递减
    /// spec §3.4.3 tickLeft 三段路径：
    /// - SELECTING 归零 → onRunningStart 本地兜底进 RUNNING
    /// - RUNNING 归零 → onEnd(null) → refresh(roomId) → fetchSettlement 覆盖 cooldownLeftSec
    func tickLeft() {
        guard leftSec > 0 else { return }
        leftSec -= 1
        if var s = state {
            s.leftSec = leftSec
            state = s
        }
        guard leftSec == 0 else { return }
        switch state?.status {
        case .selecting:
            onRunningStart(BattleRunningStartPayload(pkId: pkId, durationSec: durationSec, leftSec: durationSec))
        case .running:
            onEnd(nil)
            let rid = effectiveRoomId
            if rid > 0 {
                Task { [weak self] in
                    await self?.refreshIfNeeded(roomId: String(rid))
                }
            }
            let pk = pkId
            let requestRevision = stateRevision
            guard !pk.isEmpty else { return }
            Task { [weak self] in
                guard let self else { return }
                if let s = try? await self.service.fetchSettlement(pk) {
                    guard self.stateRevision == requestRevision, self.pkId == pk else {
                        AppLogger.party.notice("[Battle] timeout settlement dropped: PK/session changed")
                        return
                    }
                    self.lastSettlement = s
                    if let cd = s.cooldownLeftSec, cd > 0 {
                        self.cooldownLeftSec = cd
                        self.startCooldownTicker()
                    }
                }
            }
        default:
            break
        }
    }

    /// spec §3.4.5 cooldown ticker — Timer 挂 store 级属性，独立 View 生命周期
    func startCooldownTicker() {
        guard cooldownTimer == nil else { return }
        guard cooldownLeftSec > 0 else { return }
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.cooldownLeftSec > 0 { self.cooldownLeftSec -= 1 }
                if self.cooldownLeftSec <= 0 { self.stopCooldownTicker(); self.onCooldownEnd() }
            }
        }
    }

    func stopCooldownTicker() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
    }

    /// 1112 cooldownEnd 或 ticker 归零触发（对齐 H5 partyBattle.ts:668-671）
    ///
    /// 只清 cooldownLeftSec + 停 ticker，**不清 showSettlement**：
    /// 结算 popup 由用户手动关闭（对齐 H5 `closeSettlement` action），冷却结束不应误关正在看的结算页
    func onCooldownEnd() {
        cooldownLeftSec = 0
        stopCooldownTicker()
    }

    /// 用户主动关闭结算 popup（对齐 H5 partyBattle.ts:571-573 closeSettlement）
    func closeSettlement() {
        showSettlement = false
    }

    /// 退房清理（对齐 H5 partyBattle.ts:672-692 reset）
    ///
    /// **必须在 `PartyStore.resetState()` 里调**：退房 / 切房 / 被踢 / 强制离房时清 battle 残留状态，
    /// 否则下次进新房上一场 PK 的 sheet / 冷却态 / pending 申请会脏读污染。
    ///
    /// **不清的字段**（对齐 H5）：`cooldownDurationSec / totalSwitch / templates`
    /// —— 这些是跨场配置（进房时 loadGlobalConfig + loadTemplatesIfNeeded 会更新），保留可加速下次进房
    func reset() {
        invalidateStateRequests()
        stopCooldownTicker()
        // 200ms 聚合定时器 + pending payload 清理（H5 partyBattle.ts:676-681）
        leaderboardFlushTask?.cancel()
        leaderboardFlushTask = nil
        pendingLeaderboardPayload = nil

        // 14 个 state 字段清（对齐 H5 partyBattle.ts:682-691）
        state = nil
        pkId = ""
        leftSec = 0
        selectingDurationSec = 0
        durationSec = 0
        templateName = ""
        cooldownLeftSec = 0
        lastSettlement = nil
        showSettlement = false
        forceEnding = false
        pendingApplications = []
        actionError = nil
        AppLogger.party.info("[Battle] reset (leave room)")
    }
}

// MARK: - Task 10b · 200ms trailing 聚合（1105） + preservePersonal（1101）

extension PartyBattleStore {

    private static var leaderboardAggregateMS: UInt64 { 200 }

    /// spec §3.4.4 · 1105 → 200ms trailing 聚合入口
    /// **trailing 语义**：首条到达设 200ms 后 flush 定时器；后续到达合并字段但**不重置定时器**
    ///
    /// 老版兼容（对齐 H5 partyBattle.ts:454-457）：若 payload 带老版本 `team + teamScore`，
    /// 立刻翻译为 redScore/blueScore 再合并到 pending，避免后到的另一队 payload 通过合并覆盖
    /// 掉前一队的 team 字段（老 red 100 + 老 blue 80 直接合并会让 team=2 覆盖 team=1，flush 时
    /// 只会写 blueScore=80，红队 100 丢失）
    func onLeaderboardUpdate(_ payload: BattleLeaderboardMergedPayload) {
        guard acceptsCurrentPkEvent(payload.pkId) else { return }
        let normalized = Self.normalizeLegacyTeamScore(payload)
        // 合并字段到 pending
        var merged = pendingLeaderboardPayload ?? BattleLeaderboardMergedPayload(pkId: normalized.pkId)
        merged = merged.mergedWith(normalized)
        pendingLeaderboardPayload = merged

        // 已有 flush task 时不重置
        guard leaderboardFlushTask == nil else { return }
        leaderboardFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.leaderboardAggregateMS * 1_000_000)
            guard let self else { return }
            let m = self.pendingLeaderboardPayload
            self.pendingLeaderboardPayload = nil
            self.leaderboardFlushTask = nil
            if let m = m { self.applyLeaderboardUpdate(m) }
        }
    }

    /// H5 老版兼容：`team=1 + teamScore` → redScore=teamScore；`team=2 + teamScore` → blueScore=teamScore
    /// 让下游合并/写入统一按 redScore/blueScore 字段处理，不需要在每个合并点重复判断
    private static func normalizeLegacyTeamScore(_ p: BattleLeaderboardMergedPayload) -> BattleLeaderboardMergedPayload {
        guard let team = p.team, let ts = p.teamScore else { return p }
        return BattleLeaderboardMergedPayload(
            pkId: p.pkId,
            redScore: team == 1 ? ts : p.redScore,
            blueScore: team == 2 ? ts : p.blueScore,
            redGems: p.redGems,
            blueGems: p.blueGems,
            redCrownUid: p.redCrownUid,
            blueCrownUid: p.blueCrownUid,
            redTop: p.redTop,
            blueTop: p.blueTop,
            team: nil,        // 已翻译；下游不再看 team/teamScore
            teamScore: nil
        )
    }

    /// 200ms 到期 flush：把合并的红蓝分数/gems/crown 覆盖到 state；
    /// 尾部触发 refresh(/state) 拉最新 Top3（对齐 H5 partyBattle.ts:493-500）
    ///
    /// H5 注释："1105 不带 redTop/blueTop 增量，hostBottomMarquee 的送礼 Top3 依赖 state.redTop/blueTop，
    /// 每次都 refresh /state 拉回最新 Top3；上层已经在 onLeaderboardUpdate 做了 200ms 聚合，
    /// 同一动作触发的多条 1105 已合并为一次 commit，这里不再做额外节流"
    private func applyLeaderboardUpdate(_ merged: BattleLeaderboardMergedPayload) {
        if var s = state {
            if let rs = merged.redScore { s.redScore = rs }
            if let bs = merged.blueScore { s.blueScore = bs }
            if let rg = merged.redGems { s.redGems = rg }
            if let bg = merged.blueGems { s.blueGems = bg }
            if let rc = merged.redCrownUid { s.redCrownUid = rc }
            if let bc = merged.blueCrownUid { s.blueCrownUid = bc }
            if let rt = merged.redTop { s.redTop = rt }
            if let bt = merged.blueTop { s.blueTop = bt }
            state = s
        }
        // H5 partyBattle.ts:496-500 · state=nil（客态 g-agora-party.vue immediate refresh 未返回）时
        // 若直接 return，Top3 永远停留在空；触发 refresh 时从 effectiveRoomId 兜底取 roomId
        let rid = effectiveRoomId
        if rid > 0 {
            Task { [weak self] in
                await self?.refreshIfNeeded(roomId: String(rid))
            }
        }
    }

    /// spec §3.4.2 · 1101 队伍成员变化（preservePersonal 从旧 members 按 uid 回填缺失 personalScore/gems）
    /// payload 带值优先：payload.personalScore != nil 时用 payload 值；nil 时用旧 members 里同 uid 的值
    func onTeamMemberChange(_ payload: BattleTeamMemberChangePayload) {
        guard acceptsCurrentPkEvent(payload.pkId) else { return }
        guard var s = state else { return }
        if let rt = payload.redTeam {
            s.redTeam = Self.mergeTeamPreservingPersonal(new: rt, old: s.redTeam)
        }
        if let bt = payload.blueTeam {
            s.blueTeam = Self.mergeTeamPreservingPersonal(new: bt, old: s.blueTeam)
        }
        if let nt = payload.neutral {
            s.neutral = Self.mergeTeamPreservingPersonal(new: nt, old: s.neutral)
        }
        state = s
    }

    private static func mergeTeamPreservingPersonal(new: BattleTeam, old: BattleTeam) -> BattleTeam {
        let oldByUid: [Int64: BattleMember] = Dictionary(uniqueKeysWithValues: old.members.map { ($0.uid, $0) })
        let mergedMembers: [BattleMember] = new.members.map { m in
            let oldOne = oldByUid[m.uid]
            return BattleMember(
                uid: m.uid,
                nickname: m.nickname ?? oldOne?.nickname,
                avatar: m.avatar ?? oldOne?.avatar,
                personalScore: m.personalScore ?? oldOne?.personalScore,
                personalGems: m.personalGems ?? oldOne?.personalGems,
                isCrownHolder: m.isCrownHolder ?? oldOne?.isCrownHolder
            )
        }
        return BattleTeam(count: new.count, members: mergedMembers)
    }

    /// 1106 皇冠归属更新（对齐 H5 partyBattle.ts:502-524 完整逻辑）
    ///
    /// H5 payload 用 `team + oldUid + newUid` 精准更新单队 members：
    /// - `member.uid == oldUid` → isCrownHolder = false
    /// - `member.uid == newUid` → isCrownHolder = true
    ///
    /// 老后端兼容（顶层 redCrownUid/blueCrownUid）：iOS 侧同时更新顶层 state.redCrownUid/blueCrownUid
    /// 让下游消费统一（RunningHud/EndedSettlement fallback 都读顶层字段）
    func onCrownHolderUpdate(_ payload: BattleCrownHolderUpdatePayload) {
        guard acceptsCurrentPkEvent(payload.pkId) else { return }
        guard var s = state else { return }
        // 老后端顶层字段（保留原逻辑）
        if let r = payload.redCrownUid { s.redCrownUid = r }
        if let b = payload.blueCrownUid { s.blueCrownUid = b }

        // 新版：按 team 定位 members 更新 isCrownHolder（对齐 H5 line 506-519）
        if let team = payload.team {
            let updateMembers: ([BattleMember]) -> [BattleMember] = { members in
                members.map { m in
                    if let old = payload.oldUid, m.uid == old {
                        return BattleMember(
                            uid: m.uid, nickname: m.nickname, avatar: m.avatar,
                            personalScore: m.personalScore, personalGems: m.personalGems,
                            isCrownHolder: false)
                    }
                    if let new = payload.newUid, m.uid == new {
                        return BattleMember(
                            uid: m.uid, nickname: m.nickname, avatar: m.avatar,
                            personalScore: m.personalScore, personalGems: m.personalGems,
                            isCrownHolder: true)
                    }
                    return m
                }
            }
            if team == 1 {
                s.redTeam = BattleTeam(count: s.redTeam.count, members: updateMembers(s.redTeam.members))
                if let new = payload.newUid { s.redCrownUid = new }
            } else if team == 2 {
                s.blueTeam = BattleTeam(count: s.blueTeam.count, members: updateMembers(s.blueTeam.members))
                if let new = payload.newUid { s.blueCrownUid = new }
            }
        }
        state = s
    }
}

fileprivate extension BattleLeaderboardMergedPayload {
    /// 字段级合并（本 payload 优先，nil 保持旧值）
    func mergedWith(_ other: BattleLeaderboardMergedPayload) -> BattleLeaderboardMergedPayload {
        BattleLeaderboardMergedPayload(
            pkId: other.pkId ?? pkId,
            redScore: other.redScore ?? redScore,
            blueScore: other.blueScore ?? blueScore,
            redGems: other.redGems ?? redGems,
            blueGems: other.blueGems ?? blueGems,
            redCrownUid: other.redCrownUid ?? redCrownUid,
            blueCrownUid: other.blueCrownUid ?? blueCrownUid,
            redTop: other.redTop ?? redTop,
            blueTop: other.blueTop ?? blueTop
        )
    }
}

// MARK: - Task 10c · onEnd 三分类 + fetchSettlement + onRunningStart

extension PartyBattleStore {

    /// spec §1.1 · 1103 或 tickLeft SELECTING 归零触发
    /// state 已存在分支只 set status=2 + leftSec；不重构 state
    func onRunningStart(_ payload: BattleRunningStartPayload) {
        guard acceptsCurrentPkEvent(payload.pkId) else { return }
        if let payloadPkId = payload.pkId, !payloadPkId.isEmpty {
            pkId = payloadPkId
        }
        guard !pkId.isEmpty else {
            AppLogger.party.warning("[Battle] running start ignored: missing pkId")
            return
        }

        let dur = max(0, payload.durationSec ?? durationSec)
        let left = max(0, payload.leftSec ?? dur)
        var createdFallback = false
        if var s = state {
            if s.pkId.isEmpty { s.pkId = pkId }
            s.status = .running
            s.durationSec = dur
            s.leftSec = left
            state = s
        } else {
            // 首屏进房或 1100 丢失时，1103 仍必须能独立建立可渲染 RUNNING 态。
            var fallback = Self.makeSelectingState(
                pkId: pkId,
                battleId: 0,
                roomId: effectiveRoomId,
                hostUid: 0,
                hostRole: 1,
                templateId: nil,
                templateName: nil,
                selectingDurationSec: 0,
                durationSec: dur,
                leftSec: left,
                redTeam: BattleTeam(count: 0, members: []),
                blueTeam: BattleTeam(count: 0, members: []),
                neutral: BattleTeam(count: 0, members: []),
                redTop: [],
                blueTop: []
            )
            fallback.status = .running
            state = fallback
            createdFallback = true
        }
        durationSec = dur
        leftSec = left

        // 安卓端在 NIM 驱动状态变更后会 forceRefresh；1103 本身不保证携带完整 team/top3 快照。
        if createdFallback {
            let rid = effectiveRoomId
            if rid > 0 {
                Task { [weak self] in
                    await self?.refreshIfNeeded(roomId: String(rid))
                }
            }
        }
    }

    /// spec §1.1 + H5 partyBattle.ts:537-570 onEnd 分类字段（v2 2026-07-17 对齐 H5 完整语义）：
    /// - **stub**（IM 1109 有 payload 但无 durationSec）：不写 lastSettlement + 主动 fetchSettlement 补拉
    /// - **full**（API settlement 或 forceEnd 后拉的完整 payload）：showSettlement=true + apply
    ///     - 若 full 但 Top3/Crown 缺失 → 也 fetchSettlement 补拉
    /// - **null**（tickLeft RUNNING 归零本地路径）：仅写 cooldown 兜底，不重复请求
    ///
    /// PK 结束额外副作用（对齐 H5 partyBattle.ts:541-543）：
    /// 清**所有已占麦位** giftValueCount（PK 期间累计的本场收礼值不能残留到 PK 结束后的普通麦位）
    func onEnd(_ payload: BattleEndPayload?) {
        guard acceptsCurrentPkEvent(payload?.pkId) else { return }
        applyStatus(.ended)

        // ✨ H5 partyBattle.ts:543 · usePartyStore().resetAllSeatGiftValue()
        roomEnv.resetAllSeatGiftValue()

        let isFullSettlement: Bool = payload?.durationSec != nil
        if isFullSettlement, let p = payload {
            lastSettlement = PartyBattleSettlementResponse(
                pkId: p.pkId ?? pkId,
                durationSec: p.durationSec,
                winnerTeam: p.winnerTeam,
                redScore: p.redScore,
                blueScore: p.blueScore,
                redGems: p.redGems,
                blueGems: p.blueGems,
                giftSendMvp: nil,
                giftReceiveMvp: nil,
                redTop3: nil,
                blueTop3: nil,
                redCrownUid: nil,
                blueCrownUid: nil,
                endedEarly: p.endedEarly,
                cooldownLeftSec: p.cooldownLeftSec
            )
        }
        // H5 partyBattle.ts:552 · **无条件** showSettlement=true（不管 stub/full/null 都弹结算 popup）
        // tickLeft RUNNING 归零走 onEnd(null) 本地兜底路径也要立即弹 popup，让 UI 立即响应；
        // settlement 数据由 stub 分支 fetchSettlement 补拉后再刷新 popup 内容
        showSettlement = true
        // cooldown 兜底：payload.cooldownLeftSec > store.cooldownDurationSec > 60 fallback
        let cd = payload?.cooldownLeftSec ?? cooldownDurationSec
        cooldownLeftSec = cd > 0 ? cd : 60
        leftSec = 0
        if cooldownLeftSec > 0 { startCooldownTicker() }

        // stub 分类补拉（对齐 H5 partyBattle.ts:559-569）：
        // - IM 1109 stub（payload 存在但缺 durationSec）→ 主动 fetchSettlement 拉全
        // - full 但 Top3/Crown 缺（MVP 等信息缺失）→ 也 fetchSettlement 补
        // - null（tickLeft 本地兜底）→ 不重复请求
        if let p = payload, !isFullSettlement {
            Task { [weak self] in _ = try? await self?.fetchSettlement() }
            _ = p  // avoid unused
        } else if isFullSettlement {
            // H5 partyBattle.ts:565-568 · 判"Top3 / Crown 缺失" → 补拉完整 settlement
            let hasTops = (lastSettlement?.redTop3?.isEmpty == false)
                || (lastSettlement?.blueTop3?.isEmpty == false)
            let hasCrown = lastSettlement?.redCrownUid != nil || lastSettlement?.blueCrownUid != nil
            if !hasTops && !hasCrown {
                Task { [weak self] in _ = try? await self?.fetchSettlement() }
            }
        }
    }

    /// 从 service 拉完整 settlement（RUNNING 归零本地路径 tickLeft 内部调用）
    func fetchSettlement() async throws -> PartyBattleSettlementResponse? {
        guard !pkId.isEmpty else { return nil }
        let requestPkId = pkId
        let requestRevision = stateRevision
        do {
            let s = try await service.fetchSettlement(requestPkId)
            guard requestRevision == stateRevision, pkId == requestPkId else {
                AppLogger.party.notice("[Battle] settlement response dropped: PK/session changed")
                return nil
            }
            lastSettlement = s
            showSettlement = true
            return s
        } catch {
            AppLogger.party.error("[Battle] fetchSettlement failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

// MARK: - Task 10d · refreshIfNeeded + loadTemplatesIfNeeded

extension PartyBattleStore {

    /// F-1a Task 10d · 冷启动/断网重连兜底
    /// 调用点：PartyRoomView.task { await battleStore.refreshIfNeeded(roomId: ...) }
    func refreshIfNeeded(roomId: String) async {
        guard let requestedRoomId = Int64(roomId), requestedRoomId > 0 else { return }
        let requestRevision = stateRevision
        do {
            if let s = try await service.fetchState(roomId) {
                guard isCurrentAsyncRequest(revision: requestRevision, roomId: requestedRoomId),
                      s.roomId == 0 || s.roomId == requestedRoomId else {
                    AppLogger.party.notice("[Battle] refresh response dropped: room/session changed")
                    return
                }
                applyRefreshedState(s)
            }
        } catch {
            AppLogger.party.error("[Battle] refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// F-1a Task 10d · 模板列表按需拉取（首次开 InitiatePopup 时调）
    ///
    /// 对齐 H5 initiatePopup.vue :83-86：拉到 templates 后缓存 `cooldownDuration` 到 store
    /// 让 onEnd 在 settlement 缺失时也能用后台配置而非 hardcode 60
    ///
    /// 幂等 guard `templates.isEmpty` 保护重入
    func loadTemplatesIfNeeded() async {
        guard templates.isEmpty else { return }
        do {
            templates = try await service.fetchTemplates()
            // 缓存 templates[0].cooldownDuration 到 cooldownDurationSec（H5 line 83-86）
            if let cd = templates.first?.cooldownDuration, cd > 0 {
                cooldownDurationSec = cd
            }
        } catch {
            AppLogger.party.error("[Battle] loadTemplates failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// H5 initiatePopup.vue :103 —— templates[0].selectingDuration 派生（默认 60）
    /// InitiatePopup 提示文案 `initiateHint2` 用
    var globalSelectingDurationSec: Int {
        templates.first?.selectingDuration ?? 60
    }

    /// 从 service.fetchState 恢复 store 状态（refresh 冷启动 / RUNNING 结束 refetch）
    ///
    /// 对齐 H5 partyBattle.ts:159-164：SELECTING/RUNNING 阶段顺带拉一次申请列表
    /// （仅房主/房管拿到非空，普通观众后端返空 list，store 也按空覆盖）
    private func applyRefreshedState(_ s: PartyBattleState) {
        state = s
        pkId = s.pkId
        selectingDurationSec = s.selectingDurationSec
        durationSec = s.durationSec
        // H5 partyBattle.ts:149 · `Number(r.leftSec) || 0` 兜底负值到 0（UI 展示层再 max(0) 二次守护）
        leftSec = max(0, s.leftSec)
        templateName = s.templateName ?? ""
        // H5 partyBattle.ts:152-155 · 冷却剩余秒：后端在 COOLDOWN/ENDED/FORCE_ENDED 状态返回 >0，
        // 其它阶段（SELECTING/RUNNING）返回 -1；`Number.isFinite(cd) && cd > 0 ? cd : 0` 兜底守护
        // 否则 iOS Int 会写入 -1，UI 层显示 "-1s" bug
        cooldownLeftSec = s.cooldownLeftSec > 0 ? s.cooldownLeftSec : 0
        if cooldownLeftSec > 0 {
            startCooldownTicker()
        } else {
            stopCooldownTicker()
        }

        // SELECTING/RUNNING 拉申请列表（H5 line 161-164）
        if s.status == .selecting || s.status == .running {
            let rid = effectiveRoomId
            if rid > 0 {
                Task { [weak self] in
                    await self?.loadApplications(roomId: String(rid))
                }
            }
        } else {
            pendingApplications = []
        }
    }
}

// MARK: - Task 9 · onSelectingStart 侵入 PartyStore 清参战麦位

extension PartyBattleStore {

    /// F-1a Task 9：IM 1100 到达时的入口 action
    ///
    /// 对齐 H5 partyBattle.ts:335-351：
    /// 1. `_resetForNewBattle()` 清 lastSettlement / showSettlement / applications / cooldown / forceEnding
    /// 2. 构造 state（status=selecting）+ 顶层字段
    /// 3. **侵入 PartyStore**：清红蓝队参战 uid 的 seat.giftValueCount（中立位不清）
    func onSelectingStart(_ payload: BattleSelectingStartPayload) {
        guard acceptsSelectingEvent(payload.pkId) else { return }
        _resetForNewBattle()

        // 构造 state
        let selectingSec = max(0, payload.selectingDurationSec ?? 60)
        let durSec = max(0, payload.durationSec ?? 300)
        let left = max(0, payload.leftSec ?? selectingSec)
        let redTeamValue = payload.redTeam ?? BattleTeam(count: 0, members: [])
        let blueTeamValue = payload.blueTeam ?? BattleTeam(count: 0, members: [])
        let neutralValue = payload.neutral ?? BattleTeam(count: 0, members: [])
        let redTopValue = payload.redTop ?? []
        let blueTopValue = payload.blueTop ?? []
        let roomIdValue = payload.roomId ?? 0
        let hostUidValue = payload.hostUid ?? 0

        let newState = Self.makeSelectingState(
            pkId: payload.pkId ?? "",
            battleId: payload.battleId ?? 0,
            roomId: roomIdValue,
            hostUid: hostUidValue,
            hostRole: payload.hostRole ?? 1,
            templateId: payload.templateId,
            templateName: payload.templateName,
            selectingDurationSec: selectingSec,
            durationSec: durSec,
            leftSec: left,
            redTeam: redTeamValue,
            blueTeam: blueTeamValue,
            neutral: neutralValue,
            redTop: redTopValue,
            blueTop: blueTopValue
        )
        state = newState
        pkId = newState.pkId
        selectingDurationSec = selectingSec
        durationSec = durSec
        leftSec = left
        templateName = newState.templateName ?? ""

        // 侵入 PartyStore 清**所有已占麦位** giftValueCount（对齐 H5 partyBattle.ts:332-336 完整语义：
        // 中立位、SELECTING 之后经 1101/审批中途入队的人也需要清零，否则残留历史累计值）
        roomEnv.resetAllSeatGiftValue()
    }

    /// 清一场结束态与新场无关的字段（cooldown / settlement / applications / forceEnding），保留 cooldownDurationSec / totalSwitch / templates
    private func _resetForNewBattle() {
        invalidateStateRequests()
        lastSettlement = nil
        showSettlement = false
        pendingApplications = []
        cooldownLeftSec = 0
        forceEnding = false
        actionError = nil
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        leaderboardFlushTask?.cancel()
        leaderboardFlushTask = nil
        pendingLeaderboardPayload = nil
    }

    /// 构造 selecting 状态的 PartyBattleState（用 JSON round-trip 避开 Decodable-only init）
    private static func makeSelectingState(
        pkId: String,
        battleId: Int,
        roomId: Int64,
        hostUid: Int64,
        hostRole: Int,
        templateId: Int?,
        templateName: String?,
        selectingDurationSec: Int,
        durationSec: Int,
        leftSec: Int,
        redTeam: BattleTeam,
        blueTeam: BattleTeam,
        neutral: BattleTeam,
        redTop: [BattleTopMember],
        blueTop: [BattleTopMember]
    ) -> PartyBattleState {
        var dict: [String: Any] = [
            "pkId": pkId,
            "battleId": battleId,
            "roomId": roomId,
            "status": PartyBattleStatus.selecting.rawValue,
            "selectingDurationSec": selectingDurationSec,
            "durationSec": durationSec,
            "leftSec": leftSec,
            "hostUid": hostUid,
            "hostRole": hostRole,
            "redScore": 0,
            "blueScore": 0,
            "cooldownLeftSec": 0,
        ]
        if let t = templateId { dict["templateId"] = t }
        if let n = templateName { dict["templateName"] = n }
        // Team / Top 用 encode
        let encoder = JSONEncoder()
        if let d = try? encoder.encode(redTeam),
           let o = try? JSONSerialization.jsonObject(with: d) { dict["redTeam"] = o }
        if let d = try? encoder.encode(blueTeam),
           let o = try? JSONSerialization.jsonObject(with: d) { dict["blueTeam"] = o }
        if let d = try? encoder.encode(neutral),
           let o = try? JSONSerialization.jsonObject(with: d) { dict["neutral"] = o }
        if let d = try? encoder.encode(redTop),
           let o = try? JSONSerialization.jsonObject(with: d) { dict["redTop"] = o }
        if let d = try? encoder.encode(blueTop),
           let o = try? JSONSerialization.jsonObject(with: d) { dict["blueTop"] = o }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let state = try? JSONDecoder().decode(PartyBattleState.self, from: data)
        else {
            // 兜底：payload 极端异常时构造最小可用 state
            AppLogger.party.error("[Battle] makeSelectingState fallback")
            return Self.emptyState(status: .selecting)
        }
        return state
    }

    /// 空 state（异常兜底）
    private static func emptyState(status: PartyBattleStatus) -> PartyBattleState {
        let dict: [String: Any] = [
            "pkId": "", "battleId": 0, "roomId": 0,
            "status": status.rawValue,
            "selectingDurationSec": 60, "durationSec": 300, "leftSec": 0,
            "hostUid": 0, "hostRole": 1,
            "redTeam": ["count": 0, "members": []],
            "blueTeam": ["count": 0, "members": []],
            "neutral": ["count": 0, "members": []],
            "redTop": [], "blueTop": [],
            "redScore": 0, "blueScore": 0, "cooldownLeftSec": 0,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(PartyBattleState.self, from: data)
    }
}

#if DEBUG
extension PartyBattleStore {
    /// 独立测试实例（不受 shared 单例状态干扰）
    static func testInstance(
        service: PartyBattleServiceProtocol,
        roomEnv: PartyRoomEnvironment
    ) -> PartyBattleStore {
        PartyBattleStore(service: service, roomEnv: roomEnv)
    }

    func _setStateForTesting(_ s: PartyBattleState) { state = s }
    func _applyStatusForTesting(_ status: PartyBattleStatus) { applyStatus(status) }
    func _setTotalSwitchForTesting(_ v: Int) { totalSwitch = v }
    func _setShowSettlementForTesting(_ v: Bool) { showSettlement = v }
    func _setTemplatesForTesting(_ arr: [PartyBattleTemplate]) { templates = arr }
    func _setCooldownLeftSecForTesting(_ v: Int) { cooldownLeftSec = v }
    func _setLastSettlementForTesting(_ s: PartyBattleSettlementResponse?) { lastSettlement = s }
}
#endif
