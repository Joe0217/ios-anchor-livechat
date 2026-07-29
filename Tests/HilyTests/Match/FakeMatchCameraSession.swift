import Combine
import Foundation

/// L 里程碑 Match 单测：MatchCameraSessionProtocol Fake 实现。
///
/// 记录 start/stop 调用次数；可编程 isRunning 状态 + timedOut/error published 触发。
@MainActor
final class FakeMatchCameraSession: MatchCameraSessionProtocol {

    // MARK: - Protocol 属性

    var isRunning: Bool = false
    var interruptionUnrecoveredDuration: TimeInterval = 0
    var evidenceJPEGData: Data? = Data([0x00])

    // MARK: - 调用记录

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    // MARK: - Publishers（测试可通过 subject.send() 触发）

    let timedOutSubject = PassthroughSubject<Void, Never>()
    let errorSubject = PassthroughSubject<MatchCameraError, Never>()

    var timedOutPublisher: AnyPublisher<Void, Never> {
        timedOutSubject.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<MatchCameraError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - MatchCameraSessionProtocol

    func start() {
        startCallCount += 1
        isRunning = true
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }

    func latestFrameJPEGData() async -> Data? {
        evidenceJPEGData
    }
}
