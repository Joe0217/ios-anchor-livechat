import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LotteryStore")

/// 原生活动抽奖状态。中奖结果由 `userLottery` 同步返回，动画只负责展示，绝不轮询或重复提交。
@MainActor
final class LotteryStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case refreshing
        case ready
        case unsupportedPrizeLayout
        case failed(String)
        case submitting
        case spinning
        case reconciling
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var activity: LotteryActivity?
    @Published private(set) var winners: [LotteryRewardRecord] = []
    @Published private(set) var remainingTimes: Int = 0
    @Published private(set) var highlightedPrizeID: String?
    @Published private(set) var resultPrizes: [LotteryPrize] = []
    @Published var isResultPresented = false
    @Published private(set) var records: [LotteryRewardRecord] = []
    @Published private(set) var isLoadingRecords = false
    @Published private(set) var isRecordsFinished = false
    @Published private(set) var now = Date()
    @Published private(set) var insufficientEntry: LotteryDrawEntry = .one
    @Published private(set) var isInsufficientPresented = false
    @Published private(set) var roomNavigationTarget: LotteryRoomTarget?

    let route: LotteryRoute

    private let service: LotteryServicing
    private let canDrawLottery: @Sendable () -> Bool
    private var nextRecordPage = 1
    private var recordsRequestID = UUID()
    private var recordsTask: Task<Void, Never>?
    private var drawTask: Task<Void, Never>?
    private var winnersTask: Task<Void, Never>?
    private var drawRequestID: UUID?
    private var reloadRequestID = UUID()
    private var roomNavigationRequestID = UUID()
    private var clockTask: Task<Void, Never>?

    init(route: LotteryRoute,
         service: LotteryServicing = LotteryServiceReal(),
         canDrawLottery: @escaping @Sendable () -> Bool = LotteryStore.defaultCanDrawLottery) {
        self.route = route
        self.service = service
        self.canDrawLottery = canDrawLottery
    }

    deinit {
        recordsTask?.cancel()
        drawTask?.cancel()
        winnersTask?.cancel()
        clockTask?.cancel()
    }

    var title: String {
        let configured = activity?.info.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? L10n.Lottery.title : configured
    }

    var activityPhase: LotteryActivityPhase {
        activity?.info.phase(at: now) ?? .ended
    }

    var isBusy: Bool {
        switch state {
        case .loading, .refreshing, .submitting, .spinning, .reconciling:
            return true
        case .idle, .ready, .unsupportedPrizeLayout, .failed:
            return false
        }
    }

    var canDraw: Bool {
        guard case .ready = state,
              activity?.supportsNativeGrid == true,
              activityPhase == .active else {
            return false
        }
        return true
    }

    func loadIfNeeded() async {
        guard activity == nil, !isBusy else { return }
        state = .loading
        await reload()
    }

    func refresh() async {
        guard !isBusy else { return }
        state = activity == nil ? .loading : .refreshing
        await reload()
    }

    func startDraw(_ mode: LotteryDrawMode, entry: LotteryDrawEntry? = nil) {
        guard canDrawLottery() else {
            return
        }
        let safeEntry = entry ?? (mode == .five ? .five : .one)
        guard !isBusy else {
            AppToastCenter.shared.show(L10n.Lottery.pleaseWait)
            return
        }
        guard let activity, activity.supportsNativeGrid else {
            AppToastCenter.shared.show(L10n.Lottery.unsupportedPrizeLayout)
            return
        }
        switch activityPhase {
        case .notStarted:
            AppToastCenter.shared.show(L10n.Lottery.notStarted)
            return
        case .ended:
            AppToastCenter.shared.show(L10n.Lottery.ended)
            return
        case .active:
            break
        }
        guard remainingTimes >= mode.requiredTimes else {
            presentInsufficientPopup(entry: safeEntry)
            return
        }

        // 先在同一 MainActor turn 内加锁。网络请求一旦发出无法通过 cancel 撤回，不能把
        // "取消旧 Task" 当作抽奖去重手段。
        state = .submitting
        resultPrizes = []
        isResultPresented = false
        let requestID = UUID()
        drawRequestID = requestID
        drawTask = Task { [weak self] in
            await self?.performDraw(mode: mode, activity: activity, requestID: requestID)
        }
    }

    func dismissResult() {
        guard isResultPresented else { return }
        isResultPresented = false
        remainingTimes += resultPrizes.filter(\.grantsAnotherChance).count
        state = .ready
    }

    func dismissInsufficientPopup() {
        isInsufficientPresented = false
        roomNavigationTarget = nil
        // 使已经发出的 getRoomId 回包失效，防止关闭后仍发生跨 tab 跳转。
        roomNavigationRequestID = UUID()
    }

    /// H5 在点击跳转前先请求热门房。本页抽奖本体与 Party 入房状态无关；该请求只服务于
    /// 次数不足弹窗和常驻 More chances/Go 引导。Live 目标仅用返回值判断是否有可用直播，
    /// 再复用主播开播设置入口。
    func requestRoomID(for target: LotteryRoomTarget,
                       requiresInsufficientPopup: Bool = true) async -> String? {
        guard (!requiresInsufficientPopup || isInsufficientPresented),
              roomNavigationTarget == nil else {
            return nil
        }

        let requestID = UUID()
        roomNavigationRequestID = requestID
        roomNavigationTarget = target
        defer {
            if roomNavigationRequestID == requestID {
                roomNavigationTarget = nil
            }
        }

        do {
            let roomID = try await service.fetchRoomID(for: target)
            guard roomNavigationRequestID == requestID,
                  !Task.isCancelled,
                  (!requiresInsufficientPopup || isInsufficientPresented) else {
                return nil
            }
            guard let roomID, !roomID.isEmpty, roomID != "0" else {
                AppToastCenter.shared.show(
                    target == .party ? L10n.Lottery.noPartyRoomsAvailable : L10n.Lottery.noLiveAvailable
                )
                return nil
            }
            return roomID
        } catch is CancellationError {
            return nil
        } catch {
            guard roomNavigationRequestID == requestID else { return nil }
            logger.warning("Lottery room navigation failed: \(error.localizedDescription, privacy: .private)")
            AppToastCenter.shared.show((error as? APIError)?.message ?? L10n.Lottery.roomNavigationFailed)
            return nil
        }
    }

    func reloadRecords() async {
        // 记录页是只读请求，可以取消旧页；请求 ID 仍是最终防线，避免不响应取消的服务端回包
        // 把新一轮记录覆盖掉。
        recordsTask?.cancel()
        recordsRequestID = UUID()
        records = []
        nextRecordPage = 1
        isLoadingRecords = false
        isRecordsFinished = false
        await loadMoreRecords()
    }

    func loadMoreRecords() async {
        guard !isLoadingRecords, !isRecordsFinished else { return }
        let requestID = recordsRequestID
        let page = nextRecordPage
        isLoadingRecords = true
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performLoadMoreRecords(requestID: requestID, page: page)
        }
        recordsTask = task
        await task.value
        if recordsRequestID == requestID {
            recordsTask = nil
        }
    }

    private func performLoadMoreRecords(requestID: UUID, page: Int) async {
        defer {
            if recordsRequestID == requestID {
                isLoadingRecords = false
                recordsTask = nil
            }
        }

        do {
            let payload = try await service.fetchRecords(
                activityID: route.activityID,
                page: page,
                pageSize: 10
            )
            guard recordsRequestID == requestID else { return }
            records.append(contentsOf: payload.records)
            if let remaining = payload.remainingTimes {
                remainingTimes = max(0, remaining)
            }
            nextRecordPage = page + 1
            isRecordsFinished = payload.records.count < 10
        } catch is CancellationError {
            return
        } catch {
            guard recordsRequestID == requestID else { return }
            isRecordsFinished = true
            logger.warning("Lottery record load failed: \(error.localizedDescription, privacy: .private)")
            AppToastCenter.shared.show((error as? APIError)?.message ?? L10n.Lottery.recordsLoadFailed)
        }
    }

    // MARK: - Load

    private func reload() async {
        let requestID = UUID()
        reloadRequestID = requestID
        winnersTask?.cancel()
        winnersTask = nil
        do {
            let loadedActivity = try await service.fetchActivity(activityID: route.activityID)
            guard reloadRequestID == requestID, !Task.isCancelled else { return }
            // 活动详情决定页面可用性，不能等待跑马灯接口。H5 也是详情成功后立即挂载 Slider，
            // 跑马灯慢或失败都不应使整个抽奖页保持 loading。
            apply(activity: loadedActivity)
            winnersTask = Task { [weak self] in
                guard let self else { return }
                await self.loadWinners(requestID: requestID)
            }
        } catch is CancellationError {
            guard reloadRequestID == requestID else { return }
            restoreLoadedStateAfterCancelledReload()
            return
        } catch {
            guard reloadRequestID == requestID else { return }
            let message = (error as? APIError)?.message ?? L10n.Lottery.loadFailed
            if activity == nil {
                state = .failed(message)
            } else {
                restoreLoadedStateAfterCancelledReload()
            }
            logger.warning("Lottery activity load failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func loadWinners(requestID: UUID) async {
        defer {
            if reloadRequestID == requestID {
                winnersTask = nil
            }
        }

        do {
            let loadedWinners = try await service.fetchWinners(activityID: route.activityID)
            guard reloadRequestID == requestID, !Task.isCancelled else { return }
            winners = Array(loadedWinners.prefix(50))
        } catch is CancellationError {
            return
        } catch {
            guard reloadRequestID == requestID else { return }
            logger.warning("Lottery winners load failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func restoreLoadedStateAfterCancelledReload() {
        guard let activity else {
            state = .idle
            return
        }
        state = activity.supportsNativeGrid ? .ready : .unsupportedPrizeLayout
    }

    private func apply(activity: LotteryActivity) {
        self.activity = activity
        remainingTimes = max(0, activity.userTotalTimes)
        highlightedPrizeID = activity.prizes.first?.displayID
        resultPrizes = []
        startClock()
        state = activity.supportsNativeGrid ? .ready : .unsupportedPrizeLayout
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.now = Date()
            }
        }
    }

    // MARK: - Draw

    private func performDraw(mode: LotteryDrawMode,
                             activity: LotteryActivity,
                             requestID: UUID) async {
        defer {
            if drawRequestID == requestID {
                drawRequestID = nil
                drawTask = nil
            }
        }

        // deinit / page disappearance may cancel before this Task gets a chance to issue the
        // request. Once `userLottery` has started, this path never tries to replace it.
        guard drawRequestID == requestID, !Task.isCancelled else { return }
        do {
            let prizes = try await service.draw(
                activityID: route.activityID,
                mode: mode,
                sourceURL: route.sourceURL
            )
            try Task.checkCancellation()

            resultPrizes = prizes
            remainingTimes = max(0, remainingTimes - mode.requiredTimes)
            state = .spinning
            await animate(to: prizes.last?.id, in: activity.prizes)
            guard !Task.isCancelled else { return }
            isResultPresented = true
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Lottery draw failed: \(error.localizedDescription, privacy: .private)")
            // 请求超时后没有查询结果接口，不能自动重试。先重新拉详情校正剩余次数，
            // 用户明确下一次操作时才会再次提交抽奖。
            await reconcileAfterFailedDraw()
        }
    }

    private func animate(to resultID: String?, in prizes: [LotteryPrize]) async {
        let path = spinPath(for: prizes)
        guard !path.isEmpty,
              let resultID,
              let targetPosition = path.firstIndex(where: { prizes[$0].id == resultID }) else {
            // 服务端奖池刚更新或 ID 类型不一致时，仍展示同步返回的奖励，不能卡在转动状态。
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }

        var position = 0
        highlightedPrizeID = prizes[path[position]].displayID
        for _ in 0..<(path.count * 3) {
            guard !Task.isCancelled else { return }
            position = (position + 1) % path.count
            highlightedPrizeID = prizes[path[position]].displayID
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
        }

        let slowStart = (targetPosition - 3 + path.count) % path.count
        while position != slowStart {
            guard !Task.isCancelled else { return }
            position = (position + 1) % path.count
            highlightedPrizeID = prizes[path[position]].displayID
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
        }

        for duration in [500_000_000, 750_000_000, 1_000_000_000] {
            guard !Task.isCancelled else { return }
            position = (position + 1) % path.count
            highlightedPrizeID = prizes[path[position]].displayID
            do {
                try await Task.sleep(nanoseconds: UInt64(duration))
            } catch {
                return
            }
        }
    }

    private func reconcileAfterFailedDraw() async {
        state = .reconciling
        do {
            let refreshed = try await service.fetchActivity(activityID: route.activityID)
            guard !Task.isCancelled else { return }
            // 不覆盖跑马灯；它与本次未知结果无关，且入口加载已拿到最新前 50 条。
            apply(activity: refreshed)
            AppToastCenter.shared.show(L10n.Lottery.drawReconciled)
        } catch is CancellationError {
            return
        } catch {
            state = activity?.supportsNativeGrid == true ? .ready : .unsupportedPrizeLayout
            AppToastCenter.shared.show((error as? APIError)?.message ?? L10n.Lottery.drawFailed)
        }
    }

    private func spinPath(for prizes: [LotteryPrize]) -> [Int] {
        switch prizes.count {
        case 8:
            // 3x3：中心为抽奖按钮，外围按 H5 九宫格顺时针路径转动。
            return [0, 1, 2, 4, 7, 6, 5, 3]
        case 12:
            // 4x4：中间 2x2 为抽奖按钮，外围按 H5 十六宫格顺时针路径转动。
            return [0, 1, 2, 3, 5, 7, 11, 10, 9, 8, 6, 4]
        default:
            return []
        }
    }

    private func presentInsufficientPopup(entry: LotteryDrawEntry) {
        insufficientEntry = entry
        isInsufficientPresented = true
    }

    nonisolated private static func defaultCanDrawLottery() -> Bool {
        #if HILY_TESTS
        // HilyTests 独立编译，不链接 SessionStore / SelfPermissionBridge+Shared。
        return true
        #else
        return SelfPermissionBridge.shared.gate(.lottery, action: "nativeLotteryDraw")
        #endif
    }
}
