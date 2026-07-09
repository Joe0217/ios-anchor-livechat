import Foundation
import AVFoundation
import Combine
import os

/// 注册视频录制器（含美颜，2026-07-09 v2）
///
/// **架构**（对齐用户 2026-07-09 决策"Preview + 输出都带美颜"）：
/// - 复用直播采集管线：`CameraManager` (VideoDataOutput 32BGRA → FUBeautyRenderer 美颜 → subscribers 字典分发)
///   本类为 register 场景独立持一个 CameraManager 实例（与直播 singleton 生命周期解耦，符合
///   `.claude/rules/cross-scene-component-reuse-preflight.md` "复用底层能力但场景实例独立"精神）
/// - Preview：subscribe 拿美颜后帧 → 走 `CameraPreview`（`Sources/Camera/CameraPreview.swift`；MetalPreviewView 渲染）
/// - 录制：额外 subscribe 拿美颜后帧 → `AVAssetWriterInputPixelBufferAdaptor.append(pixelBuffer)` 写 mp4
/// - Audio：`AVCaptureAudioDataOutput` delegate 拿 audio sample → `AVAssetWriterInput.append(audioSample)` 写 mp4
/// - 20s 硬约束：Timer 到点自动 stopRecording
@MainActor
final class RegisterVideoRecorder: NSObject, ObservableObject {

    @Published private(set) var state: VideoRecordState = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    /// 复用直播美颜管线（独立实例；与直播 singleton 生命周期解耦）
    let camera = CameraManager()

    // ─── audio 采集（同一 session） ───
    private var micInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let audioQueue = DispatchQueue(label: "com.anchor.livechat.register.audio")

    // ─── AVAssetWriter pipeline（存 nonisolated 允许 writerQueue 串行访问） ───
    private let writerQueue = DispatchQueue(label: "com.anchor.livechat.register.writer")
    nonisolated(unsafe) private var writerBox: WriterBox?

    private var subscribeKey: ObjectIdentifier?
    private var timer: Timer?
    private var outputUrl: URL?
    private let maxDuration: TimeInterval = 20.0
    private let logger = Logger(subsystem: "com.anchor.livechat", category: "RegisterRecorder")

    /// Writer 相关状态整合到一个 nonisolated struct，writerQueue 串行独占访问
    private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        var startTime: CMTime?      // 首帧 pts 作为 startSession（避免 negative time）
        var hasStartedSession = false

        init(writer: AVAssetWriter,
             videoInput: AVAssetWriterInput,
             audioInput: AVAssetWriterInput,
             adaptor: AVAssetWriterInputPixelBufferAdaptor) {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
        }
    }

    // MARK: - Public API

    /// 权限 + camera.start + audio input/output 配置
    func prepare() async {
        logger.info("[Recorder] prepare() enter")
        state = .preparing

        let camGranted = await AVCaptureDevice.requestAccess(for: .video)
        guard camGranted else {
            state = .failed(.cameraDenied)
            logger.error("[Recorder] camera denied")
            return
        }
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            state = .failed(.microphoneDenied)
            logger.error("[Recorder] mic denied")
            return
        }

        // CameraManager.start() 内部 sessionQueue.async → configureIfNeeded + startRunning
        camera.start()

        // 轮询等 session.isRunning=true 后再 configureAudio（避免与 CameraManager 内部 configureIfNeeded 争用 session）
        let deadline = Date().addingTimeInterval(3)
        while !camera.session.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)   // 50ms
        }
        guard camera.session.isRunning else {
            state = .failed(.configFailed("camera session did not start within 3s"))
            logger.error("[Recorder] camera session not running after 3s timeout")
            return
        }

        // 加 audio input + output（video 已配好，此时 session 已 running）
        do {
            try configureAudio()
        } catch {
            state = .failed(.configFailed("audio: \(error.localizedDescription)"))
            logger.error("[Recorder] audio config failed \(error.localizedDescription, privacy: .public)")
            return
        }

        state = .ready
        logger.info("[Recorder] state → .ready (camera + audio + beauty pipeline)")
    }

    func startRecording() {
        guard state == .ready else {
            logger.warning("[Recorder] startRecording ignored, state=\(String(describing: self.state), privacy: .public)")
            return
        }

        // 建 writer（同步初始化，异步 startWriting）
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("register-beauty-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)
        outputUrl = url

        let box: WriterBox
        do {
            box = try buildWriter(outputUrl: url)
        } catch {
            state = .failed(.configFailed("writer: \(error.localizedDescription)"))
            logger.error("[Recorder] writer setup failed \(error.localizedDescription, privacy: .public)")
            return
        }

        writerQueue.sync {
            writerBox = box
            box.writer.startWriting()
        }

        // 订阅美颜后帧（帧走 CameraManager.captureOutput → renderer.process → subscribers）
        let key = ObjectIdentifier(self)
        subscribeKey = key
        camera.subscribe(key) { [weak self] pixelBuffer in
            self?.writerQueue.async {
                self?.handleVideoFrame(pixelBuffer)
            }
        }

        elapsed = 0
        state = .recording(elapsed: 0)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = min(self.maxDuration, self.elapsed + 0.05)
                self.state = .recording(elapsed: self.elapsed)
                if self.elapsed >= self.maxDuration {
                    self.stopRecording()
                }
            }
        }
        logger.info("[Recorder] startRecording -> \(url.path, privacy: .public)")
    }

    /// 20s 到点自动调 or 外部主动 stop
    func stopRecording() {
        guard case .recording = state else { return }

        // 立即断帧订阅（避免 stop 期间还有帧 append 到已 finish 的 writer）
        if let key = subscribeKey {
            camera.unsubscribe(key)
            subscribeKey = nil
        }
        timer?.invalidate()
        timer = nil

        writerQueue.async { [weak self] in
            guard let self else { return }
            guard let box = self.writerBox else {
                Task { @MainActor in self.state = .failed(.fileWriteFailed("writer missing")) }
                return
            }
            box.videoInput.markAsFinished()
            box.audioInput.markAsFinished()
            box.writer.finishWriting {
                Task { @MainActor in
                    if box.writer.status == .completed, let url = self.outputUrl {
                        self.state = .finished(localUrl: url)
                        self.logger.info("[Recorder] writer completed -> \(url.path, privacy: .public)")
                    } else {
                        let msg = box.writer.error?.localizedDescription ?? "writer failed"
                        self.state = .failed(.fileWriteFailed(msg))
                        self.logger.error("[Recorder] writer failed: \(msg, privacy: .public)")
                    }
                    self.writerBox = nil
                }
            }
        }
    }

    /// Page dismiss 时（对齐 spec §4.1 v3 MAJOR-3：onDisappear 需守卫 scenePhase != .background）
    func teardown() {
        timer?.invalidate()
        timer = nil
        if let key = subscribeKey {
            camera.unsubscribe(key)
            subscribeKey = nil
        }
        // 移除 audio input/output
        camera.session.beginConfiguration()
        if let mic = micInput { camera.session.removeInput(mic) }
        if let out = audioOutput { camera.session.removeOutput(out) }
        camera.session.commitConfiguration()
        micInput = nil
        audioOutput = nil
        // camera tearDown（session.stopRunning + observer 清）
        camera.tearDown()
        writerQueue.sync { writerBox = nil }
        logger.info("[Recorder] teardown")
    }

    // MARK: - Private

    private func configureAudio() throws {
        let session = camera.session
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // audio input
        if let mic = AVCaptureDevice.default(for: .audio) {
            let input = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(input) {
                session.addInput(input)
                micInput = input
            }
        }
        // audio output
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
            audioOutput = output
        }
    }

    /// 构建 writer（同步；startWriting 在 writerQueue 内异步调）
    private func buildWriter(outputUrl: URL) throws -> WriterBox {
        let writer = try AVAssetWriter(outputURL: outputUrl, fileType: .mp4)

        // Video input: 1080x1920 竖屏 H.264 2.5Mbps；BGRA 输入（CameraManager 用 32BGRA）
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ])
        vi.expectsMediaDataInRealTime = true
        writer.add(vi)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vi,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920
            ]
        )

        // Audio input: AAC 44.1kHz stereo 128kbps
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ])
        ai.expectsMediaDataInRealTime = true
        writer.add(ai)

        return WriterBox(writer: writer, videoInput: vi, audioInput: ai, adaptor: adaptor)
    }

    /// writerQueue 串行调，处理美颜后视频帧
    nonisolated private func handleVideoFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let box = writerBox else { return }

        // 首帧：以当前 host time 作 session start，避免 pts=0 vs 系统 host time 不一致导致 negative time
        let now = CMTimeMakeWithSeconds(CACurrentMediaTime(), preferredTimescale: 600)
        if !box.hasStartedSession {
            box.writer.startSession(atSourceTime: now)
            box.startTime = now
            box.hasStartedSession = true
        }

        if box.videoInput.isReadyForMoreMediaData {
            box.adaptor.append(pixelBuffer, withPresentationTime: now)
        }
    }

    /// writerQueue 串行调，处理 audio sample
    nonisolated private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let box = writerBox, box.hasStartedSession else { return }
        // Audio pts 用 sampleBuffer 自带 pts（视频已 anchor 到 host time；音视频独立时间轴 mp4 内部自 mux）
        if box.audioInput.isReadyForMoreMediaData {
            box.audioInput.append(sampleBuffer)
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension RegisterVideoRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        writerQueue.async { [weak self] in
            self?.handleAudioSample(sampleBuffer)
        }
    }
}
