import AVFoundation
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "AudioPlayer")

/// 语音消息播放器（H-2 spec §4，对齐 H5 `msgItem.vue:262-268`）。
///
/// **单例语义**：全局同一时刻只播一条语音（tap 新消息时自动 stop 旧的，符合 iM 心智模型）。
/// **URL 支持**：CDN https URL —— AVPlayer 内部下载并缓存；短音频 <64K 通常 <1s 完成。
/// **播完自动 stop**：AVAudioPlayerDelegate.audioPlayerDidFinishPlaying 触发。
@MainActor
final class ChatAudioPlayer: NSObject, ObservableObject {

    static let shared = ChatAudioPlayer()

    /// 当前播放中的消息 key（`clientMsgId ?? messageId`）；nil 表示无播放
    @Published private(set) var playingKey: String?

    private var player: AVAudioPlayer?
    /// AVPlayer 数据回调用；预取到内存的 downloader
    private var downloadTask: URLSessionDataTask?

    private override init() { super.init() }

    /// tap 语音气泡触发。同一 key 再 tap → 停止；新 key → 停旧起新
    func toggle(url: URL, key: String) {
        if playingKey == key {
            stop()
            return
        }
        stop()   // 停旧
        play(url: url, key: key)
    }

    func stop() {
        player?.stop()
        player = nil
        downloadTask?.cancel()
        downloadTask = nil
        playingKey = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - 内部

    private func play(url: URL, key: String) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("audio session activate failed: \(String(describing: error), privacy: .public)")
        }

        // 本地文件（用户自己刚录的临时预览路径）直接播；远端 URL 走下载
        if url.isFileURL {
            startPlaybackFromFile(url: url, key: key)
        } else {
            downloadAndPlay(url: url, key: key)
        }
    }

    private func startPlaybackFromFile(url: URL, key: String) {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            guard p.prepareToPlay(), p.play() else {
                logger.error("prepareToPlay/play returned false")
                return
            }
            self.player = p
            self.playingKey = key
        } catch {
            logger.error("startPlayback error: \(String(describing: error), privacy: .public)")
        }
    }

    private func downloadAndPlay(url: URL, key: String) {
        // 小音频 <100KB，一次性拉全后 AVAudioPlayer(data:) 播放；节省流媒体缓冲复杂度
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            Task { @MainActor [weak self] in
                guard let self, let data, error == nil else {
                    logger.error("audio download failed: \(String(describing: error), privacy: .public)")
                    return
                }
                do {
                    let p = try AVAudioPlayer(data: data)
                    p.delegate = self
                    guard p.prepareToPlay(), p.play() else { return }
                    self.player = p
                    self.playingKey = key
                } catch {
                    logger.error("AVAudioPlayer init error: \(String(describing: error), privacy: .public)")
                }
            }
        }
        self.downloadTask = task
        task.resume()
    }
}

// MARK: - AVAudioPlayerDelegate

extension ChatAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            logger.error("decode error: \(String(describing: error), privacy: .public)")
            self?.stop()
        }
    }
}
