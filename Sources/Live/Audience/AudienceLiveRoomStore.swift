import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "AudienceLiveRoom")

/// 客态房间状态只管理入房接口与业务状态，不承载主播 LiveStore 的心跳、相机或下播副作用。
@MainActor
final class AudienceLiveRoomStore: ObservableObject {
    @Published private(set) var state: AudienceLiveRoomState = .idle

    private let service: AudienceLiveRoomServiceProtocol
    private var joinTask: Task<Void, Never>?
    private var joinGeneration = 0

    init(service: AudienceLiveRoomServiceProtocol = AudienceLiveRoomService()) {
        self.service = service
    }

    deinit { joinTask?.cancel() }

    func join(anchor: LiveStreamAnchor) async {
        guard state == .idle || isRetryable else { return }
        joinTask?.cancel()
        joinGeneration &+= 1
        let generation = joinGeneration
        state = .joining

        let task = Task { @MainActor [weak self, service] in
            do {
                let room = try await service.join(anchor: anchor)
                guard let self, !Task.isCancelled, generation == self.joinGeneration else { return }
                switch room.availability {
                case .live: self.state = .live(room)
                case .calling: self.state = .calling(room)
                case .ended: self.state = .ended
                }
            } catch is CancellationError {
                return
            } catch let error as APIError {
                guard let self, generation == self.joinGeneration else { return }
                logger.error("audience join API failed code=\(error.code, privacy: .public)")
                self.state = .failed(error.message)
            } catch {
                guard let self, generation == self.joinGeneration else { return }
                logger.error("audience join failed: \(String(describing: error), privacy: .private)")
                self.state = .failed(L10n.liveRoomStatusFailed)
            }
        }
        joinTask = task
        await task.value
        if generation == joinGeneration { joinTask = nil }
    }

    func retry(anchor: LiveStreamAnchor) async {
        state = .idle
        await join(anchor: anchor)
    }

    func cancel() {
        joinGeneration &+= 1
        joinTask?.cancel()
        joinTask = nil
    }

    func markEnded() {
        joinGeneration &+= 1
        joinTask?.cancel()
        joinTask = nil
        state = .ended
    }

    func markFailed(_ message: String) {
        joinGeneration &+= 1
        joinTask?.cancel()
        joinTask = nil
        state = .failed(message)
    }

    private var isRetryable: Bool {
        if case .failed = state { return true }
        return false
    }
}
