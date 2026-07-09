import Foundation

/// 用户进场飘屏队列（对齐 H5 userEntranceFloat.vue 单条播放模型）
///
/// - 触发：attachType 80（虚拟道具进场）or activeTycoonEnter
/// - 队列：同时 1 条，5s 自动出队
@MainActor
final class EnterRoomFloatQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let nickname: String
        let avatarUrl: String?
        let userLevel: Int
        let isVip: Bool
        let isActiveTycoon: Bool   // 大R 用金色底图（对齐 H5 live_userRR_bg.webp）
    }

    @Published private(set) var current: Item?

    private var pending: [Item] = []
    private var isPlaying: Bool = false

    /// 单条显示时长（H5 CSS fadeLeft 5s ease-in）
    private let displayDuration: TimeInterval = 5.0

    func addToQueue(_ item: Item) {
        pending.append(item)
        playNextIfIdle()
    }

    func clear() {
        pending.removeAll()
        current = nil
        isPlaying = false
    }

    private func playNextIfIdle() {
        guard !isPlaying, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        current = next
        isPlaying = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.displayDuration ?? 5.0) * 1_000_000_000))
            guard let self else { return }
            self.current = nil
            self.isPlaying = false
            self.playNextIfIdle()
        }
    }
}
