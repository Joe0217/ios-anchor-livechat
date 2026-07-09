import Foundation

/// 付费弹幕飘屏队列（对齐 H5 bullet-float-manager.vue 单条顺序播放）
///
/// **v9 简化**（Level B）：
/// - 单档 scope（不做 3 档紫/橙/粉底图切换）
/// - 无跑马灯长文本滚动（v9 用 lineLimit 1 简化）
/// - Dislike 按钮 tap no-op（H 里程碑接 API）
///
/// **动画 3 相位**（对齐 H5 `enter(0.5s) → stay(showDuration) → leave(0.5s)`）
@MainActor
final class PaidBulletQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let senderAvatarUrl: String?
        let senderNickname: String
        let content: String
        /// 停留时长（默认 3s）
        let stayDuration: TimeInterval
    }

    @Published private(set) var current: Item?

    private var pending: [Item] = []
    private var isPlaying: Bool = false
    private let queueLimit: Int = 50   // 对齐 H5 queue 上限
    private let enterDuration: TimeInterval = 0.5
    private let leaveDuration: TimeInterval = 0.5

    func addToQueue(_ item: Item) {
        guard pending.count < queueLimit else { return }   // 超上限丢弃
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
        isPlaying = true
        current = next
        Task { @MainActor [weak self] in
            guard let self else { return }
            let total = self.enterDuration + next.stayDuration + self.leaveDuration
            try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
            self.current = nil
            self.isPlaying = false
            self.playNextIfIdle()
        }
    }
}
