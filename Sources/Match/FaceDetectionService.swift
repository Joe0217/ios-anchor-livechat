import Foundation

/// 匹配场景的人脸检测抽象。生产实现读取相芯最近一帧 FaceProcessor 结果；测试注入 fake。
protocol FaceDetectionServiceProtocol {
    /// 当前是否检测到人脸。
    func hasFace() -> Bool
}

/// 测试与 Preview 用的可替换实现。生产不使用此类。
final class FaceDetectionServiceStub: FaceDetectionServiceProtocol {
    static let shared = FaceDetectionServiceStub()
    private init() {}
    func hasFace() -> Bool { true }
}

#if !HILY_TESTS
/// 相芯检测结果在 `FUManager.renderPixelBuffer` 的渲染线程更新，避免主线程和 SDK render 并发访问。
final class FaceUnityFaceDetectionService: FaceDetectionServiceProtocol {
    static let shared = FaceUnityFaceDetectionService()
    private init() {}

    func hasFace() -> Bool {
        FUManager.shared().hasFaceDetected()
    }
}

/// 匹配通话中的本地相机由 CallView 持有；弱引用确保通话结束后不保留任何画面或相机资源。
@MainActor
private final class MatchCallCameraReference {
    weak var camera: CameraManager?
}

@MainActor
enum MatchCallEvidenceSource {
    private static let reference = MatchCallCameraReference()

    static func bind(_ camera: CameraManager) {
        reference.camera = camera
    }

    static func unbind(_ camera: CameraManager) {
        guard reference.camera === camera else { return }
        reference.camera = nil
    }

    /// CallFaceTimeView 初次出现和相机首帧之间有短窗口，最多等待 1 秒拿到当前通话帧。
    static func captureJPEGData() async -> Data? {
        for _ in 0..<10 {
            if let data = await reference.camera?.latestFrameJPEGData(maximumAge: 3) {
                return data
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return nil }
        }
        return nil
    }
}

@MainActor
final class MatchFaceEvidenceProvider: MatchFaceEvidenceProviding {
    static let shared = MatchFaceEvidenceProvider()
    private init() {}

    func capturePreviewEvidence(from session: MatchCameraSessionProtocol?) async -> Data? {
        await session?.latestFrameJPEGData()
    }

    func captureCallEvidence() async -> Data? {
        await MatchCallEvidenceSource.captureJPEGData()
    }

    func uploadEvidence(_ imageData: Data) async throws -> String {
        try await ImageUploader.shared.upload(rawData: imageData, preset: .feedback)
    }
}
#endif

enum FaceDetectionServiceFactory {
    static var production: FaceDetectionServiceProtocol {
        #if HILY_TESTS
        return FaceDetectionServiceStub.shared
        #else
        return FaceUnityFaceDetectionService.shared
        #endif
    }
}

enum MatchFaceEvidenceProviderFactory {
    static var production: MatchFaceEvidenceProviding? {
        #if HILY_TESTS
        return MatchFaceEvidenceTestProvider.shared
        #else
        return MatchFaceEvidenceProvider.shared
        #endif
    }
}

#if HILY_TESTS
/// 保持现有 MatchStore 状态机单测的默认“有证据”前提；具体失败分支由测试显式注入 nil provider 覆盖。
@MainActor
final class MatchFaceEvidenceTestProvider: MatchFaceEvidenceProviding {
    static let shared = MatchFaceEvidenceTestProvider()
    private init() {}

    func capturePreviewEvidence(from session: MatchCameraSessionProtocol?) async -> Data? { Data([0x00]) }
    func captureCallEvidence() async -> Data? { Data([0x00]) }
    func uploadEvidence(_ imageData: Data) async throws -> String { "test://match-face-evidence" }
}
#endif
