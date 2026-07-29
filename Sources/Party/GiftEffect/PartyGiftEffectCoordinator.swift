import Combine
import Foundation

/// 派对房静态送礼效果的串行协调器。
///
/// 对齐 H5 `gift-animator-manager.vue`：
/// - 收礼人包含自己时优先于其他静态礼物播放；
/// - 普通礼物先居中缩放 1.5 秒，再在每个仍在麦的收礼人位置缩放 1.5 秒；
/// - Lucky Gift 跳过中央阶段，直接触发麦位效果；
/// - 每条礼物同时进入独立飘屏，最多显示 3 条。
@MainActor
final class PartyGiftEffectCoordinator: ObservableObject {
    static let shared = PartyGiftEffectCoordinator()

    @Published private(set) var centralGift: PartyGiftEffectItem?
    @Published private(set) var receiverGift: PartyGiftEffectItem?
    @Published private(set) var floatingMessages: [PartyGiftEffectItem] = []

    private struct PendingGift {
        let item: PartyGiftEffectItem
        let isPriority: Bool
    }

    private var priorityQueue: [PendingGift] = []
    private var normalQueue: [PendingGift] = []
    /// 当前在麦用户。必须在中央动画结束时读取，避免播放期间下麦/上麦导致收礼动画落在旧麦位。
    private var visibleRecipientIds: Set<String> = []
    private var currentTask: Task<Void, Never>?
    /// 当前普通礼物。全局 Party SVGA/MP4 到达时，H5 会中断本动画并在全局动画结束后从头重播。
    private var currentPending: PendingGift?
    private var luckyReceiverTask: Task<Void, Never>?
    private var centerSubscription: AnyCancellable?
    private var isGlobalPartyAnimationPlaying = false

    private var floatingPending: [PartyGiftEffectItem] = []
    private var floatingDrainTask: Task<Void, Never>?
    private var generation = 0

    private static let queueLimit = 30
    private static let centralDuration: UInt64 = 1_500_000_000
    private static let receiverDuration: UInt64 = 1_500_000_000
    private static let floatingInterval: UInt64 = 300_000_000
    private static let floatingLimit = 3

    private init() {
        centerSubscription = GiftEffectCenter.shared.currentBridge.$current
            .sink { [weak self] current in
                guard let self else { return }
                let isPlaying = current?.sceneKey.scene == .party
                guard self.isGlobalPartyAnimationPlaying != isPlaying else { return }
                self.isGlobalPartyAnimationPlaying = isPlaying
                if isPlaying {
                    self.interruptNormalGiftForGlobalAnimation()
                } else {
                    self.playNextIfIdle()
                }
            }
    }

    func updateVisibleRecipientIds(_ ids: Set<String>) {
        visibleRecipientIds = ids
    }

    /// - Returns: 是否为 Lucky Gift。H5 会在判定 Lucky 后直接走麦位动画，
    ///   即使原始 giftIcon 是动态资源，也不能再进入全局礼物播放器。
    @discardableResult
    func enqueue(_ item: PartyGiftEffectItem, myUserId: String?) -> Bool {
        enqueueFloating(item)

        if isLuckyGift(item) {
            playLuckyReceiver(item)
            return true
        }

        // H5 的 SVGA/MP4 走全局 gift store；静态礼物才进入 Party 专属双队列。
        guard !item.hasPlayableAnimation, item.staticImageURL != nil else { return false }

        let isPriority = myUserId.map { item.receiverUserIds.contains($0) } ?? false
        let pending = PendingGift(item: item, isPriority: isPriority)
        if isPriority {
            priorityQueue.append(pending)
            trim(&priorityQueue)
        } else {
            normalQueue.append(pending)
            trim(&normalQueue)
        }
        playNextIfIdle()
        return false
    }

    func reset() {
        generation &+= 1
        currentTask?.cancel()
        luckyReceiverTask?.cancel()
        floatingDrainTask?.cancel()

        currentTask = nil
        currentPending = nil
        luckyReceiverTask = nil
        floatingDrainTask = nil
        priorityQueue.removeAll()
        normalQueue.removeAll()
        visibleRecipientIds = []
        floatingPending.removeAll()
        centralGift = nil
        receiverGift = nil
        floatingMessages.removeAll()
    }

    /// H5 `gift-animator-receiver` 在收礼动画显示期间不挂表情播放器；
    /// 避免两段 SVGA/图片在同一麦位抢占视觉层。表情队列本身不消费，收礼结束后继续播放。
    func isShowingReceiverGift(for userId: String) -> Bool {
        receiverGift?.receiverUserIds.contains(userId) == true
    }

    private func playNextIfIdle() {
        guard currentTask == nil else { return }
        // H5 `gift-animator-manager` only starts a normal gift when `!giftStore.isPlaying`.
        guard !isGlobalPartyAnimationPlaying else { return }
        guard let next = dequeueNext() else { return }

        let token = generation
        currentPending = next
        centralGift = next.item
        currentTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.centralDuration)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.centralGift = nil

                if !self.visibleRecipientIds.isDisjoint(with: Set(next.item.receiverUserIds)) {
                    self.receiverGift = next.item
                    try await Task.sleep(nanoseconds: Self.receiverDuration)
                    guard !Task.isCancelled, self.generation == token else { return }
                    if self.receiverGift?.id == next.item.id {
                        self.receiverGift = nil
                    }
                }
            } catch {
                return
            }

            guard let self, self.generation == token else { return }
            self.currentTask = nil
            self.currentPending = nil
            self.playNextIfIdle()
        }
    }

    /// H5 unmounts the normal animator while a Party SVGA/MP4 is playing. Return the
    /// interrupted gift to its original queue so it is replayed after the global animation.
    private func interruptNormalGiftForGlobalAnimation() {
        guard let pending = currentPending else { return }
        currentTask?.cancel()
        currentTask = nil
        currentPending = nil
        centralGift = nil
        receiverGift = nil
        if pending.isPriority {
            priorityQueue.insert(pending, at: 0)
        } else {
            normalQueue.insert(pending, at: 0)
        }
    }

    private func playLuckyReceiver(_ item: PartyGiftEffectItem) {
        luckyReceiverTask?.cancel()
        receiverGift = item
        let token = generation
        luckyReceiverTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.receiverDuration)
            } catch {
                return
            }
            guard let self, self.generation == token, self.receiverGift?.id == item.id else { return }
            self.receiverGift = nil
        }
    }

    private func dequeueNext() -> PendingGift? {
        if !priorityQueue.isEmpty { return priorityQueue.removeFirst() }
        if !normalQueue.isEmpty { return normalQueue.removeFirst() }
        return nil
    }

    private func trim(_ queue: inout [PendingGift]) {
        if queue.count > Self.queueLimit {
            queue.removeFirst(queue.count - Self.queueLimit)
        }
    }

    private func isLuckyGift(_ item: PartyGiftEffectItem) -> Bool {
        if item.isLuckyHint { return true }
        return GiftCatalogCache.shared.get(scene: .party)?.groups.contains { group in
            group.gifts.contains {
                $0.id == item.giftId && (group.tab == .luckyGift || $0.isLuckyGift)
            }
        } ?? false
    }

    // MARK: - Floating messages

    private func enqueueFloating(_ item: PartyGiftEffectItem) {
        floatingPending.append(item)
        guard floatingDrainTask == nil else { return }

        let token = generation
        floatingDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                guard !self.floatingPending.isEmpty else { break }

                let next = self.floatingPending.removeFirst()
                if self.floatingMessages.count >= Self.floatingLimit,
                   let oldest = self.floatingMessages.first {
                    self.dismissFloating(oldest.id)
                }
                self.floatingMessages.append(next)

                do {
                    try await Task.sleep(nanoseconds: Self.floatingInterval)
                } catch {
                    return
                }
            }

            guard let self, self.generation == token else { return }
            self.floatingDrainTask = nil
        }
    }

    /// H5 `floating-message-item` 在 CSS `animationend` 后通知 manager 移除自身。
    /// iOS 同样由行视图完成完整的 3 秒关键帧后回调，避免固定 timer 抢在最后淡出前移除。
    func finishFloatingAnimation(id: UUID) {
        dismissFloating(id)
    }

    private func dismissFloating(_ id: UUID) {
        floatingMessages.removeAll { $0.id == id }
    }
}
