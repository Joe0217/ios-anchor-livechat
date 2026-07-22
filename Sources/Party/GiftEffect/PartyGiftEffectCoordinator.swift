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
        let hasVisibleRecipient: Bool
    }

    private var priorityQueue: [PendingGift] = []
    private var normalQueue: [PendingGift] = []
    private var currentTask: Task<Void, Never>?
    private var luckyReceiverTask: Task<Void, Never>?

    private var floatingPending: [PartyGiftEffectItem] = []
    private var floatingDrainTask: Task<Void, Never>?
    private var generation = 0

    private static let queueLimit = 30
    private static let centralDuration: UInt64 = 1_500_000_000
    private static let receiverDuration: UInt64 = 1_500_000_000
    private static let floatingInterval: UInt64 = 300_000_000
    private static let floatingLimit = 3

    private init() {}

    func enqueue(
        _ item: PartyGiftEffectItem,
        myUserId: String?,
        visibleRecipientIds: Set<String>
    ) {
        enqueueFloating(item)

        // H5 的 SVGA/MP4 走全局 gift store；静态礼物才进入 Party 专属双队列。
        guard !item.hasPlayableAnimation, item.staticImageURL != nil else { return }

        if isLuckyGift(item) {
            playLuckyReceiver(item)
            return
        }

        let pending = PendingGift(
            item: item,
            hasVisibleRecipient: !visibleRecipientIds.isDisjoint(with: Set(item.receiverUserIds))
        )
        if let myUserId, item.receiverUserIds.contains(myUserId) {
            priorityQueue.append(pending)
            trim(&priorityQueue)
        } else {
            normalQueue.append(pending)
            trim(&normalQueue)
        }
        playNextIfIdle()
    }

    func reset() {
        generation &+= 1
        currentTask?.cancel()
        luckyReceiverTask?.cancel()
        floatingDrainTask?.cancel()

        currentTask = nil
        luckyReceiverTask = nil
        floatingDrainTask = nil
        priorityQueue.removeAll()
        normalQueue.removeAll()
        floatingPending.removeAll()
        centralGift = nil
        receiverGift = nil
        floatingMessages.removeAll()
    }

    private func playNextIfIdle() {
        guard currentTask == nil else { return }
        guard let next = dequeueNext() else { return }

        let token = generation
        centralGift = next.item
        currentTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.centralDuration)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.centralGift = nil

                if next.hasVisibleRecipient {
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
            self.playNextIfIdle()
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
