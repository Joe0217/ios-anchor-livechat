import Foundation

/// 用户进场飘屏队列（对齐 H5 userEntranceFloat.vue 单条播放模型）
///
/// - 触发：attachType 80（虚拟道具进场）or activeTycoonEnter
/// - 队列：同时 1 条；H5 按身份决定停留 1.2 秒或 3 秒，前后各 0.6 秒动画
@MainActor
final class EnterRoomFloatQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let nickname: String
        let avatarUrl: String?
        let userLevel: Int
        let isVip: Bool
        let isActiveTycoon: Bool   // 大R 用金色底图（对齐 H5 live_userRR_bg.webp）
        let guardianLevel: Int     // 守护优先于大 R / 普通等级
    }

    @Published private(set) var current: Item?

    private var pending: [Item] = []
    private var isPlaying = false
    private var displayTask: Task<Void, Never>?
    private var generation = 0

    private let slideDuration: TimeInterval = 0.6

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
        isPlaying = false
    }

    private func playNextIfIdle() {
        guard !isPlaying, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        current = next
        isPlaying = true
        let expectedGeneration = generation
        let totalDuration = slideDuration * 2 + stayDuration(for: next)
        displayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(totalDuration * 1_000_000_000))
                guard let self,
                      self.generation == expectedGeneration,
                      self.current?.id == next.id else { return }
                self.current = nil
                self.isPlaying = false
                self.displayTask = nil
                self.playNextIfIdle()
            } catch {
                return
            }
        }
    }

    private func stayDuration(for item: Item) -> TimeInterval {
        item.guardianLevel > 0 || item.isActiveTycoon ? 3.0 : 1.2
    }
}
