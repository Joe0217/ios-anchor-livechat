import AVFoundation
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "VoiceRecorder")

/// 语音录制器（H-2 spec §4.3，对齐 H5 `recording.vue` 60s 自动停止）。
///
/// **格式**：m4a AAC 44.1kHz 单声道（iOS 主流；NIMSDK 云信端支持）
/// **持久化**：录到 `.cachesDirectory/chat/audio/{UUID}.m4a`（比 tmp 更抗系统 auto clean）
/// **60s 上限**：对齐 H5 `recording.vue:34` MAX_DURATION_MS，到点自动 stop + 触发发送回调
/// M-3 兜底 cleanup handle —— @MainActor class 的 deinit 是 nonisolated,不能触碰 @MainActor 字段;
/// 用独立 non-isolated 小 class 承载 recorder + 残留文件句柄,VoiceRecorder deinit 时随之释放触发清理。
///
/// **正常路径**:ChatDetailView.onDisappear 显式调 `voiceRecorder.cancel()`(见 rule 中的 M-3 fix);
/// 本 handle 仅兜底 view/store 意外释放场景(kill / crash restore 前),防止麦克风橙点残留 60s。
private final class VoiceRecorderCleanupHandle {
    var recorder: AVAudioRecorder?
    var fileURL: URL?

    deinit {
        recorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }
}

@MainActor
final class VoiceRecorder: ObservableObject {

    /// 录制中的秒数（UI 显示用；每 100ms 更新）
    @Published private(set) var currentSeconds: Int = 0

    /// 是否正在录制
    @Published private(set) var isRecording: Bool = false

    // MARK: - 私有

    private var recorder: AVAudioRecorder?
    private var tickTask: Task<Void, Never>?
    private var currentFileURL: URL?
    private var startedAt: Date?
    /// M-3 兜底清理句柄 —— 与 recorder/currentFileURL 同步维护,VoiceRecorder 意外释放时随之 deinit 释放麦克风
    private let cleanupHandle = VoiceRecorderCleanupHandle()

    /// 60s 到点自动 stop + 触发 send 的回调（由 ChatDetailView 注入）
    var onAutoStopReachMax: ((URL, Int) -> Void)?

    // MARK: - Public API

    /// 用户按下按钮：请求麦克风权限 + 起录
    func start() {
        guard !isRecording else { return }

        // 请求权限（首次会弹系统 dialog；permission Info.plist NSMicrophoneUsageDescription 已在）
        requestPermissionThenRecord()
    }

    /// 用户松开按钮：停录 + 返 (localFilePath, durSec)。若 <1s 或异常 → 返 nil 并清理文件
    /// - Returns: 有效文件 URL + 时长（秒）；无效返 nil
    @discardableResult
    func stop() -> (url: URL, dur: Int)? {
        guard isRecording else { return nil }
        let dur = Int(Date().timeIntervalSince(startedAt ?? Date()))
        tickTask?.cancel()
        tickTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        currentSeconds = 0
        try? deactivateAudioSession()
        // M-3:主动 stop 已释放麦克风,清空兜底 handle 避免 deinit 二次操作(AVAudioRecorder.stop 幂等但多余)
        cleanupHandle.recorder = nil

        guard let url = currentFileURL, dur >= ChatConstants.voiceMinDurationSec else {
            // 时长过短 → 删除文件
            if let url = currentFileURL { try? FileManager.default.removeItem(at: url) }
            currentFileURL = nil
            cleanupHandle.fileURL = nil
            return nil
        }
        let result = (url, min(dur, ChatConstants.voiceMaxDurationSec))
        currentFileURL = nil   // 转移所有权到 caller
        cleanupHandle.fileURL = nil   // 文件归 caller,不再兜底删
        return result
    }

    /// 用户上滑取消：丢弃 + 删除文件
    func cancel() {
        guard isRecording else { return }
        tickTask?.cancel()
        tickTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        currentSeconds = 0
        try? deactivateAudioSession()
        if let url = currentFileURL { try? FileManager.default.removeItem(at: url) }
        currentFileURL = nil
        // M-3:主动 cancel 已完整清理,清空兜底 handle
        cleanupHandle.recorder = nil
        cleanupHandle.fileURL = nil
    }

    // MARK: - 内部

    private func requestPermissionThenRecord() {
        let session = AVAudioSession.sharedInstance()
        let start: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.startRecordingAfterPermission()
            }
        }
        // iOS 17 API vs iOS 16 API
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                if granted { start() } else { logger.error("mic permission denied") }
            }
        } else {
            session.requestRecordPermission { granted in
                if granted { start() } else { logger.error("mic permission denied") }
            }
        }
    }

    private func startRecordingAfterPermission() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true, options: [])

            let url = try createOutputFileURL()
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.prepareToRecord()
            guard rec.record() else {
                logger.error("record() returned false")
                return
            }

            self.recorder = rec
            self.currentFileURL = url
            self.startedAt = Date()
            self.isRecording = true
            self.currentSeconds = 0
            // M-3:同步到兜底 handle,view 意外释放时 deinit 触发清理
            cleanupHandle.recorder = rec
            cleanupHandle.fileURL = url
            startTick()
        } catch {
            logger.error("startRecording error: \(String(describing: error), privacy: .public)")
        }
    }

    private func startTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 100_000_000)   // 100ms
                if Task.isCancelled { return }
                guard let self, let start = self.startedAt else { return }
                let sec = Int(Date().timeIntervalSince(start))
                // S-5:100ms tick 但 Int 秒仅每 1s 变化,去重避免 10Hz Published emit 引起 ChatDetailView body 无意义重算
                if sec != self.currentSeconds {
                    self.currentSeconds = sec
                }
                if sec >= ChatConstants.voiceMaxDurationSec {
                    // 60s 到点自动停止 + 触发发送
                    if let (url, dur) = self.stop() {
                        self.onAutoStopReachMax?(url, dur)
                    }
                    return
                }
            }
        }
    }

    private func createOutputFileURL() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent("chat/audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).m4a")
    }

    private func deactivateAudioSession() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
