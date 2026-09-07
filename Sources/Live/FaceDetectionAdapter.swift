import Foundation

struct FaceDetectionResult: Equatable, Sendable {
    let hasFace: Bool
    let detectedAt: TimeInterval
}

protocol FaceDetectionAdapter: AnyObject {
    var latestResult: FaceDetectionResult? { get }
    func publish(hasFace: Bool, at monotonicTime: TimeInterval)
    func invalidate()
}

/// 线程安全的最新结果容器；SDK 回调只写入这里，业务 tick 在主线程读取。
final class LatestFaceDetectionAdapter: FaceDetectionAdapter {
    private let lock = NSLock()
    private var result: FaceDetectionResult?
    var latestResult: FaceDetectionResult? { lock.withLock { result } }
    func publish(hasFace: Bool, at monotonicTime: TimeInterval) { lock.withLock { result = .init(hasFace: hasFace, detectedAt: monotonicTime) } }
    func invalidate() { lock.withLock { result = nil } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

