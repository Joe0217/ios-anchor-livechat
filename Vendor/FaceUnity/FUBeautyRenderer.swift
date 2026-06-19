import CoreVideo

/// 相芯美颜处理器：实现 BeautyRenderer，把相机帧交给 FUManager(OC) 渲染。
/// 接通后把 CameraManager 的 renderer 从 PassthroughRenderer 换成本类即可，相机/预览/推流代码零改动。
final class FUBeautyRenderer: BeautyRenderer {
    init() {
        FUManager.shared().setup()
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
