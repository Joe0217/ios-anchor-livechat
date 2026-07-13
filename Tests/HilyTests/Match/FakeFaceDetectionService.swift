import Foundation

/// L 里程碑 Match 单测：FaceDetectionServiceProtocol Fake 实现。
///
/// 可编程 `stubbedHasFace`（默认 true），支持测试通话中人脸检测异常路径（P1）。
final class FakeFaceDetectionService: FaceDetectionServiceProtocol {
    var stubbedHasFace: Bool = true
    private(set) var callCount = 0

    func hasFace() -> Bool {
        callCount += 1
        return stubbedHasFace
    }
}
