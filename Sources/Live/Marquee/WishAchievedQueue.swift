import Foundation

/// 心愿达成横幅状态（对齐 H5 `wishlist-complete-float.vue`）。
///
/// H5 对连续 252/253 的处理不是排队，而是重新播放 6 秒动画；这里保持相同语义，
/// 新事件会取消旧计时并用新 id 重建视图。
@MainActor
final class WishAchievedQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
    }

    @Published private(set) var current: Item?
    private var visibilityTask: Task<Void, Never>?

    private let displayDuration: UInt64 = 6_000_000_000

    func show() {
        visibilityTask?.cancel()
        current = nil
        let item = Item()
        visibilityTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.current = item
            do {
                try await Task.sleep(nanoseconds: self.displayDuration)
            } catch {
                return
            }
            guard !Task.isCancelled, self.current?.id == item.id else { return }
            self.current = nil
        }
    }

    func clear() {
        visibilityTask?.cancel()
        visibilityTask = nil
        current = nil
    }
}

/// 首礼时刻顶部飘屏队列（H5 `firstGiftFloatList`）。
///
/// 单条展示 5 秒，连续消息之间留出 800ms，让 SwiftUI 能重新挂载并重播入场动画。
@MainActor
final class FirstGiftFloatQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let backgroundURL: String?
        let renderedText: String
        let nickname: String
        let giftImageURL: String?
        let giftSmallImageURL: String?
        let styleKey: String
        let isFirstGift: Bool
    }

    @Published private(set) var current: Item?

    private var pending: [Item] = []
    private var displayTask: Task<Void, Never>?
    private var generation = 0

    func addToQueue(_ item: Item) {
        pending.append(item)
        playNextIfIdle()
    }

    func clear() {
        generation &+= 1
        displayTask?.cancel()
        displayTask = nil
        pending.removeAll()
        current = nil
    }

    private func playNextIfIdle() {
        guard current == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        current = next
        let expectedGeneration = generation

        displayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self,
                      self.generation == expectedGeneration,
                      self.current?.id == next.id else { return }
                self.current = nil
                try await Task.sleep(nanoseconds: 800_000_000)
                guard self.generation == expectedGeneration else { return }
                self.displayTask = nil
                self.playNextIfIdle()
            } catch {
                return
            }
        }
    }
}

/// 守护开通/续费广播队列（attachType 146）。
/// 只接受当前直播间主播的广播，过滤在 NIM 层完成。
@MainActor
final class GuardianBroadcastQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let levelCode: Int
        let nickname: String
        let anchorNickname: String
        let avatarURL: String?
    }

    @Published private(set) var current: Item?
    /// 每条 146 广播都递增，即使已有横幅在展示，直播顶部人数也能立即重拉。
    @Published private(set) var enqueueRevision = 0

    private var pending: [Item] = []
    private var displayTask: Task<Void, Never>?
    private var generation = 0

    func addToQueue(_ item: Item) {
        enqueueRevision &+= 1
        pending.append(item)
        playNextIfIdle()
    }

    func clear() {
        generation &+= 1
        displayTask?.cancel()
        displayTask = nil
        pending.removeAll()
        current = nil
    }

    private func playNextIfIdle() {
        guard current == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        current = next
        let expectedGeneration = generation

        displayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self,
                      self.generation == expectedGeneration,
                      self.current?.id == next.id else { return }
                self.current = nil
                self.displayTask = nil
                self.playNextIfIdle()
            } catch {
                return
            }
        }
    }
}

/// 幸运礼物中奖全服公告队列（H5 `g-fullServiceNotice.vue`）。
@MainActor
final class LuckyGiftNoticeQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let senderNickname: String
        let senderAvatarURL: String?
        let reward: Int64
        let receiverNickname: String
        let receiverAvatarURL: String?
        let backgroundURL: String
    }

    @Published private(set) var current: Item?

    private var pending: [Item] = []
    private var displayTask: Task<Void, Never>?
    private var generation = 0

    func addToQueue(_ item: Item) {
        pending.append(item)
        playNextIfIdle()
    }

    func clear() {
        generation &+= 1
        displayTask?.cancel()
        displayTask = nil
        pending.removeAll()
        current = nil
    }

    private func playNextIfIdle() {
        guard current == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        current = next
        let expectedGeneration = generation
        displayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 7_000_000_000)
                guard let self,
                      self.generation == expectedGeneration,
                      self.current?.id == next.id else { return }
                self.current = nil
                self.displayTask = nil
                self.playNextIfIdle()
            } catch {
                return
            }
        }
    }
}

/// 直播收礼浮窗（H5 `liveRoomFloatTips.vue`）。
/// 新礼物立即取代当前内容并重置 5 秒倒计时，不积压队列。
@MainActor
final class LiveGiftFloatQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let senderNickname: String
        let senderAvatarURL: String?
        let receiverNickname: String
        let giftImageURL: String?
        let giftCount: Int
    }

    @Published private(set) var current: Item?
    private var visibilityTask: Task<Void, Never>?

    func show(_ item: Item) {
        visibilityTask?.cancel()
        current = nil
        visibilityTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.current = item
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, self.current?.id == item.id else { return }
            self.current = nil
            self.visibilityTask = nil
        }
    }

    func clear() {
        visibilityTask?.cancel()
        visibilityTask = nil
        current = nil
    }
}
