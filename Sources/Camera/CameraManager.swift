import AVFoundation
import CoreVideo

/// 相机采集管线：前置摄像头 -> BGRA 帧 -> 美颜处理器 -> onFrame 回调给预览。
///
/// 输出格式选 BGRA，便于 Core Image 预览，相芯 FURenderKit 也直接支持 BGRA 的 CVPixelBuffer。
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    /// 美颜处理器：相芯 FUBeautyRenderer（已接入）
    var renderer: BeautyRenderer = FUBeautyRenderer()
    /// 每帧（已处理）回调，用于预览渲染
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.anchor.beautypoc.session")
    private let videoQueue = DispatchQueue(label: "com.anchor.beautypoc.video")
    private let position: AVCaptureDevice.Position = .front
    private var configured = false

    // MARK: - 权限

    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - 生命周期

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - 配置

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        // 输入：前置广角摄像头
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        // 输出：BGRA + 丢弃迟到帧（保证实时性）
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // 方向竖屏 + 前置镜像（自拍习惯）
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = (position == .front) }
        }

        session.commitConfiguration()
        configured = true
    }
}

// MARK: - 帧回调

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 美颜处理（直通时原样返回；相芯接入后在此处理）
        let processed = renderer.process(pixelBuffer)
        onFrame?(processed)
    }
}
