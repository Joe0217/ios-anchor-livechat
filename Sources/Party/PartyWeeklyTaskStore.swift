import Foundation

/// 派对房主播周任务状态：列表按需拉取，实时上麦时长和达标奖励由 P2P 1022/1023 驱动。
@MainActor
final class PartyWeeklyTaskStore: ObservableObject, MessageRouter {
    static let shared = PartyWeeklyTaskStore()

    @Published private(set) var tasks: [PartyWeeklyTask] = []
    @Published private(set) var accumulatedLiveTime = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    /// 区分“服务端确认无任务”和“首次请求失败，仍需展示入口以便重试”。
    @Published private(set) var hasLoadedInitialPage = false
    /// 当前正在麦位上播放的奖励效果。效果结束后才设置 `pendingReward` 弹出奖励窗。
    @Published private(set) var rewardEffect: PartyWeeklyTaskRewardNotification?
    @Published var pendingReward: PartyWeeklyTaskRewardNotification?

    private let pageSize = 20
    private var trackedRoomId: String?
    private var nextOffset: String?
    private var total: Int?
    private var canLoadMore = false
    private var requestSequence = 0
    private var queuedRewards: [PartyWeeklyTaskRewardNotification] = []
    private var rewardEffectTask: Task<Void, Never>?
    private var trackingStartedAt: TimeInterval?
    private var handledRewardNotificationIds: Set<String> = []

    var hasTasks: Bool { !tasks.isEmpty }
    var isTracking: Bool { trackedRoomId != nil }
    var hasMore: Bool { canLoadMore }
    /// 安卓入口不是由列表是否恰好解码成功决定；进房后始终保留，面板内可重试并等待 1022 进度。
    var showsTopProgress: Bool { isTracking }

    var topProgress: PartyWeeklyTaskTopProgress? {
        guard !tasks.isEmpty else { return nil }
        let ordered = tasks.sorted { ($0.targetLiveTime ?? .max) < ($1.targetLiveTime ?? .max) }
        guard let task = ordered.first(where: { ($0.targetLiveTime ?? .max) > accumulatedLiveTime }) ?? ordered.last else {
            return nil
        }
        let target = max(task.targetLiveTime ?? accumulatedLiveTime, 1)
        let current = max(accumulatedLiveTime, task.progressLiveTime ?? 0)
        return PartyWeeklyTaskTopProgress(
            currentTime: current,
            targetTime: target,
            rewardText: task.rewards.first?.compactText ?? ""
        )
    }

    private init() {
        NIMService.shared.registerRouter(self)
    }

    func beginTracking(roomId: String) {
        guard trackedRoomId != roomId else { return }
        trackedRoomId = roomId
        trackingStartedAt = Date().timeIntervalSince1970
        tasks = []
        accumulatedLiveTime = 0
        nextOffset = nil
        total = nil
        canLoadMore = false
        hasLoadedInitialPage = false
        handledRewardNotificationIds = []
        clearRewardPresentation()
        requestSequence &+= 1
    }

    func stopTracking(roomId: String) {
        guard trackedRoomId == roomId else { return }
        trackedRoomId = nil
        trackingStartedAt = nil
        handledRewardNotificationIds = []
        clearRewardPresentation()
        requestSequence &+= 1
    }

    func load(reset: Bool = true) async {
        guard trackedRoomId != nil else { return }
        if !reset, (!canLoadMore || isLoading || isLoadingMore) { return }

        let offset = reset ? nil : nextOffset
        let sequence = { requestSequence &+= 1; return requestSequence }()
        if reset {
            isLoading = true
            tasks = []
            nextOffset = nil
            total = nil
            canLoadMore = false
        } else {
            isLoadingMore = true
        }

        do {
            let page = try await PartyAPI.weeklyTaskInfo(pageSize: pageSize, offset: offset)
            guard sequence == requestSequence else { return }
            if reset {
                tasks = page.tasks
                hasLoadedInitialPage = true
            } else {
                let ids = Set(tasks.map(\.id))
                tasks.append(contentsOf: page.tasks.filter { !ids.contains($0.id) })
            }
            nextOffset = page.nextOffset
            total = page.total
            canLoadMore = page.nextOffset != nil && page.nextOffset != offset
            if let total {
                canLoadMore = canLoadMore && tasks.count < total
            }
        } catch {
            guard sequence == requestSequence else { return }
            AppLogger.party.error("[PartyWeeklyTask] load failed err=\(String(describing: error), privacy: .public)")
            canLoadMore = false
        }

        guard sequence == requestSequence else { return }
        isLoading = false
        isLoadingMore = false
    }

    /// P2P 1022：服务端定时下发当前用户累计上麦秒数。
    func receiveProgress(payload: [String: Any]) {
        guard isForTrackedRoom(payload),
              let liveTime = PartyWeeklyTaskPage.firstInt(in: payload, keys: ["liveTime", "accumulatedDuration"])
        else { return }
        accumulatedLiveTime = max(accumulatedLiveTime, liveTime)
    }

    /// P2P 1023：奖励已由服务端发放；客户端只展示，不能重复发领奖请求。
    func receiveReward(payload: [String: Any]) {
        guard isForTrackedRoom(payload),
              let notification = PartyWeeklyTaskRewardNotification(payload: payload)
        else { return }
        if let notificationId = PartyWeeklyTaskPage.firstString(
            in: payload,
            keys: ["_nimCustomNotificationId"]
        ) {
            guard handledRewardNotificationIds.insert(notificationId).inserted else { return }
        }
        accumulatedLiveTime = max(accumulatedLiveTime, notification.liveTime)
        queuedRewards.append(notification)
        presentNextRewardIfPossible()
    }

    /// 奖励窗只能由确认按钮关闭；延迟推进队列避免下一条覆盖正在收起的弹窗。
    func dismissReward(_ id: UUID) {
        guard pendingReward?.id == id else { return }
        pendingReward = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.presentNextRewardIfPossible()
        }
    }

    private func presentNextRewardIfPossible() {
        guard rewardEffect == nil, pendingReward == nil, !queuedRewards.isEmpty else { return }
        let notification = queuedRewards.removeFirst()
        rewardEffect = notification
        rewardEffectTask?.cancel()
        rewardEffectTask = Task { [weak self, notification] in
            // Android plays the current-seat gem effect before opening TaskRewardDialog.
            try? await Task.sleep(nanoseconds: 1_350_000_000)
            guard !Task.isCancelled else { return }
            self?.completeRewardEffect(notification.id)
        }
    }

    private func completeRewardEffect(_ id: UUID) {
        guard let notification = rewardEffect, notification.id == id else { return }
        rewardEffect = nil
        pendingReward = notification
    }

    private func clearRewardPresentation() {
        rewardEffectTask?.cancel()
        rewardEffectTask = nil
        queuedRewards = []
        rewardEffect = nil
        pendingReward = nil
    }

    /// 文档中的 1022/1023 示例不带房间号，因此缺失时按当前追踪房间处理；若服务端补带
    /// `roomId`，则拒绝迟到的上一房通知，防止在新房间弹出旧奖励。
    private func isForTrackedRoom(_ payload: [String: Any]) -> Bool {
        guard let trackedRoomId else { return false }
        guard let payloadRoomId = PartyWeeklyTaskPage.firstString(
            in: payload,
            keys: ["roomId", "partyRoomId"]
        ) else {
            // 安卓样例无 roomId。NIM 的服务端时间早于本房开始追踪时，只可能是上一房或离线补发。
            if let startedAt = trackingStartedAt,
               let timestamp = PartyWeeklyTaskPage.firstInt(
                   in: payload,
                   keys: ["_nimCustomNotificationTimestamp"]
               ) {
                return TimeInterval(timestamp) >= startedAt - 1
            }
            return true
        }
        return payloadRoomId == trackedRoomId
    }

    /// CustomNotification 正确通道：NIMService.systemNotificationManager → sysMsg。
    func route(_ attachType: AttachType, payload: [String: Any], context: MessageContext) -> Bool {
        guard case .sysMsg = context else { return false }
        var normalizedPayload = PartyWeeklyTaskPage.unwrappedPayload(from: payload)
        // `data` / `result` 归一化后仍保留 SDK 注入的去重、跨房保护元数据。
        for key in ["_nimCustomNotificationId", "_nimCustomNotificationTimestamp"] {
            normalizedPayload[key] = payload[key]
        }
        switch attachType {
        case .partyTaskProgress:
            AppLogger.party.info("[PartyWeeklyTask] attachType=1022 dataKeys=\(normalizedPayload.keys.sorted().joined(separator: ","), privacy: .public)")
            receiveProgress(payload: normalizedPayload)
            return true
        case .partyTaskReward:
            AppLogger.party.info("[PartyWeeklyTask] attachType=1023 dataKeys=\(normalizedPayload.keys.sorted().joined(separator: ","), privacy: .public)")
            receiveReward(payload: normalizedPayload)
            return true
        default:
            return false
        }
    }
}

struct PartyWeeklyTaskTopProgress: Equatable {
    let currentTime: Int
    let targetTime: Int
    let rewardText: String

    var fraction: Double {
        min(1, max(0, Double(currentTime) / Double(max(targetTime, 1))))
    }
}

/// 热门房任务只在服务端判定当前房进入 TopX 时激活。轮询生命周期绑定 Party 房，离房即取消。
@MainActor
final class PartyHotRoomTaskStore: ObservableObject {
    static let shared = PartyHotRoomTaskStore()

    @Published private(set) var status: PartyHotRoomTaskStatus?
    @Published private(set) var guide: PartyHotRoomGuide?
    private var roomId: String?
    private var pollingTask: Task<Void, Never>?
    private var requestedGuide = false

    var isActive: Bool { status?.isActive == true }
    var isTracking: Bool { roomId != nil }
    /// 请求未返回时先保留入口，成功确认非 TopX 后隐藏；避免字段兼容或短暂网络失败造成入口闪烁消失。
    var showsEntry: Bool { isTracking && (status == nil || status?.isTopRoom == true) }

    func beginTracking(roomId: String) {
        guard self.roomId != roomId else { return }
        stopTracking()
        self.roomId = roomId
        requestedGuide = false
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func stopTracking() {
        pollingTask?.cancel()
        pollingTask = nil
        roomId = nil
        status = nil
        guide = nil
        requestedGuide = false
    }

    func refresh() async {
        guard let roomId else { return }
        do {
            let newStatus = try await PartyAPI.hotRoomTaskStatus(roomId: roomId)
            guard self.roomId == roomId else { return }
            status = newStatus
            if newStatus.isTopRoom {
                guide = nil
                requestedGuide = false
            } else if newStatus.path == "top_room_guide", !requestedGuide {
                requestedGuide = true
                do {
                    guide = try await PartyAPI.hotRoomWithAvailableSeat()
                } catch {
                    // 本次拉取失败允许下一轮轮询重试；不能因一次网络抖动永久丢失引导。
                    requestedGuide = false
                    throw error
                }
            } else if newStatus.path != "top_room_guide" {
                guide = nil
                requestedGuide = false
            }
        } catch {
            // 保留上一次成功状态，临时网络失败不应导致入口闪烁消失。
            AppLogger.party.error("[PartyHotTask] check failed err=\(String(describing: error), privacy: .public)")
        }
    }

    func dismissGuide() {
        guide = nil
    }

    private init() {}
}
