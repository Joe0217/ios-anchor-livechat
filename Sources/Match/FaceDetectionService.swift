import Foundation

/// L 里程碑 #3d：人脸检测 protocol + stub 实现。
///
/// **本次范围**：Store 层调用 protocol 完成人脸检测轮询与 blocked 链路；真 SDK 集成留 J-合规里程碑。
/// 真实现应桥接相芯 `fuFaceProcessorGetNumResults()` C API（在 Vendor/FaceUnity/FURenderKit
/// 的 CNamaSDK.h 声明），OC 侧 FUManager 增加 `- (BOOL)hasFaceDetected` 方法，Swift 调用即可。
///
/// spec §10 BL-4：完整 J-合规集成 = 真 API 桥 + captureCanvasScreenshot + OSS 上传 + reportNoFace 接口。
protocol FaceDetectionServiceProtocol {
    /// 当前是否检测到人脸。真集成读 `fuFaceProcessorGetNumResults() > 0`；stub 默认 true。
    func hasFace() -> Bool
}

/// Stub 实现：本里程碑默认返 true（相当于不实际检测，等 J 里程碑真集成）
final class FaceDetectionServiceStub: FaceDetectionServiceProtocol {
    static let shared = FaceDetectionServiceStub()
    private init() {}
    func hasFace() -> Bool { true }
}
