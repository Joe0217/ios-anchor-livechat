import AVFoundation
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "CallAudioSession")

/// C-4 Wave2 gap-critic-004：通话音频会话 + 系统电话打断集中管理。
///
/// **iOS 平台强需求**（H5 无对应原语）：
/// - `.playAndRecord` + `.voiceChat` mode + `.defaultToSpeaker` + `.allowBluetooth`：通话专用音频路由
/// - `AVAudioSession.interruptionNotification`：系统来电/闹钟/其他 App 抢占后 pause/resume
/// - 视频通话始终关闭 `UIDevice.isProximityMonitoringEnabled`，不能因遮挡听筒而黑屏或禁用触控
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

    private init() {
        // 本产品仅支持视频通话，不使用电话听筒贴脸场景的系统防误触。
        UIDevice.current.isProximityMonitoringEnabled = false
    }

    /// 通话开始时调用（CallStore.state 转 `.connecting` 时）。
    /// - `onInterruptionBegan`：系统来电抢占音频时触发，调用方通常静音 mic
    /// - `onInterruptionEnded`：抢占结束时触发，调用方通常恢复 mic
    func activate(onInterruptionBegan: @escaping () -> Void,
                  onInterruptionEnded: @escaping () -> Void) {
        // 幂等：重复调用不重复挂 observer / 重复 setCategory
        guard !isActive else { return }
        isActive = true
        // 任何通话生命周期都不能启用听筒遮挡黑屏。
        UIDevice.current.isProximityMonitoringEnabled = false

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

/// App 内短音效（来电铃声与前台消息提示）的统一控制器。
///
/// 音效资源与 H5 主播端保持一致，通过 CDN 按需缓存，避免将远程资源混入工程资源配置。
/// 通话建立后的音频会话仍由 `CallAudioSessionController` 管理；本控制器只在空闲或来电等待期使用
/// `.playback`，因此不抢占 RTC 的 `.playAndRecord` 会话。
@MainActor
final class AppSoundPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AppSoundPlayer()

    private enum Sound: CaseIterable, Hashable {
        case incomingCall
        case notification

        var url: URL {
            switch self {
            case .incomingCall:
                return URL(string: "https://img.hnhily.link/audio/waitAudio.mp3")!
            case .notification:
                return URL(string: "https://img.hnhily.link/audio/ding.mp3")!
            }
        }

        var logName: String {
            switch self {
            case .incomingCall: return "incoming_call"
            case .notification: return "notification"
            }
        }
    }

    private var soundData: [Sound: Data] = [:]
    private var loadingSounds = Set<Sound>()
    private var ringtonePlayer: AVAudioPlayer?
    private var notificationPlayer: AVAudioPlayer?
    private var isRingtoneRequested = false
    private var isNotificationRequested = false

    private override init() {
        super.init()
    }

    /// 登录后的通话 Store 初始化时预热，第一次来电不必等待网络下载。
    func preload() {
        Sound.allCases.forEach(loadIfNeeded)
    }

    func startIncomingCallRingtone() {
        guard UIApplication.shared.applicationState == .active else { return }
        isRingtoneRequested = true
        logger.info("Incoming ringtone requested")
        playRingtoneIfReady()
        loadIfNeeded(.incomingCall)
    }

    func stopIncomingCallRingtone() {
        isRingtoneRequested = false
        ringtonePlayer?.stop()
        ringtonePlayer = nil
        deactivatePlaybackSessionIfUnused()
    }

    func playNotificationTone() {
        guard UIApplication.shared.applicationState == .active,
              !isRingtoneRequested,
              CallStore.shared.state == .idle else {
            return
        }
        isNotificationRequested = true
        logger.debug("Notification tone requested")
        playNotificationIfReady()
        loadIfNeeded(.notification)
    }

    func handleApplicationDidEnterBackground() {
        stopIncomingCallRingtone()
        isNotificationRequested = false
        notificationPlayer?.stop()
        notificationPlayer = nil
        deactivatePlaybackSessionIfUnused()
    }

    func handleApplicationDidBecomeActive(isIncomingCallWaiting: Bool) {
        guard isIncomingCallWaiting else { return }
        startIncomingCallRingtone()
    }

    private func loadIfNeeded(_ sound: Sound) {
        guard soundData[sound] == nil, !loadingSounds.contains(sound) else { return }
        loadingSounds.insert(sound)

        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: sound.url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      !data.isEmpty else {
                    logger.warning("Sound download returned an invalid response")
                    self?.loadingSounds.remove(sound)
                    return
                }
                guard let self else { return }
                self.soundData[sound] = data
                self.loadingSounds.remove(sound)
                logger.info("Sound asset loaded kind=\(sound.logName, privacy: .public) bytes=\(data.count, privacy: .public)")
                switch sound {
                case .incomingCall:
                    self.playRingtoneIfReady()
                case .notification:
                    self.playNotificationIfReady()
                }
            } catch {
                self?.loadingSounds.remove(sound)
                logger.warning("Sound download failed: \(String(describing: error))")
            }
        }
    }

    private func playRingtoneIfReady() {
        guard isRingtoneRequested,
              UIApplication.shared.applicationState == .active,
              ringtonePlayer == nil,
              let data = soundData[.incomingCall] else {
            return
        }
        do {
            try activatePlaybackSession()
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            player.volume = 1
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                logger.warning("Incoming ringtone failed to start")
                return
            }
            ringtonePlayer = player
            logger.info("Incoming ringtone started")
        } catch {
            logger.warning("Incoming ringtone setup failed: \(String(describing: error))")
        }
    }

    private func playNotificationIfReady() {
        guard isNotificationRequested,
              UIApplication.shared.applicationState == .active,
              !isRingtoneRequested,
              CallStore.shared.state == .idle,
              notificationPlayer == nil,
              let data = soundData[.notification] else {
            return
        }
        isNotificationRequested = false
        do {
            try activatePlaybackSession()
            let player = try AVAudioPlayer(data: data)
            player.volume = 1
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                logger.warning("Notification tone failed to start")
                deactivatePlaybackSessionIfUnused()
                return
            }
            notificationPlayer = player
            logger.debug("Notification tone started")
        } catch {
            logger.warning("Notification tone setup failed: \(String(describing: error))")
            deactivatePlaybackSessionIfUnused()
        }
    }

    private func activatePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        // H5 的 <audio> 走媒体播放通道，不受 iPhone 静音键影响。原先 `.ambient` 会被静音键
        // 完全抑制，造成来电和消息都没有声音；原生这里用同样的 `.playback` 语义。
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func deactivatePlaybackSessionIfUnused() {
        guard ringtonePlayer == nil,
              notificationPlayer == nil,
              CallStore.shared.state == .idle else {
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            logger.warning("Playback audio session deactivate failed: \(String(describing: error))")
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if player === self.notificationPlayer {
                self.notificationPlayer = nil
                if self.isNotificationRequested {
                    self.playNotificationIfReady()
                } else {
                    self.deactivatePlaybackSessionIfUnused()
                }
            }
        }
    }
}
