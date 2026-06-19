import CoreVideo

/// 直通处理器：不做任何美颜，原样返回相机帧。
/// 第一阶段用它验证"相机采集 -> 预览"管线；第二阶段替换为 FUBeautyRenderer。
final class PassthroughRenderer: BeautyRenderer {
    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer { pixelBuffer }
    func updateParameters(_ params: BeautyParameters) {}
}
