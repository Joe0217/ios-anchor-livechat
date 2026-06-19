import CoreVideo

/// 美颜处理器抽象。
///
/// 设计要点：相机每帧输出 CVPixelBuffer 进来，返回处理后的 CVPixelBuffer。
/// 预览渲染只认 CVPixelBuffer，因此无论"直通"还是"相芯美颜"，下游路径完全一致。
/// 第二阶段拿到相芯 SDK 后，新增 FUBeautyRenderer 实现本协议即可，相机与预览代码零改动。
protocol BeautyRenderer: AnyObject {
    /// 处理单帧，返回处理后的像素缓冲（直通实现可原样返回）
    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer
    /// 同步最新美颜参数
    func updateParameters(_ params: BeautyParameters)
}
