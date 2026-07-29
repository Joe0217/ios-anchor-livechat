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

    /// Bug fix 2026-07-11：@StateObject 释放时（NavigationStack pop 整个 register 栈，view identity 结束）
    /// 触发 camera.tearDown() 做最终清理。camera.tearDown() 是 nonisolated 方法，可在 deinit 安全调。
    /// audio I/O / writer / timer 交给 ARC dealloc；预览页前会主动移除 audio I/O，重录时按需重新挂载。
    deinit {
        camera.tearDown()
    }

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
        /// v5 修 2026-07-12：adaptor.pixelBufferPool 罕见情况下 nil（sourcePixelBufferAttributes 未含 IOSurface key
        /// 或 startSession 时序问题）→ 走 fallback 直接 append 非-IOSurface backed FUBeauty buffer 报 -16364。
        /// 手工建 IOSurface backed pool 兜底，保证一定有 IOSurface backed dest buffer 可用。
        let manualPool: CVPixelBufferPool?
        let width: Int
        let height: Int
        var hasStartedSession = false

        init(writer: AVAssetWriter,
             videoInput: AVAssetWriterInput,
             audioInput: AVAssetWriterInput,
             adaptor: AVAssetWriterInputPixelBufferAdaptor,
             manualPool: CVPixelBufferPool?,
             width: Int, height: Int) {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
            self.manualPool = manualPool
            self.width = width
            self.height = height
        }
    }

    // MARK: - Public API

    /// 权限 + camera.start + audio input/output 配置
    ///
    /// Bug fix 2026-07-11：**幂等 guard**——SwiftUI `.task { ... prepare() }` modifier 在 view 每次可见时启动 task，
    /// Re-record 从 preview pop 回 record view 时 view 重新可见 → `.task` 再触发 prepare。
    /// 若无 guard 则：state 被重置为 .preparing → 打乱 onAppear 的 `state == .finished` 检测（restartForRecording 分支跳过）；
    /// 再走到 `camera.addAudioIO(...)` 而 audio input/output 从未被移除（suspend 保留）→
    /// `session.canAddInput(existing_input)` 返 false → addedInput=nil + addedOutput=nil →
    /// guard 触发 `state=.failed(.configFailed("audio: no mic device or session cannot add I/O"))` →
    /// onChange(.failed) → toast "Recording interrupted. Please retry" + pop（用户症状）
    func prepare() async {
        // 幂等：只在初始 .idle 时真正 prepare；后续 .task 重启动一律跳过（restartForRecording 由 onAppear 单独触发）
        guard case .idle = state else {
            logger.info("[Recorder] prepare skipped, state=\(String(describing: self.state), privacy: .public) (already prepared)")
            return
        }
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

        // Finding #4 修 2026-07-10：audio I/O 通过 CameraManager.addAudioIO 走 sessionQueue 串行
        // 避免 @MainActor 直接 session.beginConfiguration 与 CameraManager sessionQueue 内部 configureIfNeeded/handleInterruption 争用 crash
        let (mic, out) = await camera.addAudioIO(sampleBufferDelegate: self, deliveryQueue: audioQueue)
        guard mic != nil || out != nil else {
            state = .failed(.configFailed("audio: no mic device or session cannot add I/O"))
            logger.error("[Recorder] audio config failed: addAudioIO returned nil for both")
            return
        }
        micInput = mic
        audioOutput = out
        logger.info("[Recorder] audio I/O added via sessionQueue: input=\(mic != nil, privacy: .public) output=\(out != nil, privacy: .public)")

        // 录制期间清 sticker（对齐 2026-07-10 用户决策：审核视频不要贴纸干扰；其他美颜参数 保留）
        // SDK sticker 状态是全局（FUManager OC 单例），清空后 teardown 时通过 apply 当前 store.settings 恢复
        let sharedStore = BeautyPipelineSharer.shared.store
        var recordingSettings = sharedStore.settings
        let originalStickerId = recordingSettings.stickerId
        recordingSettings.stickerId = nil
        camera.renderer.apply(recordingSettings)
        logger.info("[Recorder] sticker cleared for recording (saved id=\(originalStickerId ?? "nil", privacy: .public))")

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

    /// 用户 Re-record 后 pop 回 record view，若 recorder 已进入 .finished 或 session 被意外停（push preview 可能触发 onDisappear teardown），
    /// 重启到可再次录制态。幂等：若 session 仍 running 且 state 是 .ready 直接 no-op；否则重启 session + 清 writer 残留
    ///
    /// Bug fix 2026-07-10 用户反馈：重录时画面卡死 —— session 被停 or subscribe 断
    /// Post-review NEW-1 修：teardown 已 removeAudioIO 让二次录制无音轨 → restart 时若 audioOutput nil 重加
    func restartForRecording() async {
        logger.info("[Recorder] restartForRecording enter; state=\(String(describing: self.state), privacy: .public) sessionRunning=\(self.camera.session.isRunning, privacy: .public) audioOutput=\(self.audioOutput != nil, privacy: .public)")

        // P1-1 修 2026-07-12：无条件调 start；sessionQueue 串行保证 suspend 的 pending stop 完成后 start 排队执行 → stop → start → running。
        // 原 `!isRunning` 外层 guard 与 suspend 的 `sessionQueue.async { stopRunning }` 存在 race：
        //   1. suspend() → sessionQueue.async stop 入队（未执行）
        //   2. 用户极限快速点 Re-record → onAppear → restartForRecording
        //   3. check session.isRunning → 仍 true（block 未跑）→ **跳过 start**
        //   4. 之后 sessionQueue block 执行 stopRunning → session 停 → 用户点 Record → 无帧 → 20s 后 toast + pop
        // camera.start 幂等：sessionQueue.async 内 `if !session.isRunning { startRunning }` 处理已 running 情况（no-op）。
        camera.start()
        let deadline = Date().addingTimeInterval(3)
        while !camera.session.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard camera.session.isRunning else {
            state = .failed(.configFailed("session did not restart within 3s"))
            logger.error("[Recorder] restartForRecording: session restart timeout")
            return
        }
        logger.info("[Recorder] restartForRecording: session ensured running")

        // Post-review NEW-1 修 2026-07-10：teardown 已 removeAudioIO → restart 时若 audioOutput nil 重新 addAudioIO，避免二次录制无音轨
        if audioOutput == nil {
            let (mic, out) = await camera.addAudioIO(sampleBufferDelegate: self, deliveryQueue: audioQueue)
            micInput = mic
            audioOutput = out
            logger.info("[Recorder] restartForRecording: audio I/O re-added input=\(mic != nil, privacy: .public) output=\(out != nil, privacy: .public)")
        }

        // 清 writer 残留（若上次录制 finished 后 writerBox 已 nil，此处 no-op）
        writerQueue.sync {
            writerBox = nil
            pendingOutputUrl = nil
        }
        elapsed = 0
        state = .ready
        logger.info("[Recorder] restartForRecording → .ready")
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

    /// Bug fix 2026-07-11：push preview 场景用（RegisterVideoRecordView.onDisappear）
    ///
    /// 停止 session 并移除 audio I/O，让摄像头和麦克风均释放；**保留 subscribers 字典**
    /// （含 CameraPreview Coordinator 的 sink）以支持返回录制页后的重录。
    ///
    /// **不能**调 `teardown()` / `camera.tearDown()`——那会 `subscribers.removeAll()` 清掉 CameraPreview 的 sink，
    /// pop 回来时 SwiftUI 不保证触发 `CameraPreview.updateUIView` 重新 subscribe（`.claude/rules/swiftui-camera-preview.md §3` 明确坑），
    /// 导致 Re-record 画面卡最后一帧（recorder 自己的 subscribe 在 startRecording 里显式重加，所以录出的 mp4 正常）。
    ///
    /// `CameraManager.stop()` 同时禁止前台自动恢复；重新录制时由 `restartForRecording()` 显式 `start()`。
    /// 真正 flow 退出（NavigationStack pop 整个注册栈 → view identity 结束 → @StateObject deinit）由 `deinit` 触发 `camera.tearDown()`。
    func suspend() {
        timer?.invalidate()
        timer = nil
        camera.removeAudioIO(input: micInput, output: audioOutput)
        micInput = nil
        audioOutput = nil
        camera.stop()
        logger.info("[Recorder] suspend: camera/microphone stopped, subscribers preserved for Re-record")
    }

    /// Page dismiss 时（对齐 spec §4.1 v3 MAJOR-3：onDisappear 需守卫 scenePhase != .background）
    ///
    /// v3 修：**不再** @MainActor 直接调 session.beginConfiguration（与 CameraManager.sessionQueue 争用）；
    /// audio input/output 由 camera.tearDown 内部触发 stopRunning 后自然停送 sample，session dealloc 时随之释放
    func teardown() {
        // 先恢复用户原贴纸设置（FUManager OC 单例的 sticker state 全局，录制期间清空后需恢复；
        // apply 当前 store.settings 而非快照，避免录制期间用户 mutate store 导致回退错版本）
        let currentSettings = BeautyPipelineSharer.shared.store.settings
        camera.renderer.apply(currentSettings)
        logger.info("[Recorder] beauty settings restored (sticker id=\(currentSettings.stickerId ?? "nil", privacy: .public))")

        timer?.invalidate()
        timer = nil
        if let key = subscribeKey {
            camera.unsubscribe(key)
            subscribeKey = nil
        }
        // Finding #4 修：走 CameraManager.removeAudioIO 通过 sessionQueue 串行移除 audio I/O
        camera.removeAudioIO(input: micInput, output: audioOutput)
        // camera tearDown（内部 sessionQueue.async 里 stopRunning + observer 清；顺序在 removeAudioIO 之后 → 都在 sessionQueue 串行）
        camera.tearDown()
        // Finding #5 修 2026-07-10：teardown 若命中 recording 中场景（外部 logout/1004 触发 dismiss），
        // 直接 writerBox=nil 会让 AVAssetWriter 于 .writing 状态被 ARC dealloc → 残缺 mp4 + AVFoundation warning。
        // 修：writerQueue.sync 内先 markAsFinished + finishWriting fire-and-forget，让 writer 有机会 finalize file
        writerQueue.sync {
            if let box = writerBox, box.hasStartedSession, box.writer.status == .writing {
                box.videoInput.markAsFinished()
                box.audioInput.markAsFinished()
                box.writer.finishWriting {
                    // completion 在 arbitrary queue；此时 recorder 可能已 dealloc，无需回主线程改 state
                }
                self.logger.info("[Recorder] teardown: writer finalize triggered (mp4 will be saved async)")
            }
            writerBox = nil
            pendingOutputUrl = nil
        }
        micInput = nil
        audioOutput = nil
        logger.info("[Recorder] teardown")
    }

    // MARK: - Private

    // configureAudio removed: replaced by CameraManager.addAudioIO (走 sessionQueue 串行, Finding #4)

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

        // v5 修 2026-07-12：从 adaptor.pool 或 manualPool 取 IOSurface backed dest buffer + memcpy 美颜数据 → append
        // 直接 append FUBeauty 返回的非-IOSurface backed pixelBuffer 会让硬件编码器报 -16364（用户 2026-07-12 日志）
        // 所以**禁止**再走"pool nil → direct append"fallback；改为 `adaptor.pool ?? box.manualPool` 双兜底
        let pool = box.adaptor.pixelBufferPool ?? box.manualPool
        guard let pool else {
            logger.error("[Recorder] both adaptor.pool and manualPool nil; cannot allocate IOSurface buffer (writer.status=\(box.writer.status.rawValue, privacy: .public))")
            return
        }
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
                // Finding #10 修 2026-07-10：dst 每行 padding 区（dstRow > srcRow 的 tail）先 memset 0 清零，
                // 避免 pool buffer 前次帧数据残留让编码器读到垃圾 → 视频右侧竖条纹残影
                memset(dst, 0, dstRow * h)
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
            logger.error("[Recorder] adaptor.append returned false; writer.status=\(box.writer.status.rawValue, privacy: .public) error=\(String(describing: box.writer.error), privacy: .public)")
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
    ///
    /// v5 修 2026-07-12（用户报 pool nil + -16364 + writer.status=3）：
    /// 1. sourcePixelBufferAttributes 加 `kCVPixelBufferIOSurfacePropertiesKey: [:]` 让 adaptor.pixelBufferPool 分配 IOSurface backed buffers（硬件编码器要求）；
    ///    原 attrs 只有 pixelFormat + width + height 导致 pool 建不出来（返 nil）→ fallback 直接 append 非-IOSurface FUBeauty buffer → -16364
    /// 2. 手工建 CVPixelBufferPool 存 WriterBox.manualPool 兜底：若 adaptor.pixelBufferPool 仍 nil，可用手工 pool 分配 IOSurface backed dest buffer
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

        // 关键：kCVPixelBufferIOSurfacePropertiesKey 让 CoreVideo 分配 IOSurface backed pool buffers（硬件编码器要求）
        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vi,
            sourcePixelBufferAttributes: pixelBufferAttrs
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

        // 手工 pool 兜底（adaptor.pixelBufferPool 罕见情况仍 nil 时用）
        var manualPool: CVPixelBufferPool?
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4
        ]
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, pixelBufferAttrs as CFDictionary, &manualPool)

        return WriterBox(
            writer: writer,
            videoInput: vi,
            audioInput: ai,
            adaptor: adaptor,
            manualPool: manualPool,
            width: width,
            height: height
        )
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
