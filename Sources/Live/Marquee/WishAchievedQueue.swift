import Foundation

/// 心愿达成飘屏队列（对齐 H5 attachType 252 整池完成 / 253 单礼物达成）
@MainActor
final class WishAchievedQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let giftName: String
        let giftIconUrl: String?
        /// 是否整池完成（252）vs 单礼物达成（253）
        let isWholePool: Bool
    }

    @Published private(set) var current: Item?
    private var pending: [Item] = []
    private var isPlaying: Bool = false

    /// 单条显示 3s（对齐 H5 飘屏时长）
    private let displayDuration: TimeInterval = 3.0

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
            try? await Task.sleep(nanoseconds: UInt64((self?.displayDuration ?? 3.0) * 1_000_000_000))
            guard let self else { return }
            self.current = nil
            self.isPlaying = false
            self.playNextIfIdle()
        }
    }
}
