import Foundation
import AVFoundation
import Combine
import os

/// 注册视频录制器（含美颜，2026-07-09 v3）
///
/// **架构**（对齐用户 2026-07-09 决策"Preview + 输出都带美颜"）：
/// - 复用直播采集管线：`CameraManager` (VideoDataOutput 32BGRA → FUBeautyRenderer 美颜 → subscribers 字典分发)
///   本类为 register 场景独立持一个 CameraManager 实例（与直播 singleton 生命周期解耦，符合
///   `.claude/rules/cross-scene-component-reuse-preflight.md` "复用底层能力但场景实例独立"精神）
/// - Preview：subscribe 拿美颜后帧 → 走 `CameraPreview`（`Sources/Camera/CameraPreview.swift`；MetalPreviewView 渲染）
/// - 录制：额外 subscribe 拿美颜后帧 → `AVAssetWriterInputPixelBufferAdaptor.append(pixelBuffer)` 写 mp4
/// - Audio：`AVCaptureAudioDataOutput` delegate 拿 audio sample → `AVAssetWriterInput.append(audioSample)` 写 mp4
/// - 20s 硬约束：Timer 到点自动 stopRecording
///
/// **v3 关键修复 (2026-07-09 用户报"录完闪退")**：
/// 1. **动态 writer 尺寸**：CameraManager 用 hd1280x720 preset，pixel buffer 实际尺寸 720x1280 (rotate 后)
///    或 1280x720 (rotate 前)。原写死 1080x1920 output 与 pixel buffer 尺寸不匹配 → adaptor.append crash。
///    修：首帧到达时读实际 CVPixelBuffer W/H 动态建 writer，保证尺寸严格一致
/// 2. **teardown 不再 @MainActor 直接调 session.beginConfiguration**：
///    与 CameraManager.sessionQueue 内部串行 configure 并发 → session state race → crash。
///    修：audio input/output 释放交给 CameraManager.tearDown 内部（stopRunning 后 audio delegate 不再 fire；
///    session dealloc 时 I/O 引用随之释放）
/// 3. **check startWriting 返回值**：false 时 writer.status=.failed，后续 startSession/append crash → 提前 fail
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
    nonisolated(unsafe) private var pendingOutputUrl: URL?    // startRecording 时预设，handleVideoFrame 首帧建 writer 用

    private var subscribeKey: ObjectIdentifier?
    private var timer: Timer?
    private let maxDuration: TimeInterval = 20.0
    private let logger = Logger(subsystem: "com.anchor.livechat", category: "RegisterRecorder")

    /// Writer 相关状态整合到一个 nonisolated struct，writerQueue 串行独占访问
    private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let width: Int
        let height: Int
        var hasStartedSession = false

        init(writer: AVAssetWriter,
             videoInput: AVAssetWriterInput,
             audioInput: AVAssetWriterInput,
             adaptor: AVAssetWriterInputPixelBufferAdaptor,
             width: Int, height: Int) {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
            self.width = width
            self.height = height
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
        logger.info("[Recorder] state → .ready (camera + audio + beauty pipeline; sessionPreset=\(String(describing: self.camera.session.sessionPreset), privacy: .public))")
    }

    func startRecording() {
        guard state == .ready else {
            logger.warning("[Recorder] startRecording ignored, state=\(String(describing: self.state), privacy: .public)")
            return
        }

        // v3 修：不立即建 writer，等 handleVideoFrame 首帧到达时用实际 pixel buffer W/H 动态建
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("register-beauty-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)
        pendingOutputUrl = url
        writerBox = nil

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
        logger.info("[Recorder] startRecording pending URL: \(url.path, privacy: .public); writer 首帧到达时建")
    }

    /// 20s 到点自动调 or 外部主动 stop
    func stopRecording() {
        guard case .recording = state else {
            logger.warning("[Recorder] stopRecording ignored, state=\(String(describing: self.state), privacy: .public)")
            return
        }

        // 立即断帧订阅（unsubscribe 是 sync，从 CameraManager.subscribers 字典移除 sink）
        if let key = subscribeKey {
            camera.unsubscribe(key)
            subscribeKey = nil
        }
        timer?.invalidate()
        timer = nil

        writerQueue.async { [weak self] in
            guard let self else { return }
            guard let box = self.writerBox else {
                // writer 未建过（首帧未到达就 stop）→ 无内容可保存
                Task { @MainActor in
                    self.state = .failed(.fileWriteFailed("no video frames captured (writer never built)"))
                    self.logger.error("[Recorder] stopRecording: writer nil (no frames)")
                }
                return
            }
            self.logger.info("[Recorder] stopRecording: markAsFinished + finishWriting")
            box.videoInput.markAsFinished()
            box.audioInput.markAsFinished()
            box.writer.finishWriting {
                Task { @MainActor in
                    if box.writer.status == .completed, let url = self.pendingOutputUrl {
                        self.state = .finished(localUrl: url)
                        self.logger.info("[Recorder] writer completed -> \(url.path, privacy: .public)")
                    } else {
                        let msg = box.writer.error?.localizedDescription ?? "writer.status=\(box.writer.status.rawValue)"
                        self.state = .failed(.fileWriteFailed(msg))
                        self.logger.error("[Recorder] writer failed: \(msg, privacy: .public)")
                    }
                    self.writerBox = nil
                    self.pendingOutputUrl = nil
                }
            }
        }
    }

    /// Page dismiss 时（对齐 spec §4.1 v3 MAJOR-3：onDisappear 需守卫 scenePhase != .background）
    ///
    /// v3 修：**不再** @MainActor 直接调 session.beginConfiguration（与 CameraManager.sessionQueue 争用）；
    /// audio input/output 由 camera.tearDown 内部触发 stopRunning 后自然停送 sample，session dealloc 时随之释放
    func teardown() {
        timer?.invalidate()
        timer = nil
        if let key = subscribeKey {
            camera.unsubscribe(key)
            subscribeKey = nil
        }
        // audio delegate 设 nil 让 audioOutput 停送 sample（无需 beginConfiguration removeOutput）
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        // camera tearDown（内部 sessionQueue.async 里 stopRunning + observer 清）
        camera.tearDown()
        // writer 状态清（sync 保证 pending writerQueue job 处理完）
        writerQueue.sync {
            writerBox = nil
            pendingOutputUrl = nil
        }
        micInput = nil
        audioOutput = nil
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
                logger.info("[Recorder] audio input added")
            }
        }
        // audio output
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
            audioOutput = output
            logger.info("[Recorder] audio output added")
        }
    }

    /// writerQueue 串行调，处理美颜后视频帧
    ///
    /// v3 修：首帧到达时用实际 CVPixelBuffer 尺寸动态建 writer，保证 adaptor.append 尺寸严格匹配
    /// v4 修（2026-07-10 用户报 -16364 崩溃）：FUBeautyRenderer 返回的 pixel buffer **非 IOSurface backed**
    ///     （FaceUnity SDK 内部自建），AVAssetWriter 硬件编码要求 IOSurface backed → append 报 -16364。
    ///     修：从 `adaptor.pixelBufferPool` 取 IOSurface backed buffer，memcpy 美颜后数据过去再 append
    nonisolated private func handleVideoFrame(_ pixelBuffer: CVPixelBuffer) {
        // 首帧建 writer
        if writerBox == nil {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard let url = pendingOutputUrl else {
                logger.error("[Recorder] handleVideoFrame: no pendingOutputUrl")
                return
            }
            do {
                let box = try Self.buildWriter(outputUrl: url, width: width, height: height)
                guard box.writer.startWriting() else {
                    let errMsg = box.writer.error?.localizedDescription ?? "startWriting returned false"
                    logger.error("[Recorder] handleVideoFrame: startWriting failed: \(errMsg, privacy: .public)")
                    return
                }
                writerBox = box
                logger.info("[Recorder] writer built with size \(width, privacy: .public)x\(height, privacy: .public); status=\(box.writer.status.rawValue, privacy: .public)")
            } catch {
                logger.error("[Recorder] handleVideoFrame: buildWriter throw: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        guard let box = writerBox else { return }

        let now = CMTimeMakeWithSeconds(CACurrentMediaTime(), preferredTimescale: 600)
        if !box.hasStartedSession {
            box.writer.startSession(atSourceTime: now)
            box.hasStartedSession = true
            logger.info("[Recorder] startSession at \(now.seconds, privacy: .public)")
        }

        guard box.videoInput.isReadyForMoreMediaData else { return }

        // v4 修：从 adaptor pool 取 IOSurface backed buffer + memcpy 美颜数据 → append
        // 直接 append 美颜后 pixelBuffer 会因非 IOSurface backed 让 writer 硬件编码报 -16364
        if let pool = box.adaptor.pixelBufferPool {
            var dest: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dest)
            guard poolStatus == kCVReturnSuccess, let destBuffer = dest else {
                logger.error("[Recorder] pool.createPixelBuffer failed status=\(poolStatus, privacy: .public)")
                return
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferLockBaseAddress(destBuffer, [])
            if let src = CVPixelBufferGetBaseAddress(pixelBuffer),
               let dst = CVPixelBufferGetBaseAddress(destBuffer) {
                let srcRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let dstRow = CVPixelBufferGetBytesPerRow(destBuffer)
                let h = CVPixelBufferGetHeight(pixelBuffer)
                if srcRow == dstRow {
                    memcpy(dst, src, srcRow * h)
                } else {
                    for row in 0..<h {
                        memcpy(dst.advanced(by: row * dstRow),
                               src.advanced(by: row * srcRow),
                               min(srcRow, dstRow))
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(destBuffer, [])
            if !box.adaptor.append(destBuffer, withPresentationTime: now) {
                logger.error("[Recorder] adaptor.append (pool copy) returned false; writer.status=\(box.writer.status.rawValue, privacy: .public) error=\(String(describing: box.writer.error), privacy: .public)")
            }
        } else {
            // pool 未 ready（罕见），fallback 直接 append 原 buffer
            if !box.adaptor.append(pixelBuffer, withPresentationTime: now) {
                logger.error("[Recorder] adaptor.append (no pool) returned false; writer.status=\(box.writer.status.rawValue, privacy: .public) error=\(String(describing: box.writer.error), privacy: .public)")
            }
        }
    }

    /// writerQueue 串行调，处理 audio sample
    nonisolated private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let box = writerBox, box.hasStartedSession else { return }
        if box.audioInput.isReadyForMoreMediaData {
            box.audioInput.append(sampleBuffer)
        }
    }

    /// 建 writer（同步；startWriting 由调用方 check 返回）
    ///
    /// nonisolated static helper：让 handleVideoFrame（nonisolated func）能同步调，不跨 actor 边界
    nonisolated private static func buildWriter(outputUrl: URL, width: Int, height: Int) throws -> WriterBox {
        let writer = try AVAssetWriter(outputURL: outputUrl, fileType: .mp4)

        // Video input: 尺寸严格匹配 source pixel buffer；BGRA 输入（CameraManager 用 32BGRA）
        // 目标 bitrate 2.5Mbps H.264 High autoLevel（Compressor 会二次压缩到更小）
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
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
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
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

        return WriterBox(writer: writer, videoInput: vi, audioInput: ai, adaptor: adaptor, width: width, height: height)
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
