import CoreVideo

/// 美颜处理器抽象。
///
/// 设计要点：相机每帧输出 CVPixelBuffer 进来，返回处理后的 CVPixelBuffer。
/// 预览渲染只认 CVPixelBuffer，因此无论"直通"还是"相芯美颜"，下游路径完全一致。
///
/// - 老 API `updateParameters(_ params: BeautyParameters)`：B/C/D 里程碑 4 参数遗留
///   （现 5+ 处调用：CallView/CallPOCView/LivePrepareView/LiveRoomView/BeautyPanel）；
///   Step 2 接线时逐步迁移到 `apply(_:)`
/// - 新 API `apply(_ settings: BeautySettings)`：K 里程碑 §8.3 方案 A 全量应用
protocol BeautyRenderer: AnyObject {
    /// 处理单帧，返回处理后的像素缓冲（直通实现可原样返回）
    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer
    /// [legacy] 同步 4 参数（B/C/D 里程碑遗留）
    func updateParameters(_ params: BeautyParameters)
    /// [K spec §8.3 方案 A] 全量应用 25+ 参数 + 滤镜 + 开关 + 磨皮时序前置
    func apply(_ settings: BeautySettings)
}

extension BeautyRenderer {
    /// 默认空实现：PassthroughRenderer / 未升级的 renderer 用此兜底。
    /// FUBeautyRenderer 必须 override 走完全量写入路径。
    func apply(_ settings: BeautySettings) {
        // no-op；由具体 renderer 决定是否实现
    }
}
