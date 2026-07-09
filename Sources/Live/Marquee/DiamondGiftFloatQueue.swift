import Foundation

/// 钻石盲盒飘屏队列（对齐 H5 diamond-gift-float-screen.vue）
///
/// - 触发：attachType 1030-1033
/// - 队列：5s 出队一条（`diamondGiftFloatTimer`）
@MainActor
final class DiamondGiftFloatQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let senderNickname: String
        let giftCount: Int
        let totalDiamonds: Int64
    }

    @Published private(set) var current: Item?

    private var pending: [Item] = []
    private var isPlaying: Bool = false

    /// 单条动画时长（对齐 H5 5s translate 动画）
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
