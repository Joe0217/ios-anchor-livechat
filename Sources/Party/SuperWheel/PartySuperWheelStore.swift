import Foundation
import SwiftUI

// MARK: - Result kind

enum PartySuperWheelResultKind: Equatable {
    case eliminated
    case winner
}

// MARK: - Store

/// Party 房 Super Wheel 的单一状态源。HTTP 全量状态用于进房/重连对账，1150-1156 IM
/// 广播用于实时推进阶段；两条链路都归约到这里，避免 UI 直接依赖不完整的消息 payload。
@MainActor
final class PartySuperWheelStore: ObservableObject {
    static let shared = PartySuperWheelStore()

    /// 进房 3s 静默期，避免刚进房就自动弹全屏面板打断其他动画。对齐 H5
    /// `ROOM_ENTER_SILENCE_MS = 3000`。用户主动点入口时 `endEnterSilence()` 打穿。
    private static let enterSilenceMs: UInt64 = 3_000_000_000
    /// 关局 1.5s 静止过渡，让「谁赢了」的视觉停一拍再收起浮层。对齐 H5 `END_STATIC_HOLD_MS = 1500`。
    private static let closeHoldMs: UInt64 = 1_500_000_000
    /// Dial 6s 减速旋转动画时长(对齐 H5 super-wheel-dial.vue `transition: transform 6s cubic-bezier`).
    /// SPIN 广播到达后 UI 需先播 6s 旋转再显示 REVEAL/FINAL 结算, 否则视觉上"选择和结算同时发生"。
    private static let dialAnimationMs: UInt64 = 6_000_000_000

    @Published private(set) var wheelState: PartySuperWheelState?
    @Published private(set) var config: PartySuperWheelConfig?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isConfigLoading = false
    @Published private(set) var isPerformingAction = false
    @Published var isPanelPresented = false
    @Published var isConfigPresented = false
    @Published private(set) var isPanelDismissed = false
    @Published private(set) var isResultDismissed = false
    /// 进房 3s 静默期内不自动弹面板；用户主动点击入口打穿。
    @Published private(set) var inEnterSilence = false
    /// 工具栏「Super Winner」入口红点：本局出现且用户未点开过 → true。对齐 H5 `showEntryRedDot`。
    @Published private(set) var entrySeen = false
    /// SPIN 广播后 6s 旋转期间抑制 result overlay,让 winner 弹窗等旋转完再出现。
    @Published private(set) var isDialAnimating = false
    /// F3: 每次 SPIN 广播递增的计数器,Dial 通过 `onChange(of:)` 感知 → 保证多轮或
    /// 6s 内二次 SPIN 也能触发旋转(相比 bool 信号 true→true 不发布变化的问题)。
    @Published private(set) var spinTriggerCounter: Int = 0

    private var countdownTask: Task<Void, Never>?
    private var enterSilenceTask: Task<Void, Never>?
    private var closeHoldTask: Task<Void, Never>?
    private var dialAnimationTask: Task<Void, Never>?
    private var shouldPresentPanelAfterConfigDismissal = false
    private var trackedRoomId: String?
    private var stateRequestSequence = 0
    private var reconciledDeadlineMs: Int64?
    private var deadlineReconciliationTask: Task<Void, Never>?

    private init() {}

    deinit {
        countdownTask?.cancel()
        enterSilenceTask?.cancel()
        closeHoldTask?.cancel()
        dialAnimationTask?.cancel()
    }

    // MARK: Derived state

    var isActive: Bool {
        guard let wheelState else { return false }
        return wheelState.state != 0 && wheelState.state != 9
    }

    var isSignup: Bool { wheelState?.state == 3 }
    var isBetting: Bool { wheelState?.state == 5 }
    var isSpinning: Bool { wheelState?.state == 6 }
    var isReveal: Bool { wheelState?.state == 7 }
    var isFinal: Bool { wheelState?.state == 8 }
    /// 服务端 /config 缺失时的兜底档位，与 H5 `SW_ENTRY_FEES_FALLBACK` 保持一致。
    var entryFees: [Int] {
        let fees = config?.entryFees ?? []
        return fees.isEmpty ? [50, 100, 200] : fees
    }
    var isEnabled: Bool { config?.enabled ?? false }
    var myParticipant: PartySuperWheelParticipant? {
        guard let userId = SessionStore.shared.user?.userId else { return nil }
        return wheelState?.participants.first { $0.userId == String(userId) }
    }
    /// H5 允许 CREATED / WAITING / SIGNUP 三个前置阶段加入，不能只等到 SIGNUP。
    var canJoin: Bool {
        guard myParticipant == nil else { return false }
        return [1, 2, 3].contains(wheelState?.state ?? 0)
    }
    var canBet: Bool { isBetting && myParticipant?.status == 1 }
    var isMyParticipantAlive: Bool { myParticipant?.status == 1 }
    var isParticipant: Bool { myParticipant != nil }
    var isRegistering: Bool { [1, 2, 3].contains(wheelState?.state ?? 0) }
    var isSpectating: Bool { isActive && !isMyParticipantAlive && !canJoin }
    var shouldShowBetArea: Bool {
        isMyParticipantAlive && [5, 6, 7, 8].contains(wheelState?.state ?? 0)
    }
    var isBetDisabled: Bool { !isBetting }
    var hasBigCountdown: Bool {
        remainingSeconds > 0 && [3, 4, 5].contains(wheelState?.state ?? 0)
    }
    /// 奖池优先取参与者 totalBet 实时累加，绕过后端 totalPool 广播延迟。对齐 H5 `poolAmount`。
    var displayPool: Int64 {
        let sum = wheelState?.participants.reduce(Int64(0)) { $0 + max(0, $1.totalBet) } ?? 0
        let broadcast = wheelState?.totalPool ?? 0
        return max(sum, broadcast)
    }
    var myWinningRatio: Int {
        guard let mine = myParticipant else { return 0 }
        let aliveBet = wheelState?.participants
            .filter { $0.status == 1 }
            .reduce(Int64(0)) { $0 + max(0, $1.totalBet) } ?? 0
        guard aliveBet > 0 else { return 0 }
        return min(100, max(0, Int((Double(max(0, mine.totalBet)) / Double(aliveBet) * 100).rounded())))
    }
    /// 最后一轮抑制 out：`remainCount ≤ 1` 或本地存活 ≤ 1 时不弹淘汰结算，只保留终局胜出。对齐 H5 `resultMode`。
    var resultKind: PartySuperWheelResultKind? {
        guard let state = wheelState else { return nil }
        if isFinal, (state.winner != nil || state.winnerId != nil) { return .winner }
        if isReveal, state.revealUser != nil {
            let aliveCount = state.participants.filter { $0.status == 1 }.count
            let remain = state.remainCount ?? aliveCount
            if remain <= 1 || aliveCount <= 1 { return nil }
            return .eliminated
        }
        return nil
    }
    /// 已参与的用户即使将大面板最小化，也必须收到淘汰/获胜结果；观战用户只在面板展开时展示。
    /// H5 后端 SPIN → 6s → FINAL 之间是分开广播;若后端合并/跳过导致 iOS state 6→8 太快,
    /// `isDialAnimating` 兜底 6s 抑制 overlay,让转盘先转完再弹 winner。
    var shouldPresentResult: Bool {
        resultKind != nil && !isResultDismissed && !isDialAnimating && (isParticipant || isPanelPresented)
    }
    /// 工具栏入口红点：有活跃对局且用户未点开过 → 显示。
    var showEntryRedDot: Bool { isActive && !entrySeen }

    // MARK: Enter silence

    /// 进房时启动 3s 静默期；期间自动展示面板的时机会被压住，避免打断进房动画。
    /// F1: 3s 结束后需重新检查是否满足自动弹条件 —— PartyStore.enter 里 loadState 已在
    /// inEnterSilence=true 时执行完毕(不会弹),3s 后不补弹面板 → 用户看不到已有对局。
    func beginEnterSilence() {
        enterSilenceTask?.cancel()
        inEnterSilence = true
        entrySeen = false
        enterSilenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.enterSilenceMs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.inEnterSilence = false
                // 静默期结束,若对局仍活跃 + 未主动收起(或已参与存活)→ 补弹面板
                if self.isActive, !self.isPanelDismissed || self.isMyParticipantAlive {
                    self.isPanelPresented = true
                }
            }
        }
    }

    private func endEnterSilence() {
        enterSilenceTask?.cancel()
        enterSilenceTask = nil
        inEnterSilence = false
    }

    // MARK: Tracking / lifecycle

    func beginTracking(roomId: String) {
        guard Self.canUseLottery(action: "partySuperWheelTracking") else {
            reset()
            return
        }
        guard !roomId.isEmpty else { return }
        guard trackedRoomId != roomId else { return }
        countdownTask?.cancel()
        countdownTask = nil
        deadlineReconciliationTask?.cancel()
        deadlineReconciliationTask = nil
        closeHoldTask?.cancel()
        closeHoldTask = nil
        // F2: 换房时也清 dialAnimationTask,避免上房间 SPIN 后 6s 内进新房造成 isDialAnimating 状态污染。
        dialAnimationTask?.cancel()
        dialAnimationTask = nil
        isDialAnimating = false
        stateRequestSequence &+= 1
        trackedRoomId = roomId
        wheelState = nil
        remainingSeconds = 0
        reconciledDeadlineMs = nil
        isPanelPresented = false
        isPanelDismissed = false
        isResultDismissed = false
        entrySeen = false
    }

    // MARK: HTTP actions

    func prepareConfig() async {
        guard Self.canUseLottery(action: "partySuperWheelPrepareConfig") else {
            reset()
            return
        }
        isConfigPresented = true
        guard !isConfigLoading else { return }
        isConfigLoading = true
        defer { isConfigLoading = false }
        do {
            config = try await PartyAPI.superWheelConfig()
        } catch {
            AppLogger.party.notice("[SuperWheel] config load failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelUnavailable)
        }
    }

    func loadConfig() async {
        guard Self.canUseLottery(action: "partySuperWheelLoadConfig") else { return }
        guard !isConfigLoading else { return }
        isConfigLoading = true
        defer { isConfigLoading = false }
        do {
            config = try await PartyAPI.superWheelConfig()
        } catch {
            AppLogger.party.notice("[SuperWheel] config load failed: \(String(describing: error), privacy: .private)")
        }
    }

    func loadState(roomId: String, presentWhenActive: Bool) async {
        guard Self.canUseLottery(action: "partySuperWheelLoadState") else {
            reset()
            return
        }
        guard !roomId.isEmpty, trackedRoomId == roomId else { return }
        let requestSequence = { stateRequestSequence &+= 1; return stateRequestSequence }()
        isLoading = true
        defer {
            if requestSequence == stateRequestSequence {
                isLoading = false
            }
        }
        do {
            guard let response = try await PartyAPI.superWheelState(roomId: roomId) else {
                guard requestSequence == stateRequestSequence, trackedRoomId == roomId else { return }
                wheelState = nil
                isPanelPresented = false
                refreshCountdown()
                return
            }
            guard requestSequence == stateRequestSequence,
                  trackedRoomId == roomId,
                  response.roomId.isEmpty || response.roomId == roomId else { return }
            applyLoadedState(response)
            if presentWhenActive, shouldAutomaticallyPresentPanel { isPanelPresented = true }
            refreshCountdown()
        } catch {
            AppLogger.party.notice("[SuperWheel] state load failed: \(String(describing: error), privacy: .private)")
        }
    }

    func open(roomId: String, entryFee: Int) async {
        guard Self.canUseLottery(action: "partySuperWheelOpen"),
              trackedRoomId == roomId,
              entryFees.contains(entryFee),
              !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let opened = try await PartyAPI.openSuperWheel(roomId: roomId, entryFee: entryFee)
            wheelState = PartySuperWheelState(
                roundId: opened.roundId,
                roomId: roomId,
                hostId: SessionStore.shared.user.flatMap { user in
                    user.userId.map { String($0) }
                },
                entryFee: opened.entryFee,
                state: opened.state,
                roundNo: 0,
                totalPool: 0,
                phaseDeadlineMs: nil,
                participants: [],
                winnerId: nil,
                winner: nil,
                winnerAmount: nil,
                hostAmount: nil,
                platformAmount: nil,
                revealUser: nil,
                remainCount: nil,
                eliminatedUserId: nil,
                sectorIndex: nil
            )
            queuePanelAfterConfigDismissal()
            PartyAnalytics.track(
                "h_superwheel_start",
                properties: ["roomid": roomId, "dia": entryFee]
            )
            await loadState(roomId: roomId, presentWhenActive: false)
        } catch let apiError as PartyAPIError {
            if case .business(let code, _) = apiError, code == "11503" {
                // H5：房间已有进行中对局时不报错，直接进入当前对局。
                queuePanelAfterConfigDismissal()
                await loadState(roomId: roomId, presentWhenActive: false)
                return
            }
            AppLogger.party.notice("[SuperWheel] open failed: \(String(describing: apiError), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        } catch {
            AppLogger.party.notice("[SuperWheel] open failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        }
    }

    func join() async {
        guard Self.canUseLottery(action: "partySuperWheelJoin"),
              let wheelState,
              !isPerformingAction else { return }
        let trackingProperties = wheelTrackingProperties(for: wheelState)
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await PartyAPI.joinSuperWheel(roundId: wheelState.roundId)
            PartyAnalytics.track("h_wheel_fill_click", properties: trackingProperties)
            await loadState(roomId: wheelState.roomId, presentWhenActive: false)
            var resultProperties = trackingProperties
            resultProperties["state"] = "success"
            PartyAnalytics.track("h_wheel_join_click", properties: resultProperties)
        } catch {
            var resultProperties = trackingProperties
            resultProperties["state"] = "fail"
            resultProperties["reason"] = superWheelJoinFailureReason(error)
            PartyAnalytics.track("h_wheel_join_click", properties: resultProperties)
            AppLogger.party.notice("[SuperWheel] join failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        }
    }

    func bet(amount: Int) async {
        guard Self.canUseLottery(action: "partySuperWheelBet"),
              let wheelState,
              amount > 0,
              !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await PartyAPI.betSuperWheel(roundId: wheelState.roundId, amount: amount)
            await loadState(roomId: wheelState.roomId, presentWhenActive: false)
        } catch {
            AppLogger.party.notice("[SuperWheel] bet failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        }
    }

    func close() async {
        guard Self.canUseLottery(action: "partySuperWheelClose"),
              let wheelState,
              !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await PartyAPI.closeSuperWheel(roundId: wheelState.roundId)
            PartyAnalytics.track(
                "h_superwheel_close_success",
                properties: ["roomid": wheelState.roomId]
            )
            await loadState(roomId: wheelState.roomId, presentWhenActive: false)
        } catch {
            AppLogger.party.notice("[SuperWheel] close failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        }
    }

    // MARK: Panel presentation

    /// iOS 同一展示容器不能在同一更新周期内切换两个 `.sheet`。
    /// 配置 sheet 的 onDismiss 会调用 `presentQueuedPanelAfterConfigDismissal()`。
    private func queuePanelAfterConfigDismissal() {
        isConfigPresented = false
        shouldPresentPanelAfterConfigDismissal = true
    }

    func presentQueuedPanelAfterConfigDismissal() {
        guard Self.canUseLottery(action: "partySuperWheelPresentPanel") else {
            reset()
            return
        }
        guard shouldPresentPanelAfterConfigDismissal, !isConfigPresented else { return }
        shouldPresentPanelAfterConfigDismissal = false
        openPanel()
    }

    /// 常驻图标/工具入口展开本局面板时，同时允许重新查看当前结算结果。
    func openPanel() {
        guard Self.canUseLottery(action: "partySuperWheelOpenPanel") else {
            reset()
            return
        }
        endEnterSilence()
        entrySeen = true
        isPanelDismissed = false
        isResultDismissed = false
        isPanelPresented = true
    }

    func markEntrySeen() {
        entrySeen = true
    }

    /// 最小化不结束游戏。淘汰者和未参与者本局不再被状态同步反复拉回，已参与者仍会收到结算。
    func dismissPanel() {
        isPanelPresented = false
        isPanelDismissed = true
    }

    func dismissResult() {
        isResultDismissed = true
        dismissPanel()
    }

    // MARK: Broadcast intake

    func applyBroadcast(attachType: Int, payload: [String: Any]) {
        guard Self.canUseLottery(action: "partySuperWheelBroadcast") else {
            reset()
            return
        }
        guard let trackedRoomId else { return }
        guard let incomingRoundId = PartySuperWheelBroadcast.string(payload["roundId"]), !incomingRoundId.isEmpty else {
            return
        }
        let incomingRoomId = PartySuperWheelBroadcast.string(payload["roomId"])
        guard incomingRoomId == nil || incomingRoomId == trackedRoomId else { return }
        if attachType == PartyAttachType.superWheelStateSync.rawValue {
            // 1150 的基类 payload 在新局时可能不带 entryFee。先拉 /state，绝不能让 0 或上一局档位
            // 短暂出现在 Join 按钮上；这与 H5 新 roundId 的处理一致。
            guard let current = wheelState, current.roundId == incomingRoundId else {
                Task { await loadState(roomId: trackedRoomId, presentWhenActive: false) }
                return
            }
            guard var fullState = try? PartySuperWheelState.from(payload),
                  fullState.roomId.isEmpty || fullState.roomId == trackedRoomId else { return }
            if fullState.entryFee <= 0 { fullState.entryFee = current.entryFee }
            if PartySuperWheelBroadcast.array(payload["participants"]) == nil {
                fullState.participants = current.participants
            }
            applyLoadedState(fullState)
            if shouldAutomaticallyPresentPanel { isPanelPresented = true }
            refreshCountdown()
            return
        }

        guard var state = wheelState else { return }
        state.state = PartySuperWheelBroadcast.int(payload["state"]) ?? state.state
        state.roundNo = PartySuperWheelBroadcast.int(payload["roundNo"]) ?? state.roundNo
        state.totalPool = PartySuperWheelBroadcast.int64(payload["totalPool"]) ?? state.totalPool
        state.phaseDeadlineMs = PartySuperWheelBroadcast.int64(payload["phaseDeadline"]) ?? state.phaseDeadlineMs

        switch attachType {
        case PartyAttachType.superWheelSpin.rawValue:
            // H5 在转动/揭晓期间冻结盘面；不可在 1152 提前把命中者移出扇区。
            state.state = 6
            state.eliminatedUserId = PartySuperWheelBroadcast.string(payload["eliminatedUserId"])
            state.sectorIndex = PartySuperWheelBroadcast.int(payload["sectorIndex"])
            beginDialAnimation()
        case PartyAttachType.superWheelReveal.rawValue:
            state.state = 7
            isResultDismissed = false
            state.revealUser = PartySuperWheelUser.from(payload["eliminatedUser"] as? [String: Any])
            if state.revealUser == nil,
               let userId = PartySuperWheelBroadcast.string(payload["eliminatedUserId"])
                    ?? state.eliminatedUserId,
               let participant = state.participants.first(where: { $0.userId == userId }) {
                state.revealUser = PartySuperWheelUser(
                    userId: participant.userId,
                    nickname: participant.nickname,
                    avatar: participant.avatar
                )
            }
            state.eliminatedUserId = PartySuperWheelBroadcast.string(payload["eliminatedUserId"])
                ?? state.revealUser?.userId
                ?? state.eliminatedUserId
            state.remainCount = PartySuperWheelBroadcast.int(payload["remainCount"])
            if let userId = state.revealUser?.userId,
               let index = state.participants.firstIndex(where: { $0.userId == userId }) {
                state.participants[index].status = 2
            }
        case PartyAttachType.superWheelFinal.rawValue:
            state.state = 8
            isResultDismissed = false
            state.winner = PartySuperWheelUser.from(payload["winner"] as? [String: Any])
            state.winnerId = PartySuperWheelBroadcast.string(payload["winnerId"]) ?? state.winner?.userId
            if state.winner == nil,
               let winnerId = state.winnerId,
               let participant = state.participants.first(where: { $0.userId == winnerId }) {
                state.winner = PartySuperWheelUser(
                    userId: participant.userId,
                    nickname: participant.nickname,
                    avatar: participant.avatar
                )
            }
            state.winnerAmount = PartySuperWheelBroadcast.int64(payload["winnerAmount"])
            state.hostAmount = PartySuperWheelBroadcast.int64(payload["hostAmount"])
            state.platformAmount = PartySuperWheelBroadcast.int64(payload["platformAmount"])
        case PartyAttachType.superWheelClosed.rawValue:
            state.state = 9
            isPanelPresented = false
            wheelState = state
            refreshCountdown()
            // 1.5s 静止过渡后再彻底清空 wheelState，让入口/floating 图标不瞬间消失。
            scheduleEndStatic()
            return
        default:
            break
        }
        wheelState = state
        refreshCountdown()
    }

    private func scheduleEndStatic() {
        closeHoldTask?.cancel()
        closeHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.closeHoldMs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.wheelState?.state == 9 {
                    self.wheelState = nil
                    self.remainingSeconds = 0
                    self.entrySeen = false
                }
            }
        }
    }

    /// SPIN 广播到达后启动 6s 计时,期间 `isDialAnimating=true` 抑制 result overlay。
    /// 与 H5 super-wheel-dial 6s cubic-bezier 减速动画对齐。
    /// F3: 用 `spinTriggerCounter &+= 1` 驱动 Dial 旋转 —— 递增计数器每次必发布变化,
    /// 避免 bool 信号在 true→true 情况下 SwiftUI 不触发 onChange。
    private func beginDialAnimation() {
        dialAnimationTask?.cancel()
        isDialAnimating = true
        spinTriggerCounter &+= 1
        dialAnimationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.dialAnimationMs)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.isDialAnimating = false }
        }
    }

    // MARK: Reset

    func reset() {
        countdownTask?.cancel()
        countdownTask = nil
        deadlineReconciliationTask?.cancel()
        deadlineReconciliationTask = nil
        enterSilenceTask?.cancel()
        enterSilenceTask = nil
        closeHoldTask?.cancel()
        closeHoldTask = nil
        dialAnimationTask?.cancel()
        dialAnimationTask = nil
        wheelState = nil
        config = nil
        remainingSeconds = 0
        isLoading = false
        isConfigLoading = false
        isPerformingAction = false
        shouldPresentPanelAfterConfigDismissal = false
        isPanelPresented = false
        isConfigPresented = false
        isPanelDismissed = false
        isResultDismissed = false
        inEnterSilence = false
        entrySeen = false
        isDialAnimating = false
        spinTriggerCounter = 0
        trackedRoomId = nil
        stateRequestSequence &+= 1
        reconciledDeadlineMs = nil
    }

    // MARK: Internals

    private func refreshCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        updateRemainingSeconds()
        guard wheelState?.phaseDeadlineMs != nil, isActive else { return }
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.updateRemainingSeconds()
            }
        }
    }

    private var shouldAutomaticallyPresentPanel: Bool {
        guard !inEnterSilence else { return false }
        return !isPanelDismissed || isMyParticipantAlive
    }

    private static func canUseLottery(action: String) -> Bool {
        #if HILY_TESTS
        // HilyTests 独立编译，不链接 SelfPermissionBridge+Shared。
        return true
        #else
        return SelfPermissionBridge.shared.gate(.lottery, action: action)
        #endif
    }

    private func applyLoadedState(_ state: PartySuperWheelState) {
        if wheelState?.roundId != state.roundId {
            isPanelDismissed = false
            isResultDismissed = false
            entrySeen = false
        }
        wheelState = state
    }

    private func updateRemainingSeconds() {
        guard let deadline = wheelState?.phaseDeadlineMs else {
            remainingSeconds = 0
            return
        }
        let newRemainingSeconds = max(0, Int(ceil(Double(deadline - Int64(Date().timeIntervalSince1970 * 1_000)) / 1_000)))
        if remainingSeconds != newRemainingSeconds {
            remainingSeconds = newRemainingSeconds
        }
        guard remainingSeconds == 0,
              isActive,
              reconciledDeadlineMs != deadline,
              let roomId = trackedRoomId else { return }
        reconciledDeadlineMs = deadline
        deadlineReconciliationTask?.cancel()
        deadlineReconciliationTask = Task { [weak self, deadline, roomId] in
            guard let self else { return }
            await self.loadState(roomId: roomId, presentWhenActive: false)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  self.trackedRoomId == roomId,
                  self.wheelState?.phaseDeadlineMs == deadline,
                  self.isActive else { return }
            await self.loadState(roomId: roomId, presentWhenActive: false)
        }
    }

    private func wheelTrackingProperties(for state: PartySuperWheelState) -> [String: Any] {
        var properties = PartyAnalytics.roomProperties(
            roomId: state.roomId,
            ownerId: state.hostId
        )
        properties["hostid"] = state.hostId ?? ""
        properties["dia"] = state.entryFee
        return properties
    }

    private func superWheelJoinFailureReason(_ error: Error) -> String {
        guard case let PartyAPIError.business(code, _) = error, code == "1019" else {
            return "error"
        }
        return "insufficient"
    }
}

// MARK: - Broadcast JSON helpers

enum PartySuperWheelBroadcast {
    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func array(_ value: Any?) -> [Any]? { value as? [Any] }
}
