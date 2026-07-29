import Foundation
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "robot-call")

/// 机器人来电只允许在底部 Tab 的根页面展示。
///
/// H5 的 `isFirstPage(route.path)` 语义在 SwiftUI 中由 MainTabView 的 NavigationPath
/// 派生。默认关闭，避免登录/页面切换尚未完成时的 NIM 消息覆盖子页面。
@MainActor
final class RobotCallRouteGate: ObservableObject {
    static let shared = RobotCallRouteGate()

    @Published private(set) var isAtRootPage = false

    private init() {}

    func update(isAtRootPage: Bool) {
        self.isAtRootPage = isAtRootPage
    }
}

/// 机器人通话独立状态机。
///
/// 不复用真人 1v1 `CallStore`：机器人通话没有 RTM 信令/远端 RTC 建链；远端画面由
/// 服务端下发的预录视频承载，本机则独立推流到 `agoraChannelId`，结算只依赖 homeTraffic 接口。
@MainActor
final class RobotCallStore: ObservableObject {
    static let shared = RobotCallStore()

    @Published private(set) var state: RobotCallState = .idle
    @Published private(set) var invite: RobotCallInvite?
    @Published private(set) var reward: RobotCallReward?
    @Published private(set) var ringSecondsRemaining = 0
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var isRequestInFlight = false

    var canHangUp: Bool { state == .connected && elapsedSeconds >= Self.minimumCallSeconds }
    /// 真人通话和机器人通话不能并行；结算弹窗同样不能被真人通话覆盖。
    var blocksOtherCalls: Bool {
        RobotCallAdmission.blocksOtherCalls(state: state, hasVisibleReward: reward != nil)
    }

    private static let ringTimeoutSeconds = 30
    private static let minimumCallSeconds = 10
    private static let cooldownSeconds: TimeInterval = 10
    private static let maximumInviteAge: TimeInterval = 35
    private static let maximumInviteFutureSkew: TimeInterval = 60
    private static let handledInviteRetention: TimeInterval = 5 * 60

    private let service: RobotCallServing
    private let now: () -> Date
    private let broadcaster = RobotCallBroadcastSession()
    private var ringTimer: Task<Void, Never>?
    private var callTimer: Task<Void, Never>?
    private var broadcastTask: Task<Void, Never>?
    private var lastConnectedEndedAt: Date?
    private var handledInviteRecordIds: [String: Date] = [:]
    private var deferredRewards: [RobotCallReward] = []
    private var deferredRewardTask: Task<Void, Never>?

    private init(service: RobotCallServing = RobotCallService(), now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    /// 处理 attachType=133。重复、后台和业务忙碌场景都只记录日志，不打断当前工作流。
    func receiveIncoming(_ incoming: RobotCallInvite) {
        guard state == .idle, !isRequestInFlight else {
            logger.info("drop incoming record=\(incoming.recordId, privacy: .private): state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard canPresentIncoming else { return }
        let currentTime = now()
        guard incoming.isFresh(
            now: currentTime,
            maximumAge: Self.maximumInviteAge,
            maximumFutureSkew: Self.maximumInviteFutureSkew
        ) else {
            logger.info("drop incoming record=\(incoming.recordId, privacy: .private): stale notification")
            return
        }
        handledInviteRecordIds = handledInviteRecordIds.filter {
            currentTime.timeIntervalSince($0.value) < Self.handledInviteRetention
        }
        guard handledInviteRecordIds[incoming.recordId] == nil else {
            logger.info("drop incoming record=\(incoming.recordId, privacy: .private): duplicate")
            return
        }
        if let lastConnectedEndedAt,
           currentTime.timeIntervalSince(lastConnectedEndedAt) < Self.cooldownSeconds {
            logger.info("drop incoming record=\(incoming.recordId, privacy: .private): cooldown")
            return
        }

        handledInviteRecordIds[incoming.recordId] = currentTime
        reward = nil
        invite = incoming
        elapsedSeconds = 0
        ringSecondsRemaining = Self.ringTimeoutSeconds
        state = .ringing
        startRingTimer()
        startBroadcast(for: incoming)
        logger.info("incoming record=\(incoming.recordId, privacy: .private) autoHangup=\(incoming.autoHangupSeconds, privacy: .public)s")
    }

    /// 处理 attachType=132。结算消息可在通话 UI 已关闭后异步到达，因此不依赖当前状态。
    func receiveReward(_ incoming: RobotCallReward) {
        if canPresentReward {
            reward = incoming
        } else {
            deferredRewards.append(incoming)
            scheduleDeferredRewardPresentation()
        }
        logger.info("reward record=\(incoming.recordId, privacy: .private) eligible=\(incoming.isEligible, privacy: .public)")
    }

    func accept() async {
        guard state == .ringing, let invite, !isRequestInFlight else { return }
        isRequestInFlight = true
        ringTimer?.cancel()
        state = .connecting

        do {
            try await service.respond(to: invite, answered: true)
            guard state == .connecting, self.invite?.recordId == invite.recordId else { return }
            elapsedSeconds = 0
            state = .connected
            startCallTimer(for: invite)
        } catch {
            logger.error("accept failed record=\(invite.recordId, privacy: .private): \(String(describing: error), privacy: .public)")
            await stopBroadcast()
            reset(after: .acceptFailed)
            AppToastCenter.shared.show(L10n.robotCallAcceptFailed)
        }
        isRequestInFlight = false
    }

    func reject() async {
        await endRinging(reason: .rejected)
    }

    func hangUp() async {
        guard canHangUp else {
            AppToastCenter.shared.show(L10n.robotCallMinimumDuration)
            return
        }
        await endConnected(reason: .manualHangup)
    }

    func videoDidFinish() async {
        await endConnected(reason: .videoFinished)
    }

    func dismissReward() {
        reward = nil
        presentDeferredRewardIfPossible()
    }

    /// 登出/主播资格撤销时清理本地覆盖层和定时器；网络会话已失效，不再补发业务接口。
    func resetForSessionEnd() async {
        broadcastTask?.cancel()
        broadcastTask = nil
        ringTimer?.cancel()
        ringTimer = nil
        callTimer?.cancel()
        callTimer = nil
        state = .idle
        invite = nil
        reward = nil
        ringSecondsRemaining = 0
        elapsedSeconds = 0
        isRequestInFlight = false
        lastConnectedEndedAt = nil
        handledInviteRecordIds = [:]
        deferredRewardTask?.cancel()
        deferredRewardTask = nil
        deferredRewards = []
        await broadcaster.stop()
    }

    private var canPresentIncoming: Bool {
        guard UIApplication.shared.applicationState == .active else {
            logger.info("drop incoming: app inactive")
            return false
        }
        guard SessionStore.shared.user?.userType == 2 else {
            logger.info("drop incoming: user is not approved host")
            return false
        }
        guard RobotCallRouteGate.shared.isAtRootPage else {
            logger.info("drop incoming: not at root page")
            return false
        }
        guard !CallStore.shared.blocksRobotCall else {
            logger.info("drop incoming: direct call active")
            return false
        }
        guard MatchStore.shared.state == .ended else {
            logger.info("drop incoming: matching active")
            return false
        }
        guard PartyStore.shared.roomState == .idle || PartyStore.shared.roomState == .ended else {
            logger.info("drop incoming: party active")
            return false
        }
        if let liveState = CallStore.shared.liveStore?.state,
           liveState != .idle && liveState != .ended {
            logger.info("drop incoming: live active")
            return false
        }
        guard CallStore.shared.pkStore?.state == .idle || CallStore.shared.pkStore == nil else {
            logger.info("drop incoming: PK active")
            return false
        }
        return true
    }

    /// 奖励不是 RTC 会话，但它的全局模态 UI 不能遮挡任何既有通话或房间。
    private var canPresentReward: Bool {
        guard state == .idle,
              UIApplication.shared.applicationState == .active,
              SessionStore.shared.user?.userType == 2,
              !CallStore.shared.blocksRobotCall,
              MatchStore.shared.state == .ended,
              PartyStore.shared.roomState == .idle || PartyStore.shared.roomState == .ended,
              CallStore.shared.pkStore?.state == .idle || CallStore.shared.pkStore == nil
        else {
            return false
        }
        if let liveState = CallStore.shared.liveStore?.state,
           liveState != .idle && liveState != .ended {
            return false
        }
        return true
    }

    private func presentDeferredRewardIfPossible() {
        guard reward == nil, !deferredRewards.isEmpty else { return }
        guard canPresentReward else {
            scheduleDeferredRewardPresentation()
            return
        }
        reward = deferredRewards.removeFirst()
    }

    private func scheduleDeferredRewardPresentation() {
        guard deferredRewardTask == nil else { return }
        deferredRewardTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.canPresentReward else { continue }
                self.deferredRewardTask = nil
                self.presentDeferredRewardIfPossible()
                return
            }
        }
    }

    private func startRingTimer() {
        ringTimer?.cancel()
        ringTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.state == .ringing else { return }
                guard self.ringSecondsRemaining > 1 else {
                    await self.endRinging(reason: .ringingTimeout)
                    return
                }
                self.ringSecondsRemaining -= 1
            }
        }
    }

    private func startBroadcast(for invite: RobotCallInvite) {
        broadcastTask?.cancel()
        broadcastTask = Task { [weak self, broadcaster] in
            await broadcaster.start(for: invite)
            guard !Task.isCancelled,
                  let self,
                  self.state == .ringing || self.state == .connecting || self.state == .connected,
                  self.invite?.recordId == invite.recordId else {
                await broadcaster.stop()
                return
            }
        }
    }

    private func stopBroadcast() async {
        broadcastTask?.cancel()
        broadcastTask = nil
        await broadcaster.stop()
    }

    private func startCallTimer(for invite: RobotCallInvite) {
        callTimer?.cancel()
        callTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.state == .connected else { return }
                self.elapsedSeconds += 1
                if self.elapsedSeconds >= invite.autoHangupSeconds {
                    await self.endConnected(reason: .autoHangup)
                    return
                }
            }
        }
    }

    private func endRinging(reason: RobotCallEndReason) async {
        guard state == .ringing, let invite, !isRequestInFlight else { return }
        isRequestInFlight = true
        ringTimer?.cancel()
        reset(after: reason)
        await stopBroadcast()
        do {
            try await service.respond(to: invite, answered: false)
        } catch {
            logger.error("reject failed record=\(invite.recordId, privacy: .private): \(String(describing: error), privacy: .public)")
        }
        isRequestInFlight = false
    }

    private func endConnected(reason: RobotCallEndReason) async {
        guard state == .connected, let invite, !isRequestInFlight else { return }
        isRequestInFlight = true
        callTimer?.cancel()
        reset(after: reason)
        await stopBroadcast()
        do {
            try await service.finish(recordId: invite.recordId)
        } catch {
            logger.error("finish failed record=\(invite.recordId, privacy: .private): \(String(describing: error), privacy: .public)")
        }
        isRequestInFlight = false
    }

    private func reset(after reason: RobotCallEndReason) {
        let wasConnected = state == .connected
        ringTimer?.cancel()
        ringTimer = nil
        callTimer?.cancel()
        callTimer = nil
        if wasConnected { lastConnectedEndedAt = now() }
        state = .idle
        invite = nil
        ringSecondsRemaining = 0
        elapsedSeconds = 0
        logger.info("ended reason=\(String(describing: reason), privacy: .public)")
    }
}
