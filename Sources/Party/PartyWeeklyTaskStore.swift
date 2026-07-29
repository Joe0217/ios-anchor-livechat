import Foundation
import UIKit
import Vision

/// Party 房 Weekly Task：宝石目标和礼物流水。入口仅由 room/enter 的 rewardQuantity 控制。
@MainActor
final class PartyWeeklyTaskStore: ObservableObject {
    static let shared = PartyWeeklyTaskStore()

    @Published private(set) var targetValue = 0
    @Published private(set) var currentProgress = 0
    @Published private(set) var giftHistory: [PartyGiftHistory] = []
    @Published private(set) var rewardQuantity = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasLoadError = false

    private let pageSize = 20
    private var trackedRoomId: String?
    private var nextOffset: Int64?
    private var requestSequence = 0

    var isTracking: Bool { trackedRoomId != nil }
    var showsEntry: Bool { isTracking && rewardQuantity > 0 }
    var hasMore: Bool { nextOffset != nil && !giftHistory.isEmpty }
    var progressFraction: Double {
        min(1, max(0, Double(currentProgress) / Double(max(targetValue, 1))))
    }

    private init() {}

    func beginTracking(roomId: String, rewardQuantity: Int) {
        guard trackedRoomId != roomId else {
            self.rewardQuantity = max(0, rewardQuantity)
            return
        }
        trackedRoomId = roomId
        self.rewardQuantity = max(0, rewardQuantity)
        targetValue = 0
        currentProgress = 0
        giftHistory = []
        nextOffset = nil
        hasLoadError = false
        requestSequence &+= 1
    }

    func stopTracking(roomId: String) {
        guard trackedRoomId == roomId else { return }
        trackedRoomId = nil
        nextOffset = nil
        requestSequence &+= 1
        isLoading = false
        isLoadingMore = false
        hasLoadError = false
    }

    func load(reset: Bool = true) async {
        guard trackedRoomId != nil else { return }
        if reset, isLoading { return }
        if !reset, (nextOffset == nil || isLoading || isLoadingMore) { return }
        let offset: Int64
        if reset {
            offset = 0
        } else if let nextOffset {
            offset = nextOffset
        } else {
            return
        }
        let sequence = { requestSequence &+= 1; return requestSequence }()
        if reset {
            isLoading = true
            hasLoadError = false
        } else {
            isLoadingMore = true
        }

        do {
            let page = try await PartyAPI.weeklyTaskInfo(pageSize: pageSize, offset: offset)
            guard sequence == requestSequence else { return }
            targetValue = page.targetValue
            currentProgress = page.currentProgress
            if reset {
                giftHistory = page.giftHistory
            } else {
                let seen = Set(giftHistory.map(\.id))
                giftHistory.append(contentsOf: page.giftHistory.filter { !seen.contains($0.id) })
            }
            // 后端未单独返回 cursor 时，最后一条 createTime 是 Android 的分页游标。
            nextOffset = page.giftHistory.count >= pageSize ? page.nextOffset : nil
            hasLoadError = false
        } catch {
            guard sequence == requestSequence else { return }
            hasLoadError = true
            AppLogger.party.error("[PartyWeeklyTask] load failed err=\(String(describing: error), privacy: .public)")
        }

        guard sequence == requestSequence else { return }
        isLoading = false
        isLoadingMore = false
    }
}

/// TopX 热门任务：麦时档位、任务引导和 1022/1023 实时通知。
@MainActor
final class PartyHotRoomTaskStore: ObservableObject, MessageRouter {
    static let shared = PartyHotRoomTaskStore()

    @Published private(set) var status: PartyHotRoomTaskStatus?
    @Published private(set) var guide: PartyHotRoomGuide?
    @Published private(set) var rewardEffect: PartyHotTaskRewardNotification?
    @Published var pendingReward: PartyHotTaskRewardNotification?
    @Published var shouldPresentMissionRules = false
    @Published var shouldPresentProgressGuide = false
    @Published private(set) var missionRuleImageURL: String?
    @Published private(set) var faceVerificationWarning: PartyHotTaskFaceWarning?
    @Published private(set) var topRankLimit = 3

    private var roomId: String?
    private var trackingStartedAt: TimeInterval?
    private var pollingTask: Task<Void, Never>?
    private var hasPresentedInitialGuide = false
    private var hasPresentedOutOfTopGuide = false
    private var enteredFromTopRoomGuide = false
    private var queuedRewards: [PartyHotTaskRewardNotification] = []
    private var rewardEffectTask: Task<Void, Never>?
    private var handledRewardDeliveryKeys: Set<String> = []
    private var isLoadingGuide = false
    private var faceCheckTask: Task<Void, Never>?
    /// 只保存轮询/1022/1023 的服务端累计麦时；绝不由客户端本地秒表伪造进度。
    private var accumulatedLiveValue = 0
    private var isLoadingMissionRules = false
    private var missionRuleRequestSequence = 0
    private var topRankConfigRequestSequence = 0
    private let guideDefaults = UserDefaults.standard

    var isTracking: Bool { roomId != nil }
    /// 仅在接口给出确定结果后显示：TopX 有档位展示进度，非 TopX 展示掉榜提示。
    /// TopX 但后台未配置档位时，安卓会隐藏该任务容器。
    var showsEntry: Bool {
        guard isTracking, let status else { return false }
        return !status.isTopRoom || status.isActive
    }
    var isOutOfTop: Bool { status?.isTopRoom == false }
    var isTopRoom: Bool { status?.isTopRoom == true }

    private init() {
        NIMService.shared.registerRouter(self)
    }

    func beginTracking(roomId: String, entryPath: PartyRoomEntryPath) {
        guard self.roomId != roomId else {
            // 小窗恢复会重新构造 PartyRoomView，但房间会话未离开；不能让默认路由来源抹掉
            // 已记录的热门房引导来源。
            enteredFromTopRoomGuide = enteredFromTopRoomGuide || entryPath == .topRoomGuide
            return
        }
        stopTracking()
        self.roomId = roomId
        enteredFromTopRoomGuide = entryPath == .topRoomGuide
        trackingStartedAt = Date().timeIntervalSince1970
        Task { [weak self] in
            await self?.loadTopRankLimit(for: roomId)
        }
        pollingTask = Task { [weak self] in
            var isInitial = true
            while !Task.isCancelled {
                if await self?.refresh(isInitial: isInitial) == true {
                    isInitial = false
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func stopTracking() {
        pollingTask?.cancel()
        pollingTask = nil
        roomId = nil
        trackingStartedAt = nil
        status = nil
        guide = nil
        isLoadingGuide = false
        hasPresentedInitialGuide = false
        hasPresentedOutOfTopGuide = false
        enteredFromTopRoomGuide = false
        handledRewardDeliveryKeys = []
        shouldPresentMissionRules = false
        rewardEffectTask?.cancel()
        rewardEffectTask = nil
        faceCheckTask?.cancel()
        faceCheckTask = nil
        accumulatedLiveValue = 0
        isLoadingMissionRules = false
        missionRuleRequestSequence &+= 1
        missionRuleImageURL = nil
        rewardEffect = nil
        pendingReward = nil
        shouldPresentProgressGuide = false
        faceVerificationWarning = nil
        queuedRewards = []
    }

    @discardableResult
    func refresh(isInitial: Bool = false) async -> Bool {
        guard let roomId else { return false }
        do {
            let newStatus = try await PartyAPI.hotRoomTaskStatus(roomId: roomId)
            guard self.roomId == roomId else { return false }
            let previousStatus = status
            let previousFaceErrorCount = previousStatus?.nowFaceErrorCount
            // Android 仅以 checkExistHot3、1022 与 1023 同步累计值。保留单调性只用于抵抗
            // 服务端消息乱序，不能以本地时钟补秒。
            let mergedLiveValue = max(accumulatedLiveValue, newStatus.liveValue)
            status = newStatus.updating(liveValue: mergedLiveValue)
            accumulatedLiveValue = mergedLiveValue
            // 重新进入 TOPx 后，下一次掉榜应再次给出迁移引导。
            if newStatus.isTopRoom {
                hasPresentedOutOfTopGuide = false
            }
            if let previousFaceErrorCount, newStatus.nowFaceErrorCount > previousFaceErrorCount {
                faceVerificationWarning = newStatus.nowFaceErrorCount > newStatus.screenFaceLimit
                    ? .limitReached(newStatus.nowFaceErrorCount)
                    : .warning(newStatus.nowFaceErrorCount)
            }
            AppLogger.party.info("[PartyHotTask] status existHot=\(newStatus.existHot, privacy: .public) tiers=\(newStatus.anchorTasks.count, privacy: .public)")
            if newStatus.isActive, isInitial, !hasPresentedInitialGuide {
                hasPresentedInitialGuide = true
                if shouldPresentProgressGuideNow {
                    guideDefaults.set(Date().timeIntervalSince1970, forKey: Self.progressGuideShownKey)
                    shouldPresentProgressGuide = true
                } else {
                    await loadMissionRules()
                    guard self.roomId == roomId, self.status?.isActive == true else { return false }
                    shouldPresentMissionRules = true
                }
            }
            if enteredFromTopRoomGuide,
               isInitial,
               !newStatus.isTopRoom {
                await requestTopRoomGuide()
            }
            updateFaceCheckTask()
            return true
        } catch {
            AppLogger.party.error("[PartyHotTask] check failed err=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    func dismissGuide() { guide = nil }
    func dismissMissionRules() { shouldPresentMissionRules = false }
    func dismissProgressGuide() { shouldPresentProgressGuide = false }
    func dismissFaceVerificationWarning() { faceVerificationWarning = nil }

    private static let progressGuideShownKey = "party.hotTask.progressGuideShownAt"
    private var shouldPresentProgressGuideNow: Bool {
        let last = guideDefaults.double(forKey: Self.progressGuideShownKey)
        return last == 0 || Date().timeIntervalSince1970 - last > 24 * 60 * 60
    }

    private func updateFaceCheckTask() {
        // 只有已上视频麦且摄像头有效开启时才开始 60 秒周期；这样主播刚上麦不会沿用离麦期间的剩余等待时间。
        guard isEligibleForHotTaskTiming else {
            faceCheckTask?.cancel()
            faceCheckTask = nil
            return
        }
        guard faceCheckTask == nil else { return }
        faceCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.isEligibleForHotTaskTiming else {
                    self.updateFaceCheckTask()
                    return
                }
                await self.checkFaceAndReportIfNeeded()
            }
        }
    }

    private var isEligibleForHotTaskTiming: Bool {
        isFaceVerificationAllowed && PartyStore.shared.isEligibleForHotTaskTiming
    }

    /// 安卓仅在热门任务未完成且违规数未超过服务端阈值时截图和上报。
    private var isFaceVerificationAllowed: Bool {
        guard let status, status.isActive else { return false }
        return !status.isCompleted && status.nowFaceErrorCount <= status.screenFaceLimit
    }

    /// 麦时由服务端推送；这里仅做人脸检测。检测失败时才上传图片并调用违规上报接口。
    private func checkFaceAndReportIfNeeded() async {
        guard let snapshot = await PartyStore.shared.hotTaskFaceSnapshot(),
              self.roomId == snapshot.roomId else { return }
        let result = await Task.detached(priority: .utility) {
            PartyHotTaskFaceDetector.detect(in: snapshot.imageData)
        }.value
        guard result == .noFace else {
            if result == .unavailable {
                AppLogger.party.notice("[PartyHotTask] face check skipped: frame could not be analyzed")
            }
            return
        }
        do {
            let url = try await ImageUploader.shared.upload(rawData: snapshot.imageData, preset: .feedback)
            guard self.roomId == snapshot.roomId, self.isFaceVerificationAllowed else { return }
            try await PartyAPI.reportHotRoomTask(
                roomId: snapshot.roomId,
                content: url,
                seatIndex: snapshot.seatIndex
            )
            AppLogger.party.info("[PartyHotTask] face report sent seatIndex=\(snapshot.seatIndex, privacy: .public)")
            _ = await refresh()
        } catch {
            AppLogger.party.error("[PartyHotTask] face report failed err=\(String(describing: error), privacy: .private)")
        }
    }

    /// 麦位、摄像头或任务完成状态改变时立即重新评估，不等待下一次 60 秒轮询。
    func reevaluateFaceCheck() {
        updateFaceCheckTask()
    }

    func loadMissionRules() async {
        guard let requestedRoomId = roomId, !isLoadingMissionRules else { return }
        isLoadingMissionRules = true
        let requestSequence = { missionRuleRequestSequence &+= 1; return missionRuleRequestSequence }()
        defer {
            if requestSequence == missionRuleRequestSequence {
                isLoadingMissionRules = false
            }
        }
        do {
            let imageURL = try await PartyAPI.hotRoomTaskRuleImageURL()
            guard roomId == requestedRoomId, requestSequence == missionRuleRequestSequence else { return }
            missionRuleImageURL = imageURL
        } catch {
            guard roomId == requestedRoomId, requestSequence == missionRuleRequestSequence else { return }
            AppLogger.party.error("[PartyHotTask] rule config failed err=\(String(describing: error), privacy: .public)")
        }
    }

    private func loadTopRankLimit(for requestedRoomId: String) async {
        let requestSequence = { topRankConfigRequestSequence &+= 1; return topRankConfigRequestSequence }()
        do {
            let config = try await AppConfigService.fetch(keys: ["anchor_subsidy_top_x"])
            guard roomId == requestedRoomId, requestSequence == topRankConfigRequestSequence else { return }
            let value: Int?
            if let intValue = config["anchor_subsidy_top_x"] as? Int {
                value = intValue
            } else if let stringValue = config["anchor_subsidy_top_x"] as? String {
                value = Int(stringValue)
            } else if let numberValue = config["anchor_subsidy_top_x"] as? NSNumber {
                value = numberValue.intValue
            } else {
                value = nil
            }
            if let value, (1...99).contains(value) {
                topRankLimit = value
            }
        } catch {
            AppLogger.party.notice("[PartyHotTask] top rank config unavailable; using Top \(self.topRankLimit, privacy: .public)")
        }
    }

    /// 仅由列表热门房引导进入的主播，掉出 TOPx 后才请求新的目标房。
    private func requestTopRoomGuide() async {
        guard let roomId, !isLoadingGuide, guide == nil else { return }
        guard enteredFromTopRoomGuide,
              status?.isTopRoom == false,
              !hasPresentedOutOfTopGuide else { return }
        isLoadingGuide = true
        defer { isLoadingGuide = false }
        do {
            let target = try await PartyAPI.hotRoomWithAvailableSeat()
            guard self.roomId == roomId, let target else { return }
            // 当前房就是服务端返回的首选 Top 房时不弹；本次掉榜已处理，避免轮询反复请求。
            hasPresentedOutOfTopGuide = true
            guard target.roomId != roomId else { return }
            guide = target
        } catch {
            AppLogger.party.error("[PartyHotTask] available seat check failed err=\(String(describing: error), privacy: .public)")
        }
    }

    func dismissReward(_ id: UUID) {
        guard pendingReward?.id == id else { return }
        pendingReward = nil
        presentNextRewardIfPossible()
    }

    private func receiveProgress(_ payload: [String: Any]) {
        guard isForTrackedRoom(payload),
              let liveTime = PartyWeeklyTaskPage.firstInt(
                in: payload,
                keys: ["liveValue", "liveTime", "accumulatedDuration"]
              )
        else { return }
        applyProgress(liveTime)
    }

    private func receiveReward(_ payload: [String: Any]) {
        guard isForTrackedRoom(payload), let reward = PartyHotTaskRewardNotification(payload: payload) else { return }
        guard handledRewardDeliveryKeys.insert(rewardDeliveryKey(for: payload, reward: reward)).inserted else {
            return
        }
        applyProgress(reward.liveTime)
        queuedRewards.append(reward)
        presentNextRewardIfPossible()
    }

    /// 轮询、1022 与 1023 都必须单调推进。服务端回包/通知到达顺序不保证，
    /// 不能让较旧的值回退 UI 的进度条和倒计时。
    private func applyProgress(_ value: Int) {
        let mergedLiveValue = max(accumulatedLiveValue, value)
        accumulatedLiveValue = mergedLiveValue
        if let status {
            self.status = status.updating(liveValue: mergedLiveValue)
        }
        updateFaceCheckTask()
    }

    private func presentNextRewardIfPossible() {
        guard rewardEffect == nil, pendingReward == nil, !queuedRewards.isEmpty else { return }
        let reward = queuedRewards.removeFirst()
        rewardEffect = reward
        rewardEffectTask?.cancel()
        rewardEffectTask = Task { [weak self, reward] in
            // SVGA 由播放器完成回调推进；这里仅作网络/资源异常时的超时兜底。
            let fallbackDuration: UInt64 = reward.hasSVGAEffect ? 7_000_000_000 : 1_350_000_000
            try? await Task.sleep(nanoseconds: fallbackDuration)
            guard !Task.isCancelled else { return }
            self?.completeRewardEffect(reward.id)
        }
    }

    func completeRewardEffect(_ id: UUID) {
        guard let reward = rewardEffect, reward.id == id else { return }
        rewardEffectTask?.cancel()
        rewardEffectTask = nil
        rewardEffect = nil
        pendingReward = reward
    }

    private func isForTrackedRoom(_ payload: [String: Any]) -> Bool {
        guard let roomId else { return false }
        if let payloadRoomId = PartyWeeklyTaskPage.firstString(in: payload, keys: ["roomId", "partyRoomId"]) {
            return payloadRoomId == roomId
        }

        // CustomSystemNotification 可能没有 roomId。此时仅在 NIM 投递时间明确晚于当前
        // 房间会话开始时才接收，不能把无归属信息的延迟通知错误归入当前房间。
        guard let trackingStartedAt,
              let rawTimestamp = PartyWeeklyTaskPage.firstInt64(
                in: payload,
                keys: ["_nimCustomNotificationTimestamp"]
              )
        else {
            return false
        }
        return normalizedNotificationTimestamp(rawTimestamp) >= trackingStartedAt - 5
    }

    /// NIM 的 CustomSystemNotification 时间戳为毫秒；兼容已经被上游归一化为秒的测试 payload。
    private func normalizedNotificationTimestamp(_ timestamp: Int64) -> TimeInterval {
        let seconds = timestamp > 10_000_000_000 ? Double(timestamp) / 1_000 : Double(timestamp)
        return TimeInterval(seconds)
    }

    /// 系统通知正常带 NIM ID。少数兼容包缺失 ID 时，以房间、投递时间和奖励内容构造稳定键，
    /// 只压制重投，保留不同麦时档位的独立奖励。
    private func rewardDeliveryKey(
        for payload: [String: Any],
        reward: PartyHotTaskRewardNotification
    ) -> String {
        if let notificationId = PartyWeeklyTaskPage.firstString(
            in: payload,
            keys: ["_nimCustomNotificationId"]
        ) {
            return "nim:\(notificationId)"
        }
        let roomScope = PartyWeeklyTaskPage.firstString(in: payload, keys: ["roomId", "partyRoomId"])
            ?? roomId
            ?? ""
        let timestamp = PartyWeeklyTaskPage.firstInt64(
            in: payload,
            keys: ["_nimCustomNotificationTimestamp"]
        ).map(String.init) ?? ""
        let rewards = reward.rewards.map(\.id).joined(separator: "|")
        return "fallback:\(roomScope):\(timestamp):\(reward.liveTime):\(rewards)"
    }

    func route(_ attachType: AttachType, payload: [String: Any], context: MessageContext) -> Bool {
        switch context {
        case .sysMsg, .syncSysMsg:
            break
        default:
            return false
        }
        var normalized = PartyWeeklyTaskPage.unwrappedPayload(from: payload)
        // `data`/`result` 包装会把房间归属与 SDK 附加的去重、时间字段留在外层；转发前补回，
        // 否则奖励去重与跨房迟到消息过滤都会失效。
        for key in ["roomId", "partyRoomId", "_nimCustomNotificationId", "_nimCustomNotificationTimestamp"] {
            if normalized[key] == nil, let value = payload[key] {
                normalized[key] = value
            }
        }
        switch attachType {
        case .partyTaskProgress:
            AppLogger.party.info("[PartyHotTask] 1022 keys=\(normalized.keys.sorted().joined(separator: ","), privacy: .public)")
            receiveProgress(normalized)
            return true
        case .partyTaskReward:
            AppLogger.party.info("[PartyHotTask] 1023 keys=\(normalized.keys.sorted().joined(separator: ","), privacy: .public)")
            receiveReward(normalized)
            return true
        default:
            return false
        }
    }
}

/// Party 列表的「开启视频获得更多奖励」引导。
/// API 未返回可用目标或请求失败时静默跳过，避免以 loading/error 状态打断大厅浏览。
@MainActor
final class PartyTopRoomGuideStore: ObservableObject {
    @Published private(set) var guide: PartyHotRoomGuide?
    @Published private(set) var topRankLimit = 3

    private static let shownAtDefaultsKey = "party.topRoomGuide.shownAt"
    private let defaults: UserDefaults
    private var isLoading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadIfEligible() async {
        guard !isLoading, guide == nil, !hasShownToday else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            guard let target = try await PartyAPI.hotRoomWithAvailableSeat() else { return }
            guard !Task.isCancelled else { return }
            await loadTopRankLimit()
            guard !Task.isCancelled else { return }

            // Android 在成功获取目标后、显示弹窗前写入当天标记；关闭不重弹。
            defaults.set(Date().timeIntervalSince1970, forKey: Self.shownAtDefaultsKey)
            guide = target
            AnalyticsTracker.track(
                "h_party_top3_popup_show",
                properties: ["hasAvailableSeat": target.hasSeat]
            )
        } catch {
            AppLogger.party.error("[PartyTopRoomGuide] available seat check failed err=\(String(describing: error), privacy: .public)")
        }
    }

    func dismiss() {
        guide = nil
    }

    func confirmEnter(_ target: PartyHotRoomGuide) {
        AnalyticsTracker.track(
            "h_party_top3_popup_click",
            properties: [
                "targetRoomId": target.roomId,
                "targetRoomRank": target.rank ?? 0,
                "hasSeat": target.hasSeat
            ]
        )
        guide = nil
    }

    private var hasShownToday: Bool {
        let timestamp = defaults.double(forKey: Self.shownAtDefaultsKey)
        guard timestamp > 0 else { return false }
        return partyDay(for: Date(timeIntervalSince1970: timestamp)) == partyDay(for: Date())
    }

    private func partyDay(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.startOfDay(for: date)
    }

    private func loadTopRankLimit() async {
        do {
            let config = try await AppConfigService.fetch(keys: ["anchor_subsidy_top_x"])
            let value: Int?
            if let intValue = config["anchor_subsidy_top_x"] as? Int {
                value = intValue
            } else if let stringValue = config["anchor_subsidy_top_x"] as? String {
                value = Int(stringValue)
            } else if let numberValue = config["anchor_subsidy_top_x"] as? NSNumber {
                value = numberValue.intValue
            } else {
                value = nil
            }
            if let value, (1...99).contains(value) {
                topRankLimit = value
            }
        } catch {
            AppLogger.party.notice("[PartyTopRoomGuide] top rank config unavailable; using Top \(self.topRankLimit, privacy: .public)")
        }
    }
}

enum PartyHotTaskFaceWarning: Identifiable, Sendable {
    case warning(Int)
    case limitReached(Int)

    var id: String {
        switch self {
        case .warning(let count): return "warning-\(count)"
        case .limitReached(let count): return "limit-\(count)"
        }
    }

    var hasReachedLimit: Bool {
        if case .limitReached = self { return true }
        return false
    }
}

private enum PartyHotTaskFaceDetection: Sendable {
    case face
    case noFace
    case unavailable
}

private enum PartyHotTaskFaceDetector {
    static func detect(in imageData: Data) -> PartyHotTaskFaceDetection {
        autoreleasepool {
            guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
                return .unavailable
            }
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                return (request.results ?? []).isEmpty ? .noFace : .face
            } catch {
                return .unavailable
            }
        }
    }
}
