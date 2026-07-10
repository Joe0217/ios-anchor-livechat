import Foundation
import Combine
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PKStore")

/// G 里程碑 spec §2：直播 PK 主态状态机。
///
/// **9 态闭环**：idle → matching/inviting/invited → starting → inPK → punishing → endingPK → idle；
/// 异常进 failed。状态迁移调用方分为：
/// - **用户操作**：startRandomMatch / cancelMatch / inviteByAnchorId / acceptInvite / rejectInvite / cancelInvite / endPKActive / endPunishActive / userToggledInviteSwitch
/// - **NIM 推送**：handle97 / handle98 / handle99 / handle100(子分发 7/8/9/10/-1) / handleMute
/// - **生命周期**：reconcileOnReconnect / teardown
///
/// **callState 联动**（spec §2.4 表 + LiveStore.setCallState 内部已 `guard state == .living` 双保险）：
/// - idle/failed → 0；matching/inviting/invited → 2；starting/inPK/punishing → 3
/// - endingPK 瞬时态不改 callState（由 next state 自然覆盖）
///
/// **弱网拦截**（spec §3.5）：enter inPK 时订阅 NetworkQualityMonitor.$currentLevel；
/// 监听到 `.weakSevere` 拦截 NQM 默认 forceEnd 路径改切 `.pkLow`；exit endingPK 时取消订阅。
///
/// **service 调用**：M2 写出 PKService 调用，但 try-catch 失败转 failed；M3 真 service wire 时
/// LiveRoomView 注入 LiveStore/agora/nim 后接通完整链路。
@MainActor
final class PKStore: ObservableObject {

    // MARK: - Published 状态

    @Published private(set) var state: PKStateMain = .idle
    @Published private(set) var ctx: PKContext?
    @Published private(set) var scores: PKScoreUpdate?
    @Published private(set) var receivedInvite: PKInviteInfo?

    /// 邀请弹窗：接受邀请开关 UI 绑定值（true=允许接收邀请；对齐 H5 acceptInvitation）。
    /// 加载入口 `loadInviteSwitchIfNeeded()`；写入入口 `setInviteSwitch(accept:)`。
    @Published private(set) var acceptInviteSwitchOn: Bool = true
    @Published private(set) var inviteSwitchLoading: Bool = false

    /// 推荐列表 UI 状态（PKInviteSheet 绑定）。
    @Published private(set) var recommendList: [PKRecommendAnchor] = []
    @Published private(set) var recommendLoading: Bool = false
    @Published private(set) var recommendHasMore: Bool = true
    @Published private(set) var recommendCurrentPage: Int = 1
    /// 搜索关键词（UI 双向绑定通过 `setSearchKeyword`）。
    @Published private(set) var searchKeyword: String = ""
    /// 是否处于搜索态（影响 UI 标题 + load more 参数）。
    @Published private(set) var isSearching: Bool = false

    /// PK 邀请默认时长（秒）—— 对齐 H5 `pkStore.pkSettings.defaultDuration`。
    /// - 由 [PKDurationPickerSheet] setting 图标弹窗 4 选项（3/5/10/15 min）修改；
    /// - `inviteByAnchorId` 从此字段取默认时长；
    /// - 会话内存态（不做 UserDefaults 持久化，对齐 H5 store 内存 setting 行为）
    @Published var defaultDuration: Int = 300

    /// 三个倒计时的剩余秒（UI 直接绑定显示）。
    @Published private(set) var inviteRemainingSeconds: Int = 0
    @Published private(set) var pkRemainingSeconds: Int = 0
    @Published private(set) var punishRemainingSeconds: Int = 0

    // MARK: - 弱依赖（M3 由 LiveRoomView.onAppear 注入）

    weak var liveStore: LiveStore?
    weak var agora: AgoraManager?
    weak var nim: NIMChatroomManager?
    weak var observer: PKStoreObserver?
    weak var networkMonitor: NetworkQualityMonitor?

    // MARK: - 内部

    let countdown = PKCountdownController()
    /// G M4：PKNIMRouter 强引用（NIMChatroomManager 走 weak 持有）；lazy init 时拿 self weak ref 安全。
    lazy var router: PKNIMRouter = PKNIMRouter(pkStore: self)
    /// PK 期 invite switch 处理（spec §8.3）
    private(set) var userToggledInviteSwitch: Bool = false
    private var inviteSwitchEntrySnapshot: Bool?
    private var isUpdatingInviteSwitch: Bool = false
    /// 匹配 RETRY 阶段标志（QUICK 15s 超时后切 RETRY 5min）
    private var matchingRetryStarted: Bool = false
    /// 弱网订阅
    private var nqCancellable: AnyCancellable?
    /// G #2 反馈修复：标记本轮 PK 结果窗是否已弹过。
    /// case 8 路径（自然结束→enterPunishing→exitToIdle）：在 enterPunishing 时立刻弹结果，exitToIdle 不重弹。
    /// case 9/-1 路径（对方退/异常→exitToIdle）：在 exitToIdle 直接弹结果。
    /// teardown / 下一轮 enterInPK 时重置。
    private var hasShownResult: Bool = false
    /// G M5-3：前台监听 + 500ms 防抖的 reconcile task
    private var foregroundCancellable: AnyCancellable?
    /// NIM 长连重连成功监听（对齐 H5 `onConnect → syncPkStateAfterReconnect`）
    private var nimConnectCancellable: AnyCancellable?
    private var reconcileDebounceTask: Task<Void, Never>?
    /// G #1 修复：匹配 QUICK 15s 超时切 RETRY；RETRY 5min 超时回 idle（对齐 H5 PK_TIME.QUICK_MATCH/RETRY_MATCH）
    private var matchingQuickTask: Task<Void, Never>?
    private var matchingRetryTask: Task<Void, Never>?
    /// G #5 修复：匹配阶段轮询 task（对齐 H5 startMatchPolling）
    /// QUICK 阶段每 3s 调一次 startPkMatch(false)，RETRY 阶段每 15s 调一次 startPkMatch(true)；
    /// 后端找到对手会主动通过 NIM 推送 attachType=100 pkStatus=10，轮询是辅助"我还在等"信号。
    private var matchingPollTask: Task<Void, Never>?

    // MARK: - G #5 修复：并发邀请字典（H5 同时邀请上限 5 个）

    /// 已邀请字典：key=anchorUserId，value=邀请上下文。
    /// H5 livePk.js:64 `invitedList: []`；MAX_INVITE_COUNT=5。
    /// 每条邀请独立 60s 倒计时 task。
    @Published private(set) var invitedAnchors: [Int: PKInvitedItem] = [:]
    /// 每条邀请的 60s 超时 task，与 invitedAnchors 同 key
    private var inviteTimers: [Int: Task<Void, Never>] = [:]
    /// 邀请并发上限（对齐 H5 PK_LIMITS.MAX_INVITE_COUNT）
    private let maxInviteCount = 5
    /// PK 接口 inviterId（PKStore 自己的 anchorId/userId；M3 由 LiveRoomView 注入）
    var ownAnchorId: Int = 0
    var ownRoomId: Int = 0
    /// 声网 PK 多频道 token 复用主直播 rtcToken（声网 token 绑 uid 不绑 channel，spec §1.2 决策）。
    /// joinPKOpposite 时用本字段；M3 由 LiveRoomView.onAppear 注入。
    var rtcToken: String = ""

    init() {
        // G M5-3：app 回前台时调度 reconcile（500ms 防抖避免连续触发）
        foregroundCancellable = NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleReconcile() }
            }
        // 对齐 H5 `onConnect → syncPkStateAfterReconnect`：NIM 长连重连成功后调度 reconcile。
        // dropFirst 忽略订阅当下的初值（避免冷启动 auto-login 触发一次多余的 reconcile；
        // 冷启动进房逻辑独立触发一次；且 reconcile 入口 state guard 会拦截 idle 态无害化）。
        nimConnectCancellable = NIMService.shared.$connectionState
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] state in
                guard state == .connected else { return }
                Task { @MainActor in self?.scheduleReconcile() }
            }
    }

    // MARK: - 用户操作：匹配

    /// 发起随机匹配（idle → matching + QUICK 15s 倒计时）。
    /// 15s 未匹配到 → 自动切 RETRY 5min；RETRY 仍未匹配 → 自动回 idle。
    func startRandomMatch() async {
        guard state == .idle else {
            logger.warning("startRandomMatch invalid state=\(self.state.rawValue)")
            return
        }
        matchingRetryStarted = false
        transition(to: .matching)
        logger.info("🟢 [PK Match] startRandomMatch QUICK 15s timer scheduled")
        do {
            // QUICK 15s 阶段：首次调 startPkMatch(isMatchRetry:false)，并启动 3s 轮询 + 15s 超时
            try await PKService.startPkMatch(isMatchRetry: false)
            logger.info("🟢 [PK Match] startPkMatch ok → QUICK 15s timeout + 3s poll scheduled")
            scheduleMatchingQuickTimeout()
            scheduleMatchingPoll(isRetry: false, intervalSec: 3)
        } catch {
            logger.error("startPkMatch failed: \(String(describing: error), privacy: .private)")
            // 接口失败时不要卡在 .failed（既无 overlay 也无 entry UI）→ 直接调 cancelMatch 兜底回 idle
            await cancelMatch()
        }
    }

    /// 取消匹配（matching/failed/inviting/invited/starting → idle）。
    /// **强容错**：放宽 guard，让用户在任何"应该能取消但卡住"的态都有逃生通道。
    /// **后端通知**：matching/RETRY 期必须调 cancelMatch API，否则后端 callState 永远不清。
    func cancelMatch() async {
        let prevState = state
        // 仅 idle / inPK / punishing / endingPK 拒绝（PK 已开始或已结束不走匹配取消）
        guard prevState != .idle, prevState != .inPK, prevState != .punishing, prevState != .endingPK else {
            logger.warning("cancelMatch ignored: state=\(prevState.rawValue, privacy: .public)")
            return
        }
        logger.info("cancelMatch from state=\(prevState.rawValue, privacy: .public)")
        cancelMatchingTimers()
        countdown.cancelInvite()
        // 通知后端（无论之前是 matching 还是 failed/inviting 等，都把 PK 匹配池里清掉）
        do {
            try await PKService.cancelMatch()
        } catch {
            logger.warning("cancelMatch API failed but tear down anyway: \(String(describing: error), privacy: .private)")
        }
        matchingRetryStarted = false
        receivedInvite = nil
        transition(to: .idle)
    }

    // MARK: - G #1 修复：匹配 QUICK 15s / RETRY 5min 超时切换

    /// QUICK 15s 倒计时；超时切 RETRY（不轮询，spec §1.2 决策）。
    private func scheduleMatchingQuickTimeout() {
        matchingQuickTask?.cancel()
        matchingQuickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self else { return }
            if Task.isCancelled { return }
            // 已被 100/cancelMatch 等转移走的情况：state 不再 .matching → 跳过
            guard self.state == .matching, !self.matchingRetryStarted else {
                logger.info("🟡 [PK Match] QUICK timer fired but state already moved (state=\(self.state.rawValue, privacy: .public) retry=\(self.matchingRetryStarted, privacy: .public))")
                return
            }
            logger.info("🟡 [PK Match] QUICK 15s 未匹配 → 切 RETRY")
            await self.enterRetryMatching()
        }
    }

    /// 进入 RETRY 5min 阶段：调 startPkMatch(true)，启动 5min 兜底倒计时 + 15s 轮询。
    private func enterRetryMatching() async {
        matchingRetryStarted = true
        // 切换轮询间隔：QUICK 3s → RETRY 15s
        matchingPollTask?.cancel()
        matchingPollTask = nil
        do {
            try await PKService.startPkMatch(isMatchRetry: true)
            logger.info("🟡 [PK Match] startPkMatch(retry) ok → RETRY 5min timeout + 15s poll scheduled")
            scheduleMatchingRetryTimeout()
            scheduleMatchingPoll(isRetry: true, intervalSec: 15)
        } catch {
            logger.error("startPkMatch(retry) failed: \(String(describing: error), privacy: .private)")
            await self.cancelMatch()
        }
    }

    /// 启动匹配轮询 task（对齐 H5 startMatchPolling）。
    /// QUICK 期 3s 一次 / RETRY 期 15s 一次（用户决策值；H5 RETRY 是 10s）。
    /// 后端找到对手时通过 NIM 推送 attachType=100 pkStatus=10，本轮询是辅助"我还在等"信号。
    /// 轮询失败不影响下一次轮询，state 校验 + cancel 自动停。
    private func scheduleMatchingPoll(isRetry: Bool, intervalSec: Int) {
        matchingPollTask?.cancel()
        matchingPollTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(intervalSec) * 1_000_000_000)
                guard let self else { return }
                if Task.isCancelled { return }
                guard self.state == .matching else {
                    logger.info("[PK Match Poll] state moved (=\(self.state.rawValue, privacy: .public)), poll stops")
                    return
                }
                // RETRY 阶段进入后旧 QUICK poll task 自然停（matchingPollTask 已被覆盖）
                do {
                    try await PKService.startPkMatch(isMatchRetry: isRetry)
                    logger.debug("[PK Match Poll] tick isRetry=\(isRetry, privacy: .public) ok")
                } catch {
                    // 单次轮询失败不影响下次（与 H5 一致：轮询是冗余信号）
                    logger.notice("[PK Match Poll] tick failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    /// RETRY 5min 倒计时；超时仍未匹配 → 调 cancelMatch 回 idle。
    private func scheduleMatchingRetryTimeout() {
        matchingRetryTask?.cancel()
        matchingRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard let self else { return }
            if Task.isCancelled { return }
            guard self.state == .matching else {
                logger.info("🟡 [PK Match] RETRY timer fired but state already moved (state=\(self.state.rawValue, privacy: .public))")
                return
            }
            logger.notice("🔴 [PK Match] RETRY 5min 超时 → 自动回 idle")
            await self.cancelMatch()
        }
    }

    /// 通用 timer 清理（cancelMatch / handle100 case 10 / teardown 都要调）
    private func cancelMatchingTimers() {
        matchingQuickTask?.cancel()
        matchingRetryTask?.cancel()
        matchingPollTask?.cancel()
        matchingQuickTask = nil
        matchingRetryTask = nil
        matchingPollTask = nil
    }

    /// 邀请字典 + timer 全清（teardown / state→inPK 时调）
    private func cancelAllInviteTimers() {
        for (_, t) in inviteTimers { t.cancel() }
        inviteTimers.removeAll()
        invitedAnchors.removeAll()
    }

    // MARK: - 用户操作：邀请

    /// 主动邀请指定主播（H5 同步：最多 5 个并发；idle/inviting 都可发起）。
    /// - 重复邀请同一 anchorId 拒绝
    /// - 满 5 个拒绝
    /// - 首次邀请 idle→inviting；后续邀请保持 inviting
    /// - 每条独立 60s 超时（独立 inviteTimers task）
    func inviteByAnchorId(_ anchorId: Int, duration: Int, nickname: String? = nil, avatar: String? = nil) async {
        // 状态守卫：H5 livePk.js:434 允许 LIVE 或 INVITING
        guard state == .idle || state == .inviting else {
            logger.warning("🟡 [PK Invite] invalid state=\(self.state.rawValue, privacy: .public)")
            return
        }
        // 重复邀请检查
        guard invitedAnchors[anchorId] == nil else {
            logger.warning("🟡 [PK Invite] anchor \(anchorId, privacy: .public) already invited")
            return
        }
        // 并发上限
        guard invitedAnchors.count < maxInviteCount else {
            logger.warning("🟡 [PK Invite] hit max invite count \(self.maxInviteCount, privacy: .public)")
            return
        }
        do {
            try await PKService.invitePk(anchorId: anchorId, pkDuration: duration)
            logger.info("🟢 [PK Invite] invitePk API ok anchor=\(anchorId, privacy: .public)")
        } catch {
            logger.error("🔴 [PK Invite] invitePk FAILED: \(String(describing: error), privacy: .private)")
            // 单条失败不影响其他邀请，安静返回（state 保持当前）
            return
        }
        // 加入字典 + 启动该条独立 60s 超时
        let item = PKInvitedItem(anchorUserId: anchorId,
                                  inviteTime: Date(),
                                  duration: duration,
                                  nickname: nickname,
                                  avatar: avatar)
        invitedAnchors[anchorId] = item
        startSingleInviteTimer(anchorId: anchorId)
        // 首条邀请进 .inviting；后续保持
        if state == .idle {
            transition(to: .inviting)
        }
        // 维持 PKMatchingOverlay 不显示但 entry 显示"+追加" 用 inviteRemainingSeconds = 该条剩余
        inviteRemainingSeconds = 60
    }

    /// 启动某条邀请的 60s 独立倒计时（超时自动调 handleInvite(.timeout) + 移除字典）。
    private func startSingleInviteTimer(anchorId: Int) {
        inviteTimers[anchorId]?.cancel()
        inviteTimers[anchorId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self else { return }
            if Task.isCancelled { return }
            guard self.invitedAnchors[anchorId] != nil else { return }
            logger.notice("🟡 [PK Invite] anchor \(anchorId, privacy: .public) 60s 超时，自动 timeout 上报")
            await self.handleInviteSingleTimeout(anchorId: anchorId)
        }
    }

    /// 单条邀请 60s 超时：调 handleInvite(.timeout) 通知后端 + 从字典移除 + 检查回 idle。
    private func handleInviteSingleTimeout(anchorId: Int) async {
        guard let item = invitedAnchors[anchorId] else { return }
        do {
            try await PKService.handleInvite(inviterId: anchorId,
                                              type: .timeout,
                                              pkDuration: item.duration)
        } catch {
            logger.warning("handleInvite(.timeout) API failed: \(String(describing: error), privacy: .private)")
        }
        removeInvite(anchorId: anchorId)
    }

    /// 取消单条邀请（指定 anchorId）。
    func cancelInviteSingle(anchorId: Int) async {
        guard let item = invitedAnchors[anchorId] else { return }
        do {
            try await PKService.handleInvite(inviterId: anchorId,
                                              type: .cancel,
                                              pkDuration: item.duration)
        } catch {
            logger.warning("cancelInvite single API failed: \(String(describing: error), privacy: .private)")
        }
        removeInvite(anchorId: anchorId)
    }

    /// 取消所有邀请（兜底入口）。逐条通知后端 + 清字典 + transition .idle。
    func cancelInvite() async {
        guard state == .inviting else { return }
        let anchors = Array(invitedAnchors.keys)
        for anchorId in anchors {
            await cancelInviteSingle(anchorId: anchorId)
        }
        // removeInvite 内部会在字典空时 transition .idle，此处无需再 transition
    }

    /// 从字典移除单条邀请 + 取消对应 timer。字典空时自动 transition .inviting → .idle。
    /// 注：调用前已通知后端（除非是 handle99_ack 被对方拒绝/取消 路径）。
    private func removeInvite(anchorId: Int) {
        inviteTimers[anchorId]?.cancel()
        inviteTimers.removeValue(forKey: anchorId)
        invitedAnchors.removeValue(forKey: anchorId)
        if invitedAnchors.isEmpty && state == .inviting {
            inviteRemainingSeconds = 0
            transition(to: .idle)
        }
    }

    /// 接受 PK 邀请（invited → starting → inPK；调 handleInvite(accept) + joinPk）。
    func acceptInvite() async {
        guard state == .invited, let info = receivedInvite else { return }
        countdown.cancelInvite()
        transition(to: .starting)
        do {
            try await PKService.handleInvite(inviterId: info.userId,
                                             type: .accept,
                                             pkDuration: info.pkDuration)
            let resp = try await PKService.joinPk(roomId: ownRoomId,
                                                  pkDuration: info.pkDuration,
                                                  oppositeAnchorId: info.userId,
                                                  pkType: .invite)
            enterInPK(from: resp,
                      oppositeUserId: info.userId,
                      oppositeNickname: info.nickname,
                      oppositeAvatar: info.avatar,
                      oppositeChannel: info.agoraChannelId,
                      duration: info.pkDuration,
                      pkType: .invite)
        } catch {
            logger.error("acceptInvite chain failed: \(String(describing: error), privacy: .private)")
            transition(to: .failed)
        }
    }

    /// 拒绝邀请（invited → idle）。
    func rejectInvite() async {
        guard state == .invited, let info = receivedInvite else { return }
        countdown.cancelInvite()
        receivedInvite = nil
        do {
            try await PKService.handleInvite(inviterId: info.userId,
                                             type: .reject,
                                             pkDuration: info.pkDuration)
        } catch {
            logger.warning("rejectInvite API failed: \(String(describing: error), privacy: .private)")
        }
        transition(to: .idle)
    }

    // MARK: - 用户操作：结束

    /// PK 进行中主动中断（inPK → endingPK → punishing；H5 endPk(isActiveDisconnect=2)）。
    func endPKActive() async {
        guard state == .inPK, let c = ctx else { return }
        transition(to: .endingPK)
        do {
            try await PKService.endPk(pkId: c.pkId,
                                      roomId: ownRoomId,
                                      oppositeAnchorId: c.oppositeUserId,
                                      isActiveDisconnect: .activeInterrupt)
            enterPunishing(seconds: 120)
        } catch {
            logger.error("endPk failed: \(String(describing: error), privacy: .private)")
            transition(to: .failed)
        }
    }

    /// 惩罚态主动结束（punishing → endingPK → idle）。
    func endPunishActive() async {
        guard state == .punishing, let c = ctx else { return }
        transition(to: .endingPK)
        do {
            try await PKService.endPunishing(pkId: c.pkId,
                                             roomId: ownRoomId,
                                             oppositeAnchorId: c.oppositeUserId,
                                             isActiveDisconnect: .activeInterrupt,
                                             disconnectFromStatus: .punishing)
        } catch {
            logger.warning("endPunishing API failed but tear down: \(String(describing: error), privacy: .private)")
        }
        await exitToIdle(finalScores: scores)
    }

    // MARK: - 用户操作：邀请开关

    /// PK 期间用户手动切了"接受邀请"开关 → 标记后续不覆盖恢复（spec §8.3 R6）。
    func userToggledInviteSwitch(_ close: Bool) async {
        userToggledInviteSwitch = true
        await updateInviteSwitchSafe(close: close)
    }

    /// 邀请弹窗打开时调用：拉取"接受邀请"开关当前值（仅首次或失败时；幂等）。
    /// 已加载且不在 loading → 跳过；接口失败保留默认 true（H5 同行为：兜底允许接受）。
    func loadInviteSwitchIfNeeded() async {
        guard !inviteSwitchLoading else { return }
        inviteSwitchLoading = true
        defer { inviteSwitchLoading = false }
        do {
            let acceptOn = try await PKService.queryInviteSwitch()
            acceptInviteSwitchOn = acceptOn
            logger.info("loadInviteSwitch ok acceptOn=\(acceptOn, privacy: .public)")
        } catch {
            logger.warning("queryInviteSwitch failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 用户在邀请弹窗手动切换"接受邀请"开关。
    /// - `accept=false` 同时本端处于 .invited → 同步拒绝当前邀请（H5 line 363-367 行为）
    /// - 写入接口同步本端 published 值
    func setInviteSwitch(accept: Bool) async {
        let prev = acceptInviteSwitchOn
        acceptInviteSwitchOn = accept                   // 乐观更新 UI
        // 关闭开关时若处于被邀请态 → 同步拒绝（H5 同行为）
        if !accept, state == .invited {
            await rejectInvite()
        }
        // PK 期内手动切换标记为"用户主动"，PK 结束时不覆盖（spec §8.3 R6）
        if state == .inPK || state == .punishing {
            userToggledInviteSwitch = true
        }
        do {
            try await PKService.updateInviteSwitch(close: !accept)
        } catch {
            logger.warning("setInviteSwitch updateInviteSwitch failed: \(String(describing: error), privacy: .private)")
            acceptInviteSwitchOn = prev                 // 回滚
        }
    }

    // MARK: - 用户操作：推荐列表（PKInviteSheet）

    /// 邀请弹窗打开时调用：刷新推荐列表（重置分页 + 拉第一页）。
    /// 当前若处于 .matching → 仍允许查看列表（H5 在 matching 时禁止点击 invite 按钮，由 UI 控制）。
    func refreshRecommendList() async {
        recommendCurrentPage = 1
        recommendHasMore = true
        recommendList = []
        await loadMoreRecommend()
    }

    /// 加载下一页（推荐 or 搜索结果根据 isSearching 分流）。
    /// 由 UI 滚动到底部触发。
    func loadMoreRecommend() async {
        guard !recommendLoading, recommendHasMore else { return }
        recommendLoading = true
        defer { recommendLoading = false }
        let page = recommendCurrentPage
        let kw = searchKeyword.trimmingCharacters(in: .whitespaces)
        let anchorIdParam: Int? = isSearching && Int(kw) != nil ? Int(kw) : nil
        let nicknameParam: String? = isSearching && anchorIdParam == nil && !kw.isEmpty ? kw : nil
        do {
            let items = try await PKService.getRecommendAnchorList(currentPage: page,
                                                                    pageSize: 20,
                                                                    anchorId: anchorIdParam,
                                                                    nickname: nicknameParam)
            recommendList.append(contentsOf: items)
            recommendCurrentPage = page + 1
            // hasMore：少于 pageSize 视为最后一页
            recommendHasMore = items.count >= 20
            logger.info("loadMoreRecommend page=\(page, privacy: .public) got=\(items.count, privacy: .public) total=\(self.recommendList.count, privacy: .public)")
        } catch {
            logger.warning("loadMoreRecommend failed: \(String(describing: error), privacy: .private)")
            recommendHasMore = false                    // 失败时关闭 loadMore 触发器，避免重复重试
        }
    }

    /// 设置搜索关键词（UI TextField onChange）。
    func setSearchKeyword(_ value: String) {
        searchKeyword = value
    }

    /// 触发搜索：按当前 searchKeyword 重置列表 + 拉第一页。
    /// 关键词为空 → 退出搜索态，刷推荐列表。
    func performSearch() async {
        let kw = searchKeyword.trimmingCharacters(in: .whitespaces)
        if kw.isEmpty {
            isSearching = false
            await refreshRecommendList()
            return
        }
        isSearching = true
        recommendCurrentPage = 1
        recommendHasMore = true
        recommendList = []
        await loadMoreRecommend()
    }

    /// 清除搜索：回到推荐态。
    func clearSearch() async {
        searchKeyword = ""
        isSearching = false
        await refreshRecommendList()
    }

    // MARK: - NIM 入口（M4 由 PKNIMRouter 路由）

    /// attachType=97 收到 PK 邀请。
    func handle97_invite(_ info: PKInviteInfo) {
        guard state == .idle else {
            // 已在 PK / 匹配中 → 忽略；后端 invite 开关应已挡
            logger.warning("handle97 ignored: state=\(self.state.rawValue)")
            return
        }
        receivedInvite = info
        transition(to: .invited)
        startInviteCountdown(seconds: 60)
    }

    /// attachType=98 PK 实时分数 + Top3 更新。
    /// **仅 `.inPK` 期间响应**：punishing 阶段是惩罚时间，礼物不计 PK 贡献（业务规则），即使后端误推也忽略。
    func handle98_score(_ update: PKScoreUpdate) {
        guard state == .inPK else {
            logger.warning("🎁 [PK Score] ignored: state=\(self.state.rawValue) (punishing/idle 不计贡献)")
            return
        }
        scores = update
        logger.info("🎁 [PK Score] my=\(update.pkCounter ?? 0) opp=\(update.oppositePkCounter ?? 0) myTop3=\(update.top3Users?.count ?? 0) oppTop3=\(update.oppositeTop3Users?.count ?? 0)")
        observer?.pkStore(self, didUpdateScores: update)
    }

    /// attachType=99 邀请状态变更（1接受 / 2拒绝 / 4取消；3超时不走推送）。
    /// **5 并发邀请改造**：从 invitedAnchors 字典按 userId 查找；不再依赖单一 state.inviting + 单条 receivedInvite。
    func handle99_ack(_ ack: PKInviteAck) {
        switch ack.inviteStatus {
        case 1:
            // 被邀请方接受 → 主动方调 joinPk → inPK
            // 必须本端处于 .inviting + 字典中确实有这个 anchorId
            guard state == .inviting, let oppositeId = ack.userId,
                  invitedAnchors[oppositeId] != nil else { return }
            Task { [weak self] in await self?.handleInviteAccepted(ack) }
        case 2:
            // 被某主播拒绝：仅移除该条邀请；其他邀请继续等
            guard state == .inviting, let oppositeId = ack.userId else { return }
            logger.info("🟡 [PK Invite] anchor \(oppositeId, privacy: .public) rejected")
            removeInvite(anchorId: oppositeId)
        case 4:
            // 主动方取消邀请 → 被邀请方收到通知，清理被邀请态（这里是接收侧）
            guard state == .invited else { return }
            countdown.cancelInvite()
            receivedInvite = nil
            transition(to: .idle)
        default:
            // inviteStatus=3 超时不走 99，本端 60s 倒计时到期本端主动调 handleInvite(type:.timeout)
            logger.warning("handle99 unknown inviteStatus=\(ack.inviteStatus)")
        }
    }

    private func handleInviteAccepted(_ ack: PKInviteAck) async {
        guard state == .inviting, let oppositeId = ack.userId,
              let item = invitedAnchors[oppositeId] else { return }
        // 选定该条邀请 → 取消其他邀请的本地 timer（后端 callState=3 后会自动拒绝其他主播接受其他邀请）
        // 不主动通知后端 cancel 其他邀请——H5 行为同（livePk.js:1500 仅 filter 移除当前 userId）。
        for (otherId, _) in invitedAnchors where otherId != oppositeId {
            inviteTimers[otherId]?.cancel()
            inviteTimers.removeValue(forKey: otherId)
        }
        invitedAnchors.removeAll()
        inviteTimers.removeAll()
        countdown.cancelInvite()
        transition(to: .starting)
        do {
            // pkDuration 优先用本端邀请时的 duration（H5 livePk.js:1492 同行为）
            let duration = item.duration
            let resp = try await PKService.joinPk(roomId: ownRoomId,
                                                  pkDuration: duration,
                                                  oppositeAnchorId: oppositeId,
                                                  pkType: .invite)
            enterInPK(from: resp,
                      oppositeUserId: oppositeId,
                      oppositeNickname: ack.nickname ?? item.nickname,
                      oppositeAvatar: item.avatar,
                      oppositeChannel: ack.agoraChannelId,
                      duration: duration,
                      pkType: .invite)
        } catch {
            logger.error("🔴 [PK Invite] handleInviteAccepted joinPk FAILED: \(String(describing: error), privacy: .private)")
            do { try await PKService.cancelMatch() } catch { logger.warning("cancelMatch fallback failed: \(error)") }
            transition(to: .idle)
        }
    }

    /// attachType=100 PK 状态束（按 data.pkStatus 子分发 7/8/9/10/-1）。
    func handle100_status(_ bundle: PKStatusBundle) {
        switch bundle.pkStatus {
        case 10:
            // 匹配成功（主态独有）
            guard state == .matching, let oppositeId = bundle.userId else { return }
            cancelMatchingTimers()
            matchingRetryStarted = false
            transition(to: .starting)
            Task { [weak self] in await self?.handleMatchSuccess(bundle, oppositeId: oppositeId) }
        case 8:
            // PK 结束进惩罚
            logger.info("🏁 [PK End→Punish] result=\(bundle.result ?? -1) my=\(bundle.pkCounter ?? 0) opp=\(bundle.oppositePkCounter ?? 0) isActiveInterrupt=\(bundle.isActiveInterrupt ?? false)")
            guard state == .inPK else { return }
            // 后端推送时可能附带 result/pkCounter，scores 兜底
            if let pkCounter = bundle.pkCounter, let oppCounter = bundle.oppositePkCounter {
                scores = PKScoreUpdate(pkCounter: pkCounter,
                                       oppositePkCounter: oppCounter,
                                       top3User: scores?.top3User,
                                       oppositeTop3User: scores?.oppositeTop3User,
                                       top3Users: scores?.top3Users,
                                       oppositeTop3Users: scores?.oppositeTop3Users)
            }
            // v22（2026-07-11）：result 来自后端广播；主动结束路径 result=nil 由 enterPunishing 内本地算
            enterPunishing(seconds: 120, resultFromBundle: bundle.result,
                           opponentNickname: bundle.nickname ?? ctx?.oppositeNickname)
        case 9:
            // 对方结束 / 中断；仅结束 PK，本端不下播
            logger.info("🏁 [PK Opposite Ended] currentState=\(self.state.rawValue) currentScores my=\(self.scores?.pkCounter ?? 0) opp=\(self.scores?.oppositePkCounter ?? 0) bundleScores my=\(bundle.pkCounter ?? -1) opp=\(bundle.oppositePkCounter ?? -1)")
            // 后端 push 时若带最新分数则覆盖本端 scores（pkStatus=9 也可能携带最终分数）
            if let pkCounter = bundle.pkCounter, let oppCounter = bundle.oppositePkCounter {
                scores = PKScoreUpdate(pkCounter: pkCounter,
                                       oppositePkCounter: oppCounter,
                                       top3User: scores?.top3User,
                                       oppositeTop3User: scores?.oppositeTop3User,
                                       top3Users: scores?.top3Users,
                                       oppositeTop3Users: scores?.oppositeTop3Users)
            }
            Task { [weak self] in await self?.exitToIdle(finalScores: self?.scores) }
        case -1:
            // 对方异常断线（连续 20s 无心跳）
            logger.warning("🏁 [PK Opposite Disconnect] pkStatus=-1 abnormal")
            transition(to: .failed)
            Task { [weak self] in await self?.exitToIdle(finalScores: self?.scores) }
        case 7:
            // 7 仅客态进 PK；G 范围外（主态不处理）
            logger.info("handle100 pkStatus=7 (audience side) ignored on host")
        default:
            logger.warning("handle100 unknown pkStatus=\(bundle.pkStatus)")
        }
    }

    private func handleMatchSuccess(_ bundle: PKStatusBundle, oppositeId: Int) async {
        // 默认时长 300（PK_TIME.RANDOM_PK_DURATION）
        let duration = 300
        do {
            let resp = try await PKService.joinPk(roomId: ownRoomId,
                                                  pkDuration: duration,
                                                  oppositeAnchorId: oppositeId,
                                                  pkType: .random)
            enterInPK(from: resp,
                      oppositeUserId: oppositeId,
                      oppositeNickname: bundle.nickname,
                      oppositeAvatar: bundle.avatar,
                      oppositeChannel: bundle.agoraChannelId,
                      duration: duration,
                      pkType: .random)
        } catch {
            logger.error("🔴 [PK Match] handleMatchSuccess joinPk FAILED: \(String(describing: error), privacy: .private)")
            // 匹配成功后 joinPk 失败：服务端可能已把本端锁在 PK 池中，必须 cancelMatch 通知后端清理
            // 避免 UI 卡在 .failed（既无 overlay 也无 entry button）→ 直接回 .idle
            do { try await PKService.cancelMatch() } catch { logger.warning("cancelMatch fallback failed: \(error)") }
            transition(to: .idle)
        }
    }

    /// attachType=-8 静音对方广播（H5 同步走 mutePkRoom API + NIM 广播）。
    func handleMute(_ mute: Bool) async {
        guard state == .inPK else { return }
        do {
            try await PKService.mutePkRoom(mute: mute)
        } catch {
            logger.warning("mutePkRoom API failed: \(String(describing: error), privacy: .private)")
        }
        // attachType=-8 NIM 广播由 NIMChatroomManager 在 M4 接入时附带
    }

    // MARK: - 中断重连（M5；本期留接口）

    /// G M5-3：500ms 防抖调度一次 `reconcileOnReconnect`，避免前台 / 弱网恢复 / NIM 重连三入口
    /// 短时间齐发时重复触发。
    ///
    /// **cancel 语义**：`try? await Task.sleep` 被 cancel 时 CancellationError 被 try? 吞掉，
    /// 控制流仍会继续走到 `reconcileOnReconnect`——必须显式 `Task.isCancelled` 短路，否则
    /// 500ms 内多入口齐发会导致旧 task 立即执行 + 新 task 500ms 后执行 = 重复 API 打点。
    func scheduleReconcile() {
        reconcileDebounceTask?.cancel()
        reconcileDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reconcileOnReconnect()
        }
    }

    /// 前后台恢复 / 弱网恢复 / NIM 长连重连成功时调用，校验远端 PK 是否仍在。
    /// H5 行为：getPkStatus 返回 'INPK' / 'PUNISHING' / null；与本地 state 校验，不一致以远端为准。
    /// 本地 ctx 缺失（进程被杀）时直接当 PK 已退，让用户重新发起。
    ///
    /// **前置守卫**（对齐 H5 `syncPkStateAfterReconnect` line 962-966 `isInPkOrPunishing`）：
    /// 仅当本地处于 `.inPK / .punishing` 时才发起校验；其他状态（含 idle/matching/inviting/invited/starting/endingPK）
    /// 直接返回不发接口，避免直播期间每次前后台/弱网/NIM 重连都无条件打点 getPkStatus。
    func reconcileOnReconnect() async {
        guard state == .inPK || state == .punishing else {
            logger.info("reconcile: skipped, local state=\(self.state.rawValue) not in PK/punishing")
            return
        }
        do {
            let remote = try await PKService.getPkStatus()
            switch (remote, state) {
            case (.inPK, .inPK), (.punishing, .punishing):
                logger.info("reconcile: state aligned remote=\(remote?.rawValue ?? "nil")")
            case (.inPK, _) where ctx != nil:
                logger.info("reconcile: remote in PK, local out → can't rebuild ctx fully; staying idle")
                // ctx 内存还在则 align 到 inPK，否则保持 idle（H5 同行为）
            case (nil, .inPK), (nil, .punishing):
                logger.warning("reconcile: remote NOT in PK while local thought yes → tear down")
                await exitToIdle(finalScores: scores)
            default:
                break
            }
        } catch {
            logger.warning("reconcile: getPkStatus failed: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - 生命周期

    /// LiveStore.state→ended 时由 LiveStore 调用：取消所有 timer + 通知后端清匹配池 + 解订阅 + 清字段。
    /// **真根因修复**：teardown 之前不通知后端，导致用户退播/杀 app 时后端 callState 残留 2，
    /// 其他主播看本端"匹配中"永远无法邀请。本函数对各状态强制通知对应 API：
    /// - matching → POST /api/pk/cancelMatch
    /// - inviting → POST /api/pk/handleInvite(type:.cancel)
    /// - invited → POST /api/pk/handleInvite(type:.reject)
    /// - inPK / punishing → POST /api/pk/endPk / endPunishing
    func teardown() async {
        let prevState = state
        logger.info("🚪 [PK Teardown] entered from state=\(prevState.rawValue, privacy: .public)")
        countdown.cancelAll()
        cancelMatchingTimers()
        cancelAllInviteTimers()
        unsubscribeNetworkQuality()
        // 真根因修复：teardown 前通知后端清理服务端态，否则后端 callState 残留导致主播"假在匹配中"
        switch prevState {
        case .matching:
            do {
                try await PKService.cancelMatch()
                logger.info("🚪 [PK Teardown] cancelMatch API ok")
            } catch {
                logger.warning("🚪 [PK Teardown] cancelMatch failed: \(String(describing: error), privacy: .private)")
            }
        case .inviting:
            do {
                try await PKService.handleInvite(inviterId: 0, type: .cancel, pkDuration: 0)
                logger.info("🚪 [PK Teardown] handleInvite(.cancel) API ok")
            } catch {
                logger.warning("🚪 [PK Teardown] handleInvite(.cancel) failed: \(String(describing: error), privacy: .private)")
            }
        case .invited:
            if let info = receivedInvite {
                do {
                    try await PKService.handleInvite(inviterId: info.userId, type: .reject, pkDuration: info.pkDuration)
                    logger.info("🚪 [PK Teardown] handleInvite(.reject) API ok")
                } catch {
                    logger.warning("🚪 [PK Teardown] handleInvite(.reject) failed: \(String(describing: error), privacy: .private)")
                }
            }
        case .inPK:
            if let c = ctx {
                do {
                    try await PKService.endPk(pkId: c.pkId, roomId: ownRoomId,
                                              oppositeAnchorId: c.oppositeUserId,
                                              isActiveDisconnect: .activeInterrupt)
                    logger.info("🚪 [PK Teardown] endPk API ok")
                } catch {
                    logger.warning("🚪 [PK Teardown] endPk failed: \(String(describing: error), privacy: .private)")
                }
            }
        case .punishing:
            if let c = ctx {
                do {
                    try await PKService.endPunishing(pkId: c.pkId, roomId: ownRoomId,
                                                     oppositeAnchorId: c.oppositeUserId,
                                                     isActiveDisconnect: .activeInterrupt,
                                                     disconnectFromStatus: .punishing)
                    logger.info("🚪 [PK Teardown] endPunishing API ok")
                } catch {
                    logger.warning("🚪 [PK Teardown] endPunishing failed: \(String(describing: error), privacy: .private)")
                }
            }
        default:
            break
        }
        // PK 频道也要主动 leaveChannelEx 释放声网资源
        if let channel = ctx?.oppositeChannel, !channel.isEmpty {
            await agora?.leavePKOpposite(channel: channel)
        }
        ctx = nil
        scores = nil
        receivedInvite = nil
        inviteRemainingSeconds = 0
        pkRemainingSeconds = 0
        punishRemainingSeconds = 0
        matchingRetryStarted = false
        userToggledInviteSwitch = false
        inviteSwitchEntrySnapshot = nil
        hasShownResult = false
        state = .idle
        // teardown 路径不调 setCallState（直播已 ended，LiveStore.setCallState 内 guard 会拦）
    }

    // MARK: - transition + 内部辅助

    private func transition(to next: PKStateMain) {
        guard next != state else { return }
        logger.info("PK transition \(self.state.rawValue) → \(next.rawValue)")
        state = next
        updateCallState(for: next)
        updatePrivateCallVisibility(for: next)
        observer?.pkStore(self, didChange: next)
    }

    /// PK 期间强制关闭 + 隐藏私 call 开关；PK 结束还原（对齐 H5 liveRoom.vue:466 shouldShowPrivateCall）。
    /// **可见规则**：仅 `.idle` / `.failed` 显示；其他所有态（matching/inviting/invited/starting/inPK/punishing/endingPK）隐藏。
    /// endingPK 也隐藏——瞬时态很快切到 idle/failed 会自然恢复；隐藏期间用户看到的是稳定关态。
    private func updatePrivateCallVisibility(for next: PKStateMain) {
        switch next {
        case .idle, .failed:
            liveStore?.resumePrivateCallAfterPK()
        case .matching, .inviting, .invited, .starting, .inPK, .punishing, .endingPK:
            liveStore?.pausePrivateCallForPK()
        }
    }

    private func updateCallState(for next: PKStateMain) {
        let value: Int
        switch next {
        case .idle, .failed:
            value = 0
        case .matching, .inviting, .invited:
            value = 2
        case .starting, .inPK, .punishing:
            value = 3
        case .endingPK:
            return                                            // 瞬时态不主动改 callState
        }
        liveStore?.setCallState(value)
    }

    private func enterInPK(from resp: PKJoinResponse,
                           oppositeUserId: Int,
                           oppositeNickname: String?,
                           oppositeAvatar: String?,
                           oppositeChannel: String?,
                           duration: Int,
                           pkType: PKType) {
        // H5 行为：endTime 本地自算 Date() + duration
        let end = Date().addingTimeInterval(TimeInterval(duration))
        ctx = PKContext(pkId: resp.pkId,
                        oppositeUserId: oppositeUserId,
                        oppositeNickname: oppositeNickname ?? resp.nickname,
                        oppositeAvatar: oppositeAvatar ?? resp.avatar,
                        oppositeChannel: oppositeChannel,
                        oppositeYxAccId: resp.yxAccId,
                        duration: duration,
                        endTime: end,
                        pkType: pkType)
        scores = nil
        hasShownResult = false       // 新一轮 PK 起点，重置结果窗 flag
        transition(to: .inPK)
        startInPKCountdown(endAt: end)
        subscribeNetworkQuality()
        // M3 bug 修复：必须真正调 joinChannelEx 加对手 PK 频道；否则只有状态机 + UI，SDK 没拉对手画面
        if let channel = oppositeChannel, !channel.isEmpty,
           !rtcToken.isEmpty, ownAnchorId > 0 {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.agora?.joinPKOpposite(channel: channel,
                                                         oppositeUid: UInt(oppositeUserId),
                                                         token: self.rtcToken,
                                                         ownUid: UInt(self.ownAnchorId))
                } catch {
                    logger.error("joinPKOpposite failed: \(String(describing: error), privacy: .private)")
                }
            }
        } else {
            logger.warning("enterInPK skipped joinPKOpposite: channel=\(oppositeChannel ?? "nil") tokenLen=\(self.rtcToken.count) anchorId=\(self.ownAnchorId)")
        }
        Task { [weak self] in
            await self?.enterPKInviteSwitchSnapshotAndDisable()
        }
        // v22（2026-07-11）：本地 append "PK is on!" 公屏消息（对齐 H5 startPreparingCountdown 结束广播）
        appendPKStartToPublicChat()
    }

    /// v22（2026-07-11）：主态本地 append PK 开始/结果公屏消息（对齐 H5 sendLiveRoomNotice + 本地 unshift）
    /// H5 主播端不依赖收到自己发送的 attachType -9 广播，本地 unshift 到 liveChatRecords；iOS 侧同款处理。
    private func appendPKStartToPublicChat() {
        guard let store = nim?.messagesStore else { return }
        store.append(PublicChatMessage(
            text: L10n.pkNotificationStart,
            isSystem: false,
            senderNickname: nil, senderAvatar: nil,
            userLevel: nil, isHost: false, isVip: false,
            messageType: .pkNotify
        ))
    }

    private func appendPKResultToPublicChat(result: Int, opponentNickname: String?) {
        guard let store = nim?.messagesStore else { return }
        let myNick = SessionStore.shared.user?.nickname ?? "Anchor"
        let oppNick = opponentNickname ?? "Opponent"
        let text: String
        switch result {
        case 1: text = L10n.pkResultWinFormat(myNick, oppNick)
        case 2: text = L10n.pkResultLoseFormat(myNick, oppNick)
        case 3: text = L10n.pkResultDrawFormat(myNick, oppNick)
        default: return
        }
        store.append(PublicChatMessage(
            text: text,
            isSystem: false,
            senderNickname: nil, senderAvatar: nil,
            userLevel: nil, isHost: false, isVip: false,
            messageType: .pkNotify
        ))
    }

    /// v22（2026-07-11）：signature 增加 resultFromBundle / opponentNickname 让公屏结果消息在所有路径下都能 append
    /// - 后端广播路径（handle100_status case 8）：传 bundle.result / bundle.nickname
    /// - 主动结束路径（endPKActive / handleInPKExpired）：传 nil，函数内用本地 scores 计算胜负
    private func enterPunishing(seconds: Int,
                                 resultFromBundle: Int? = nil,
                                 opponentNickname: String? = nil) {
        transition(to: .punishing)
        startPunishCountdown(seconds: seconds)
        unsubscribeNetworkQuality()
        if let c = ctx {
            observer?.pkStore(self, didEnterPunishing: c)
        }
        // v22（2026-07-11）：本地 append PK 结果公屏消息（对齐 H5 sendPkEndNotice）
        // result 优先 bundle 值，无则用本地 scores 计算：my > opp → 胜 1；my < opp → 败 2；相等 → 平 3
        let effectiveResult: Int
        if let r = resultFromBundle, r > 0 {
            effectiveResult = r
        } else {
            let my = scores?.pkCounter ?? 0
            let opp = scores?.oppositePkCounter ?? 0
            effectiveResult = my > opp ? 1 : (my < opp ? 2 : 3)
        }
        appendPKResultToPublicChat(result: effectiveResult,
                                    opponentNickname: opponentNickname ?? ctx?.oppositeNickname)
        // G #2 反馈修复：pkStatus=8 PK 自然结束时立即弹结果窗（含 result + 最终分数）。
        // 不等 120s punishing 结束才显示——punishing 是惩罚时间，结果应该实时可见。
        if !hasShownResult {
            hasShownResult = true
            observer?.pkStore(self, didEndPK: scores)
        }
    }

    /// 从 inPK / punishing / endingPK 退到 idle，统一清字段 + observer 通知 + invite switch 恢复。
    /// **结果窗弹出策略**（G #2 反馈修复）：
    /// - case 8 路径已在 enterPunishing 弹过结果 → `hasShownResult=true` → 本函数不重弹
    /// - case 9 / -1 路径未走 punishing → `hasShownResult=false` → 本函数补弹
    private func exitToIdle(finalScores: PKScoreUpdate?) async {
        countdown.cancelAll()
        unsubscribeNetworkQuality()
        let snapshot = scores ?? finalScores
        // M3 bug 修复：离开 PK 时必须 leaveChannelEx 对手频道，否则 SDK 残留连接 + 资源泄漏
        if let channel = ctx?.oppositeChannel, !channel.isEmpty {
            await agora?.leavePKOpposite(channel: channel)
        }
        await restoreInviteSwitchIfNeeded()
        ctx = nil
        receivedInvite = nil
        inviteRemainingSeconds = 0
        pkRemainingSeconds = 0
        punishRemainingSeconds = 0
        let shouldNotifyResult = !hasShownResult
        hasShownResult = false
        transition(to: .idle)
        if shouldNotifyResult {
            observer?.pkStore(self, didEndPK: snapshot)
        }
        scores = nil
    }

    // MARK: - 倒计时

    private func startInviteCountdown(seconds: Int) {
        inviteRemainingSeconds = seconds
        countdown.scheduleInvite(seconds: seconds,
                                 onTick: { [weak self] remaining in
                                     self?.inviteRemainingSeconds = remaining
                                 },
                                 onExpire: { [weak self] in
                                     guard let self else { return }
                                     Task { await self.handleInviteTimeout() }
                                 })
    }

    private func startInPKCountdown(endAt: Date) {
        pkRemainingSeconds = max(0, Int(endAt.timeIntervalSinceNow))
        countdown.scheduleInPK(endAt: endAt,
                               onTick: { [weak self] remaining in
                                   self?.pkRemainingSeconds = remaining
                               },
                               onExpire: { [weak self] in
                                   guard let self else { return }
                                   Task { await self.handleInPKExpired() }
                               })
    }

    private func startPunishCountdown(seconds: Int) {
        punishRemainingSeconds = seconds
        countdown.schedulePunish(seconds: seconds,
                                 onTick: { [weak self] remaining in
                                     self?.punishRemainingSeconds = remaining
                                 },
                                 onExpire: { [weak self] in
                                     guard let self else { return }
                                     Task { await self.handlePunishExpired() }
                                 })
    }

    /// 邀请态本地 60s 倒计时到期：
    /// - inviting：主动方超时调 handleInvite(type:.timeout) 上报 → 回 idle
    /// - invited：被邀请方超时同样调 handleInvite(type:.timeout) + 清 receivedInvite
    private func handleInviteTimeout() async {
        let targetType: PKInviteHandle = .timeout
        let inviterId: Int
        let duration: Int
        switch state {
        case .inviting:
            inviterId = 0   // M3 由 LiveRoomView 注入被邀请方 id（受邀者侧的 inviterId 实为我方）
            duration = 0
        case .invited:
            inviterId = receivedInvite?.userId ?? 0
            duration = receivedInvite?.pkDuration ?? 0
        default:
            return
        }
        do {
            try await PKService.handleInvite(inviterId: inviterId,
                                             type: targetType,
                                             pkDuration: duration)
        } catch {
            logger.warning("handleInviteTimeout API failed: \(String(describing: error), privacy: .private)")
        }
        receivedInvite = nil
        transition(to: .idle)
    }

    /// PK 倒计时归零：endPk(isActiveDisconnect=1) 自然结束 → punishing
    private func handleInPKExpired() async {
        guard state == .inPK, let c = ctx else { return }
        do {
            try await PKService.endPk(pkId: c.pkId,
                                      roomId: ownRoomId,
                                      oppositeAnchorId: c.oppositeUserId,
                                      isActiveDisconnect: .normal)
            enterPunishing(seconds: 120)
        } catch {
            logger.error("handleInPKExpired endPk failed: \(String(describing: error), privacy: .private)")
            transition(to: .failed)
        }
    }

    /// 惩罚倒计时归零：endPunishing(.normal, .punishing) → idle
    private func handlePunishExpired() async {
        guard state == .punishing, let c = ctx else { return }
        do {
            try await PKService.endPunishing(pkId: c.pkId,
                                             roomId: ownRoomId,
                                             oppositeAnchorId: c.oppositeUserId,
                                             isActiveDisconnect: .normal,
                                             disconnectFromStatus: .punishing)
        } catch {
            logger.warning("handlePunishExpired API failed: \(String(describing: error), privacy: .private)")
        }
        await exitToIdle(finalScores: scores)
    }

    // MARK: - 弱网订阅（spec §3.5）

    private func subscribeNetworkQuality() {
        guard let nm = networkMonitor, nqCancellable == nil else { return }
        nqCancellable = nm.$currentLevel.sink { [weak self] level in
            guard let self else { return }
            if level == .weakSevere {
                self.agora?.applyEncoderQuality(.pkLow)
            } else if level == .weakWarning {
                // PK 期 weakWarning 也降一档（与非 PK 期 .low 共面，但用 PK 容器分辨率 480x640）
                self.agora?.applyEncoderQuality(.pkLow)
            } else if level == .normal {
                self.agora?.applyEncoderQuality(.pkActive)
                // M5-3：弱网恢复时也调度一次 reconcile，校验远端 PK 状态
                self.scheduleReconcile()
            }
        }
    }

    private func unsubscribeNetworkQuality() {
        nqCancellable?.cancel()
        nqCancellable = nil
    }

    // MARK: - invite switch（spec §8.3 R6 / R11）

    /// 进 PK 时关闭"接受邀请"开关；entry 时快照原值用于退出恢复。
    /// 防 R11 非幂等：isUpdatingInviteSwitch 防重入。
    private func enterPKInviteSwitchSnapshotAndDisable() async {
        userToggledInviteSwitch = false
        inviteSwitchEntrySnapshot = false               // 假设默认开启（searchValue=0）；M3 wire 时可从持久化读真值
        await updateInviteSwitchSafe(close: true)
    }

    /// PK 退出后恢复 invite switch；用户 PK 期手动切过则尊重不覆盖。
    private func restoreInviteSwitchIfNeeded() async {
        if userToggledInviteSwitch {
            logger.info("invite switch restore skipped: userToggled=true")
            userToggledInviteSwitch = false
            inviteSwitchEntrySnapshot = nil
            return
        }
        if let snapshot = inviteSwitchEntrySnapshot {
            // snapshot 为 false（开启）就 restore 到 close=false；snapshot 为 true 不动
            if !snapshot {
                await updateInviteSwitchSafe(close: false)
            }
        }
        inviteSwitchEntrySnapshot = nil
    }

    private func updateInviteSwitchSafe(close: Bool) async {
        guard !isUpdatingInviteSwitch else {
            logger.info("updateInviteSwitch already in flight, skip")
            return
        }
        isUpdatingInviteSwitch = true
        defer { isUpdatingInviteSwitch = false }
        do {
            try await PKService.updateInviteSwitch(close: close)
        } catch {
            logger.warning("updateInviteSwitch failed: \(String(describing: error), privacy: .private)")
        }
    }
}

#if DEBUG
// MARK: - 仅供单测使用的内部钩子（绕过 PKService 真调，专注测状态机）

extension PKStore {
    /// 直接驱动到指定 state（仅 DEBUG / 单测）。
    func testOnly_force(state: PKStateMain) {
        let next = state
        if next != self.state {
            self.state = next
            updateCallState(for: next)
            observer?.pkStore(self, didChange: next)
        }
    }

    /// 直接注入 ctx + scores（仅 DEBUG / 单测）。
    func testOnly_inject(ctx: PKContext?, scores: PKScoreUpdate? = nil, receivedInvite: PKInviteInfo? = nil) {
        self.ctx = ctx
        self.scores = scores
        self.receivedInvite = receivedInvite
    }
}
#endif
