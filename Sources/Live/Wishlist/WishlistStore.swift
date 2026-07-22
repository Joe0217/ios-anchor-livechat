import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "WishlistStore")

/// 心愿单 store（对齐 H5 wishlist 数据流）
@MainActor
final class WishlistStore: ObservableObject {
    @Published private(set) var items: [WishlistItem] = []
    @Published private(set) var topGifters: [WishlistTop6Item] = []

    /// 用户主播昵称（半屏面板标题用；由外部注入）
    @Published var anchorNickname: String = ""

    private let service: WishlistServiceProtocol
    private var anchorUserId: String = ""
    private var top6Timer: Timer?
    private var itemsTask: Task<Void, Never>?
    private var top6Task: Task<Void, Never>?
    private var requestGeneration = 0
    private var top6Generation = 0
    private var activeLiveRecordId: String?
    private var isPanelVisible = false
    /// IM 收礼事件可能快于 getAnchorWishlist 回包，甚至先于 `loadInitial`；按 giftId 暂存绝对完成数，回包后合并。
    private var pendingProgressByGiftId: [String: Int] = [:]
    /// 部分 50 消息未携带权威的 `compelteGiftNum`，但仍带本次礼物数量；先按增量暂存，等快照回来合并。
    private var pendingProgressDeltaByGiftId: [String: Int] = [:]
    /// 252/253 也可能先于心愿单接口回包到达。保留完成事件，避免首轮加载后又显示未完成。
    private var pendingWholePoolCompletion = false
    private var pendingCompletedGiftIds: Set<String> = []
    private var progressRecoveryTask: Task<Void, Never>?
    private var progressRecoveryAttempts = 0

    init(service: WishlistServiceProtocol = WishlistServiceReal()) {
        self.service = service
    }

    deinit {
        itemsTask?.cancel()
        top6Task?.cancel()
        progressRecoveryTask?.cancel()
    }

    /// H5 固定渲染 6 个槽位；接口返回不足 6 条时补空头像。
    var topSixSlots: [WishlistTop6Item] {
        (1...6).map { rank in
            topGifters.first(where: { $0.rank == rank }) ?? .emptySlot(at: rank)
        }
    }

    /// 进房初始化拉取
    func loadInitial(anchorUserId: String, anchorNickname: String) {
        // 同一直播间的首轮 IM 可能早于这里执行，必须保留其暂存进度。
        // 真正切换主播时清掉，避免把旧房间的事件套用到新房间。
        let isDifferentAnchor = !self.anchorUserId.isEmpty && self.anchorUserId != anchorUserId
        if isDifferentAnchor {
            pendingProgressByGiftId = [:]
            pendingProgressDeltaByGiftId = [:]
            pendingWholePoolCompletion = false
            pendingCompletedGiftIds = []
        }
        requestGeneration += 1
        top6Generation += 1
        itemsTask?.cancel()
        top6Task?.cancel()
        progressRecoveryTask?.cancel()
        progressRecoveryTask = nil
        progressRecoveryAttempts = 0
        onPanelDisappear()
        self.anchorUserId = anchorUserId
        self.anchorNickname = anchorNickname
        items = []
        topGifters = []
        guard !anchorUserId.isEmpty else { return }
        let generation = requestGeneration
        itemsTask = Task { [weak self] in
            await self?.loadItems(anchorUserId: anchorUserId, generation: generation)
        }
    }

    func reset() {
        requestGeneration += 1
        top6Generation += 1
        itemsTask?.cancel()
        top6Task?.cancel()
        progressRecoveryTask?.cancel()
        itemsTask = nil
        top6Task = nil
        progressRecoveryTask = nil
        onPanelDisappear()
        anchorUserId = ""
        anchorNickname = ""
        items = []
        topGifters = []
        pendingProgressByGiftId = [:]
        pendingProgressDeltaByGiftId = [:]
        pendingWholePoolCompletion = false
        pendingCompletedGiftIds = []
        progressRecoveryAttempts = 0
    }

    private func loadItems(anchorUserId: String, generation: Int) async {
        do {
            let loaded = try await service.fetchWishlist(anchorUserId: anchorUserId)
            try Task.checkCancellation()
            guard generation == requestGeneration, self.anchorUserId == anchorUserId else { return }
            // IM 事件若先到，不能被接口旧快照覆盖；与 H5 收礼时写 currentLiveInfo.wishlist 的结果一致。
            items = loaded.map { item in
                var merged = item
                if let completedCount = pendingProgressByGiftId[item.id] {
                    merged = merged.updatingCompletedCount(completedCount)
                }
                if let delta = pendingProgressDeltaByGiftId[item.id], delta > 0 {
                    merged = merged.updatingCompletedCount(merged.completedCount + delta)
                }
                if pendingWholePoolCompletion || pendingCompletedGiftIds.contains(item.id) {
                    merged = merged.markingCompleted()
                }
                return merged
            }
            // 只消费本次接口实际包含的项。若接口短暂返回空列表，保留 IM 事件等待下一次有效快照。
            let loadedIds = Set(loaded.map(\.id))
            pendingProgressByGiftId = pendingProgressByGiftId.filter { !loadedIds.contains($0.key) }
            pendingProgressDeltaByGiftId = pendingProgressDeltaByGiftId.filter { !loadedIds.contains($0.key) }
            if !loadedIds.isEmpty {
                pendingWholePoolCompletion = false
            }
            pendingCompletedGiftIds.subtract(loadedIds)
            if !loadedIds.isEmpty {
                progressRecoveryAttempts = 0
            } else if hasPendingProgress {
                scheduleProgressRecovery(anchorUserId: anchorUserId, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Wishlist load failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 半屏面板 onAppear 触发 Top6 拉取 + 启动 30s 轮询
    func onPanelAppear(liveRecordId: String) {
        // H5 `if (!info.id && !info.agoraLiveRoomId) return`；父层 roomId 尚未回填时会传 "0"。
        guard !liveRecordId.isEmpty, liveRecordId != "0", !anchorUserId.isEmpty else { return }
        isPanelVisible = true
        activeLiveRecordId = liveRecordId
        refreshTop6()
        startTop6Polling(liveRecordId: liveRecordId)
    }

    /// 半屏面板 onDisappear 停止轮询
    func onPanelDisappear() {
        top6Timer?.invalidate()
        top6Timer = nil
        isPanelVisible = false
        activeLiveRecordId = nil
        top6Generation += 1
        top6Task?.cancel()
        top6Task = nil
    }

    /// 收到心愿礼物时按 H5 `wishGiftTick` 的语义即时刷新贡献榜；面板关闭时不产生额外请求。
    func refreshTop6IfPanelVisible() {
        guard isPanelVisible else { return }
        refreshTop6()
    }

    private func refreshTop6() {
        guard let liveRecordId = activeLiveRecordId, !liveRecordId.isEmpty,
              !anchorUserId.isEmpty else { return }
        top6Generation += 1
        top6Task?.cancel()
        let generation = top6Generation
        let anchorId = anchorUserId
        top6Task = Task { [weak self] in
            await self?.loadTop6(
                liveRecordId: liveRecordId,
                anchorId: anchorId,
                generation: generation
            )
        }
    }

    private func loadTop6(liveRecordId: String, anchorId: String, generation: Int) async {
        do {
            let loaded = try await service.fetchTop6(liveRecordId: liveRecordId, anchorId: anchorId)
            try Task.checkCancellation()
            guard generation == top6Generation,
                  isPanelVisible,
                  activeLiveRecordId == liveRecordId,
                  anchorUserId == anchorId else { return }
            topGifters = loaded
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Top6 load failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func startTop6Polling(liveRecordId: String) {
        top6Timer?.invalidate()
        top6Timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTop6() }
        }
    }

    /// 收礼推进进度（对齐 H5 handleLiveGiftMessage 里 `compelteGiftNum` 的权威绝对值更新）。
    @discardableResult
    func updateProgress(giftId: String, completedCount: Int) -> Bool {
        applyGiftProgress(giftId: giftId, completedCount: completedCount, receivedCount: 0)
    }

    /// 处理 attachType 50 的心愿礼物进度。
    ///
    /// 正常消息以 `compelteGiftNum` 为权威绝对值；线上偶发缺失该字段时，使用本次 `giftNum`
    /// 作为增量，避免“收到了礼物但顶部卡和 sheet 都不动”。
    @discardableResult
    func applyGiftProgress(giftId: String, completedCount: Int?, receivedCount: Int) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == giftId }) else {
            // 已有列表但礼物不在其中时，普通礼物和 H5 `findIndex < 0` 一样直接忽略。
            // 但若服务端明确携带心愿单的绝对进度，说明本地快照可能落后，需要暂存后有限重拉。
            if !items.isEmpty, completedCount == nil { return false }
            // 心愿单接口尚未返回或短暂返回空列表时保留进度，等有效快照合并后顶部卡和 sheet 会一起更新。
            if let completedCount {
                pendingProgressByGiftId[giftId] = completedCount
                // 后到的绝对值已包含此前累计，不应再叠加旧增量。
                pendingProgressDeltaByGiftId.removeValue(forKey: giftId)
            } else {
                pendingProgressDeltaByGiftId[giftId, default: 0] += max(1, receivedCount)
            }
            scheduleProgressRecovery(anchorUserId: anchorUserId, generation: requestGeneration)
            refreshTop6IfPanelVisible()
            return false
        }
        let nextCompletedCount = completedCount
            ?? (items[idx].completedCount + max(1, receivedCount))
        items[idx] = items[idx].updatingCompletedCount(nextCompletedCount)
        pendingProgressByGiftId.removeValue(forKey: giftId)
        pendingProgressDeltaByGiftId.removeValue(forKey: giftId)
        refreshTop6IfPanelVisible()
        return true
    }

    private var hasPendingProgress: Bool {
        !pendingProgressByGiftId.isEmpty || !pendingProgressDeltaByGiftId.isEmpty
    }

    /// H5 会在聊天室登录后再拉一次 wishlist；iOS 首轮 API 偶发空快照时用有限重试补齐这个时序。
    private func scheduleProgressRecovery(anchorUserId: String, generation: Int) {
        guard !anchorUserId.isEmpty,
              progressRecoveryTask == nil,
              progressRecoveryAttempts < 2 else { return }
        progressRecoveryAttempts += 1
        progressRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  generation == self.requestGeneration,
                  anchorUserId == self.anchorUserId else { return }
            await self.loadItems(anchorUserId: anchorUserId, generation: generation)
            guard generation == self.requestGeneration else { return }
            self.progressRecoveryTask = nil
            if self.hasPendingProgress {
                self.scheduleProgressRecovery(anchorUserId: anchorUserId, generation: generation)
            }
        }
    }

    /// 252 标记全部礼物达成；253 仅在 giftId 缺失/null 时才与 H5 一样降级为全量达成。
    @discardableResult
    func markCompleted(wholePool: Bool, giftId: String?, hasGiftId: Bool) -> Bool {
        guard !items.isEmpty else {
            if wholePool || !hasGiftId {
                pendingWholePoolCompletion = true
            } else if let giftId {
                pendingCompletedGiftIds.insert(giftId)
            }
            return false
        }
        if !wholePool, hasGiftId {
            guard let giftId, let index = items.firstIndex(where: { $0.id == giftId }) else { return false }
            items[index] = items[index].markingCompleted()
            return true
        }
        items = items.map { $0.markingCompleted() }
        return true
    }
}
