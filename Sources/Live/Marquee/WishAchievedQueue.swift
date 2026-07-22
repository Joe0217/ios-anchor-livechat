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
