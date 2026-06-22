import CoreVideo
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "FUBeauty")

/// 美颜 setup 错误（B 里程碑 spec §6.1）。
enum BeautyError: Error, Equatable {
    case setupFailed
    case setupTimeout(elapsed: TimeInterval)
}

/// 相芯美颜处理器：实现 BeautyRenderer，把相机帧交给 FUManager(OC) 渲染。
/// init 改 throws：setup 失败或 >500ms 超时由 CameraManager 降级到 PassthroughRenderer（spec §6）。
final class FUBeautyRenderer: BeautyRenderer {
    init() throws {
        let start = Date()
        guard FUManager.shared().setupSync() else {
            logger.error("FaceUnity setupSync returned false; will fallback")
            throw BeautyError.setupFailed
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed > 0.5 {
            logger.warning("FaceUnity setup took \(elapsed)s (>500ms); fallback to passthrough")
            throw BeautyError.setupTimeout(elapsed: elapsed)
        }
    }

    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        FUManager.shared().renderPixelBuffer(pixelBuffer)
    }

    func updateParameters(_ params: BeautyParameters) {
        FUManager.shared().updateBlur(
            params.blur,
            whiten: params.whiten,
            eyeEnlarge: params.eyeEnlarge,
            faceThin: params.faceThin,
            enabled: params.enabled
        )
    }
}
