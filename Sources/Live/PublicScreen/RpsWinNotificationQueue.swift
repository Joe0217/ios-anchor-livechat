import Foundation

/// H5 `rpsNotifyQueue` 的主播端等价物：首条立即展示，其余每 10 秒出一条。
@MainActor
final class RpsWinNotificationQueue {
    private let interval: TimeInterval
    private let maximumPendingCount: Int
    private let onEmit: (PublicChatMessage) -> Void

    private var pending: [PublicChatMessage] = []
    private var lastEmissionAt: Date?
    private var emissionTask: Task<Void, Never>?

    init(interval: TimeInterval = 10,
         maximumPendingCount: Int = 20,
         onEmit: @escaping (PublicChatMessage) -> Void) {
        self.interval = interval
        self.maximumPendingCount = maximumPendingCount
        self.onEmit = onEmit
    }

    deinit {
        emissionTask?.cancel()
    }

    func enqueue(_ message: PublicChatMessage) {
        let now = Date()
        let elapsed = lastEmissionAt.map { now.timeIntervalSince($0) } ?? interval

        if pending.isEmpty, elapsed >= interval {
            emit(message, at: now)
            return
        }

        pending.append(message)
        if pending.count > maximumPendingCount {
            pending.removeFirst(pending.count - maximumPendingCount)
        }
        scheduleNextEmission()
    }

    func reset() {
        emissionTask?.cancel()
        emissionTask = nil
        pending.removeAll()
        lastEmissionAt = nil
    }

    private func scheduleNextEmission() {
        guard emissionTask == nil, !pending.isEmpty else { return }

        let elapsed = lastEmissionAt.map { Date().timeIntervalSince($0) } ?? interval
        let delay = max(0, interval - elapsed)
        emissionTask = Task { @MainActor [weak self] in
            guard delay > 0 else {
                self?.emitNext()
                return
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.emitNext()
        }
    }

    private func emitNext() {
        emissionTask = nil
        guard !pending.isEmpty else { return }
        emit(pending.removeFirst(), at: Date())
        scheduleNextEmission()
    }

    private func emit(_ message: PublicChatMessage, at date: Date) {
        onEmit(message)
        lastEmissionAt = date
    }
}
