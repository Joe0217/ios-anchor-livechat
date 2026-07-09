import AVFoundation
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "CallAudioSession")

/// C-4 Wave2 gap-critic-004：通话音频会话 + 接近传感器 + 系统电话打断集中管理。
///
/// **iOS 平台强需求**（H5 无对应原语）：
/// - `.playAndRecord` + `.voiceChat` mode + `.defaultToSpeaker` + `.allowBluetooth`：通话专用音频路由
/// - `AVAudioSession.interruptionNotification`：系统来电/闹钟/其他 App 抢占后 pause/resume
/// - `UIDevice.isProximityMonitoringEnabled`：前置摄像头通话时脸贴屏自动黑屏防误触
///
/// **生命周期**：
/// - `activate(...)` 在 CallStore.state 首次进入 `.connecting` 时调（提前于 `.connected` 覆盖被叫场景）
/// - `deactivate()` 在 CallStore.state 转 `.idle` 时调（endLocally → scheduleEndedToIdle 500ms 后）
/// - AudioSession 主动 setActive(false, .notifyOthersOnDeactivation) 释放独占，让系统音乐等 App 恢复
///
/// **与直播私 call 关系**：直播私 call（`frontGameType==.live`）走 LiveStore.pauseForCall + LiveRoomView
/// AudioSession 主导，本 controller 由 CallStore 判定后**不激活**，避免与直播侧 setCategory 冲突。
@MainActor
final class CallAudioSessionController {
    static let shared = CallAudioSessionController()

    private var interruptionObserver: NSObjectProtocol?
    private var onInterruptionBegan: (() -> Void)?
    private var onInterruptionEnded: (() -> Void)?
    private var isActive: Bool = false

    private init() {}

    /// 通话开始时调用（CallStore.state 转 `.connecting` 时）。
    /// - `onInterruptionBegan`：系统来电抢占音频时触发，调用方通常静音 mic
    /// - `onInterruptionEnded`：抢占结束时触发，调用方通常恢复 mic
    func activate(onInterruptionBegan: @escaping () -> Void,
                  onInterruptionEnded: @escaping () -> Void) {
        // 幂等：重复调用不重复挂 observer / 重复 setCategory
        guard !isActive else { return }
        isActive = true

        // AudioSession 配置：通话专用路由（.voiceChat 关闭回声/自适应增益）
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: [])
            logger.info("AudioSession activated: playAndRecord/voiceChat")
        } catch {
            logger.error("AudioSession activate failed: \(String(describing: error))")
        }

        self.onInterruptionBegan = onInterruptionBegan
        self.onInterruptionEnded = onInterruptionEnded

        // 监听系统打断（来电 / 闹钟 / 其他 App 抢占）
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    logger.info("AudioSession interruption began")
                    self.onInterruptionBegan?()
                case .ended:
                    // 系统抢占结束后需要重新 setActive（AVAudioSession API 约定）
                    do { try AVAudioSession.sharedInstance().setActive(true, options: []) }
                    catch { logger.warning("AudioSession re-activate after interruption failed: \(String(describing: error))") }
                    logger.info("AudioSession interruption ended → session re-active")
                    self.onInterruptionEnded?()
                @unknown default: break
                }
            }
        }

        // Proximity：前置摄像头通话时脸贴屏自动黑屏（iOS 系统级）
        UIDevice.current.isProximityMonitoringEnabled = true
    }

    /// 通话结束时调用（CallStore.state 转 `.idle` 时）。幂等。
    func deactivate() {
        guard isActive else { return }
        isActive = false

        UIDevice.current.isProximityMonitoringEnabled = false

        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        onInterruptionBegan = nil
        onInterruptionEnded = nil

        // setActive(false, .notifyOthersOnDeactivation) 让其他 App（如 Music）自动恢复播放
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            logger.info("AudioSession deactivated + notified others")
        } catch {
            logger.warning("AudioSession deactivate failed: \(String(describing: error))")
        }
    }
}
