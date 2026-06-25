import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "Camera")

/// 相机采集管线：前置摄像头 → BGRA 帧 → 美颜处理器 → subscribers 字典分发给每个 CameraPreview（v5.8）。
///
/// onError callback：监听 RuntimeError / WasInterrupted / InterruptionEnded 三类系统通知；
/// 权限拒绝立即冒到 onError，其它错误由 LiveStore 持有 20s watcher 累计。
/// 美颜降级：FUBeautyRenderer 构造失败时自动 fallback 到 PassthroughRenderer，
/// `isBeautyFallback = true` 供 LiveRoomView 注入完成后通知 LiveStore.markBeautyUnavailable。
final class CameraManager: NSObject, ObservableObject {
    /// 相机错误类型（spec §5.1）
    enum CameraError: Equatable {
        case permissionDenied
        case sessionRuntimeError(description: String)
        case wasInterrupted(reasonRaw: Int)
        case interruptionEnded
    }

    let session = AVCaptureSession()

    /// 美颜处理器：默认 FUBeautyRenderer，失败降级 PassthroughRenderer。
    var renderer: BeautyRenderer
    /// 美颜是否降级（init 时确定，供 LiveRoomView 注入 store 后通知）
    let isBeautyFallback: Bool

    /// v5.8：多订阅者模型替代 v5.7 单闭包 onFrame。
    ///
    /// 历史：v5.3.3~v5.6 用 `var onFrame: ((CVPixelBuffer) -> Void)?` 单闭包后绑覆盖前绑，
    /// 直播私 call 场景里 PIP CameraPreview 后挂载会把 LiveRoomView 本体的 sink 覆写掉；
    /// v5.7 试图用 "updateUIView 每次强制重绑" 修复，但 SwiftUI 在 `.overlay { ... }` 内 view
    /// 消失时**不会**触发 ZStack 兄弟节点（本体 CameraPreview）的 updateUIView，本体永远拿不到
    /// 重绑机会，挂断后本端画面卡死 + 观众端断流。
    ///
    /// v5.8：字典存所有订阅者，每个 CameraPreview 持有独立 key（Coordinator 的 ObjectIdentifier），
    /// PIP dismantle 仅注销 PIP 自己那一格，本体 sink 始终留在字典里。
    /// 锁保护：subscribe/unsubscribe 在 main queue，captureOutput 在 videoQueue 读，必须 NSLock。
    private let subscribersLock = NSLock()
    private var subscribers: [ObjectIdentifier: (CVPixelBuffer) -> Void] = [:]

    /// 相机错误回调（LiveRoomView 注入；转发到 LiveStore.onCameraError）
    var onError: ((CameraError) -> Void)?

    /// 订阅每帧（已处理）回调。key 必须在 unsubscribe 时一致；CameraPreview 用 ObjectIdentifier(Coordinator)。
    func subscribe(_ key: ObjectIdentifier, sink: @escaping (CVPixelBuffer) -> Void) {
        subscribersLock.lock()
        subscribers[key] = sink
        subscribersLock.unlock()
    }

    /// 注销订阅。CameraPreview 在 dismantleUIView 时调用，确保 PIP 销毁后字典自动收敛。
    func unsubscribe(_ key: ObjectIdentifier) {
        subscribersLock.lock()
        subscribers.removeValue(forKey: key)
        subscribersLock.unlock()
    }

    /// 推送给订阅者 sink 的目标帧率（v5.1 弱网降级用）。
    /// 相机仍以 30fps 采集，但当 targetFPS=15 时按时间间隔丢弃一半帧，避免帧堆积导致画面卡顿。
    /// nonisolated 字段，captureOutput 在 videoQueue 读取，Int 写读为原子操作。
    var targetFPS: Int = 30
    private var lastPushedAt: TimeInterval = 0

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.anchor.livechat.session")
    private let videoQueue = DispatchQueue(label: "com.anchor.livechat.video")
    private let position: AVCaptureDevice.Position = .front
    private var configured = false

    override init() {
        // B 里程碑 spec §6.2：FUBeautyRenderer setup 失败自动降级
        do {
            self.renderer = try FUBeautyRenderer()
            self.isBeautyFallback = false
        } catch {
            logger.error("FaceUnity setup failed, falling back to passthrough: \(String(describing: error))")
            self.renderer = PassthroughRenderer()
            self.isBeautyFallback = true
        }
        super.init()
        addSessionObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

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

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = (position == .front) }
        }

        session.commitConfiguration()
        configured = true
    }

    // MARK: - 系统通知监听（spec §5.2）

    private func addSessionObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(handleRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
        nc.addObserver(
            self,
            selector: #selector(handleWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: session
        )
        nc.addObserver(
            self,
            selector: #selector(handleInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded,
            object: session
        )
        // v5.2 修复后台→前台画面卡顿+误触发 forceEnd：回前台主动重启 session
        nc.addObserver(
            self,
            selector: #selector(handleWillEnterForeground(_:)),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let desc = err?.localizedDescription ?? "unknown"
        logger.error("AVCaptureSession runtime error: \(desc)")
        // v5.3.1 review #2 阻塞修复：app 在 background 时 Task.sleep 不挂起，
        // 若此时 RuntimeError 触发 startCameraFailureWatcher，20s 后回前台 Task 醒来误触发 forceEnd(.cameraFailure)。
        // 后台静默仅日志，回前台后由 handleInterruptionEnded 或 willEnterForeground 重启 session。
        DispatchQueue.main.async { [weak self] in
            guard UIApplication.shared.applicationState != .background else {
                logger.warning("runtimeError in background; not reporting (avoid 20s Task.sleep误触发 forceEnd)")
                return
            }
            self?.onError?(.sessionRuntimeError(description: desc))
        }
    }

    @objc private func handleWasInterrupted(_ note: Notification) {
        let reasonRaw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? 0
        logger.warning("AVCaptureSession was interrupted reason=\(reasonRaw)")
        // v5.2：后台类 interruption 静默不上报 LiveStore（避免 20s watcher 误触发 forceEnd(.cameraFailure)）
        // AVCaptureSession.InterruptionReason 枚举：
        //   1 = videoDeviceNotAvailableInBackground (iOS 9+，app 进入后台 — 最常见误触发源)
        //   2 = audioDeviceInUseByAnotherClient
        //   3 = videoDeviceInUseByAnotherClient（被相机类 app 占用 — 真问题，上报）
        //   4 = videoDeviceNotAvailableWithMultipleForegroundApps（iPad 多任务）
        //   5 = videoDeviceNotAvailableDueToSystemPressure（散热限流 — 真问题，上报）
        if reasonRaw == 1 || reasonRaw == 4 {
            logger.info("background-type interruption (reason=\(reasonRaw)); not reporting to LiveStore")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onError?(.wasInterrupted(reasonRaw: reasonRaw))
        }
    }

    @objc private func handleInterruptionEnded(_ note: Notification) {
        logger.info("AVCaptureSession interruption ended; restart session")
        // v5.3.1 review #1 修订：先同步派发 onError 清 watcher，再 start()——
        // 缩小 sessionQueue.startRunning 与 main.async stopWatcher 之间的 race window。
        // 实际 race 仅在 InterruptionEnded 发生在 watcher 启动后 20s+ 触发（reason=1 已过滤，
        // 其他 reason 21s+ 才下播是 spec §13 #6b 预期行为），此修订属保守加固。
        DispatchQueue.main.async { [weak self] in
            self?.onError?(.interruptionEnded)
        }
        // v5.3：InterruptionEnded 时 session.isInterrupted 才变 false，此时 startRunning 才生效
        start()
    }

    /// v5.2：回前台防御性兜底
    /// 注：v5.3.1 review #6 注释纠正——startRunning 在 isInterrupted=true 时**不是 silently fail**，
    /// 而是被 iOS 内部排队，等 InterruptionEnded 后自动执行。
    /// 本入口保留作 InterruptionEnded 通知丢失时的最终兜底；正常路径由 handleInterruptionEnded 触发。
    @objc private func handleWillEnterForeground(_ note: Notification) {
        logger.info("App will enter foreground; ensure capture session is running")
        start()
    }

    /// v5.3.1 review #5 阻塞修复：CameraManager observer 跨 dismiss 仍响应导致摄像头灯亮。
    /// LiveRoomView.onDisappear 显式调用本方法，同步：
    /// 1. 移除 NotificationCenter observer（避免 willEnterForeground 重启已离开的 session）
    /// 2. 清空所有订阅者 + onError 闭包（避免被 capture 帧 mutate 已销毁的 store）
    /// 3. 同步 stop session（确保摄像头灯熄灭）
    func tearDown() {
        logger.info("CameraManager tearDown: removing observers, clearing subscribers, stopping session")
        NotificationCenter.default.removeObserver(self)
        subscribersLock.lock()
        subscribers.removeAll()
        subscribersLock.unlock()
        onError = nil
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

// MARK: - 帧回调

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // v5.1 弱网降级：按 targetFPS 节流推帧（targetFPS=15 时丢一半帧，避免编码器堆积导致卡顿）
        let now = CACurrentMediaTime()
        let interval = 1.0 / Double(max(1, targetFPS))
        if now - lastPushedAt < interval { return }
        lastPushedAt = now
        let processed = renderer.process(pixelBuffer)
        // v5.8：锁内拷贝 sink snapshot，锁外分发；避免长时间持锁阻塞 main queue 的 subscribe/unsubscribe。
        subscribersLock.lock()
        let sinks = Array(subscribers.values)
        subscribersLock.unlock()
        for sink in sinks {
            sink(processed)
        }
    }
}
