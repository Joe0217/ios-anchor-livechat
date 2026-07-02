import CoreVideo
import Foundation

/// K spec §5.2 R7/R8-b/R10-b：BeautyRenderer Mock。
///
/// 记录 apply / updateParameters 调用，供 Sharer 广播路径断言。
/// `process(_:)` 返回入参，实际 CVPixelBuffer 内容不重要（Sharer 测试不涉及帧处理）。
final class MockBeautyRenderer: BeautyRenderer, @unchecked Sendable {
    /// 记录所有 apply 调用（按序）
    private(set) var applyCalls: [BeautySettings] = []
    /// 记录所有 legacy updateParameters 调用
    private(set) var updateCalls: [BeautyParameters] = []
    private(set) var processCallCount = 0
    /// 便于日志：给 mock 起个名字
    let label: String

    init(label: String = "mock") { self.label = label }

    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        processCallCount += 1
        return pixelBuffer
    }

    func updateParameters(_ params: BeautyParameters) {
        updateCalls.append(params)
    }

    func apply(_ settings: BeautySettings) {
        applyCalls.append(settings)
    }
}
