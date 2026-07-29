import SwiftUI
import UIKit
import AVFoundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LoopingVideoView")

/// 远端 mp4 无缝循环背景视频 SwiftUI 组件（v4 —— code-review 修复合并版）。
///
/// **典型用途**：派对房背景大图（`bigImgUrl` 为 `.mp4` 时）等需要"无缝循环 + aspect fill + 静音 +
/// 首帧就绪回调"的背景视频场景。对齐 H5 `room-bg.vue` 的
/// `<video autoplay loop muted playsinline object-cover>` 语义。
///
/// **本次 code-review 修复**：
/// - **#4** URLSession tempURL 生命周期 UB → 走 `URLDiskCache` 在 delegate queue 同步 move
/// - **#5** 无 HTTP 状态/MIME 校验 → URLDiskCache 内 2xx + `video/` 前缀校验
/// - **#6** `player.status == .failed` 只 log 不清缓存 → 失败时 `URLDiskCache.invalidate` 主动删
/// - **#8** detach 未清 `view.playerLayer.player` → 现在 weak view + detach 里显式清
/// - **#9** `timeControlStatus == .playing` 非严格首帧信号 → 改观察 `AVPlayerLayer.isReadyForDisplay`
/// - **#11** URLSession 无 timeout/retry → URLDiskCache 独立 session 短 timeout + 一次重试
/// - **#13** SHA256 缓存与 YYEVAAnimationPlayer 逐行重复 → 抽 `URLDiskCache` 公共
///
/// **实现要点**：
/// - `AVQueuePlayer + AVPlayerLooper`：AVFoundation 原生无缝循环
/// - `videoGravity = .resizeAspectFill`：等比拉伸 + 中心裁剪，匹配 H5 `object-cover`
/// - `isMuted = true`：**背景视频恒静音**，不干扰直播 / 派对房 RTC 音频路径
/// - **gen 计数器**：URL 变化 / dismantle 时 `&+= 1`；stale download 回来时 gen 不匹配丢弃
/// - **onReady**：`AVPlayerLayer.isReadyForDisplay = true` fire 一次（幂等），供外层 placeholder 淡出
///
/// **生命周期**：`dismantleUIView` 由 SwiftUI 精确清理（对齐 `.claude/rules/swiftui-camera-preview.md` §3）。
struct LoopingVideoView: UIViewRepresentable {
    let url: URL?
    /// 背景视频默认静音；权益全屏预览可显式打开原始音轨。
    var isMuted: Bool = true
    var onReady: (() -> Void)? = nil

    /// URLDiskCache namespace（与 YYEVACache 隔离）
    static let cacheNamespace = "PartyBGCache"

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        context.coordinator.attach(view: v, url: url, isMuted: isMuted, onReady: onReady)
        return v
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        context.coordinator.update(url: url, isMuted: isMuted, onReady: onReady)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// override `layerClass` 让 `view.layer` 本身就是 `AVPlayerLayer`——尺寸自动跟随 view.bounds。
    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    @MainActor
    final class Coordinator {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        /// weak view 引用：detach 时可以显式 nil playerLayer.player（#8 修复）
        private weak var containerView: PlayerContainerView?
        private var currentURLStr: String = ""
        /// 已缓存本地文件的远端源 URL（用于 .failed 时 invalidate 缓存）
        private var currentRemoteURL: URL?
        /// 观察 AVPlayerLayer.isReadyForDisplay（真首帧信号）
        private var readyObservation: NSKeyValueObservation?
        /// 观察 player.status（.failed 时清缓存）
        private var playerStatusObservation: NSKeyValueObservation?
        private var onReadyFired = false
        private var onReady: (() -> Void)?
        /// gen 计数：URL 变化 / dismantle 时自增，stale async task 通过 gen 对比丢弃
        private var currentGen: Int = 0
        private var loadTask: Task<Void, Never>?
        /// AVPlayer 在 app 切后台被系统 pause，回前台需显式 play() 恢复
        private var foregroundObserver: NSObjectProtocol?

        func attach(view: PlayerContainerView, url: URL?, isMuted: Bool, onReady: (() -> Void)?) {
            let player = AVQueuePlayer()
            player.isMuted = isMuted
            // Looper 推入 duplicate item 无缝循环；.advance 避免 item 结束时 SDK 暂停
            player.actionAtItemEnd = .advance
            view.playerLayer.player = player
            view.playerLayer.videoGravity = .resizeAspectFill
            self.player = player
            self.containerView = view
            self.onReady = onReady
            installForegroundObserver()
            load(url: url)
        }

        func update(url: URL?, isMuted: Bool, onReady: (() -> Void)?) {
            self.onReady = onReady
            player?.isMuted = isMuted
            let newStr = url?.absoluteString ?? ""
            guard newStr != currentURLStr else { return }
            load(url: url)
        }

        func detach() {
            currentGen &+= 1
            loadTask?.cancel()
            loadTask = nil
            readyObservation?.invalidate()
            readyObservation = nil
            playerStatusObservation?.invalidate()
            playerStatusObservation = nil
            looper?.disableLooping()
            looper = nil
            player?.pause()
            player?.removeAllItems()
            player = nil
            // #8 修复：nil 掉 layer.player，避免 CALayer 强引延迟释放硬件解码器
            containerView?.playerLayer.player = nil
            containerView = nil
            currentRemoteURL = nil
            removeForegroundObserver()
        }

        // MARK: - foreground resume

        private func installForegroundObserver() {
            guard foregroundObserver == nil else { return }
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.resumePlaybackIfNeeded() }
            }
        }

        private func removeForegroundObserver() {
            if let obs = foregroundObserver {
                NotificationCenter.default.removeObserver(obs)
                foregroundObserver = nil
            }
        }

        private func resumePlaybackIfNeeded() {
            guard let player else { return }
            // 系统在后台自动 pause AVPlayer,回前台需显式 play() 恢复循环播放
            if player.timeControlStatus != .playing {
                player.play()
                logger.info("foreground resume: player.play()")
            }
        }

        // MARK: - load

        private func load(url: URL?) {
            currentGen &+= 1
            let gen = currentGen
            loadTask?.cancel()
            loadTask = nil
            readyObservation?.invalidate()
            readyObservation = nil
            playerStatusObservation?.invalidate()
            playerStatusObservation = nil
            looper?.disableLooping()
            looper = nil
            onReadyFired = false
            player?.removeAllItems()
            currentRemoteURL = nil

            guard let url else {
                currentURLStr = ""
                return
            }
            currentURLStr = url.absoluteString
            logger.info("load url=\(url.absoluteString, privacy: .public)")

            // 本地 file:// 直接播（PartyBGCache hit / 测试路径）
            if url.isFileURL {
                playLocal(fileURL: url, gen: gen)
                return
            }

            // 远端：走 URLDiskCache（同步 move + HTTP 校验 + 短 timeout + 一次重试）
            currentRemoteURL = url
            loadTask = Task { @MainActor [weak self] in
                do {
                    let localPath = try await URLDiskCache.fetch(
                        url: url,
                        namespace: LoopingVideoView.cacheNamespace,
                        expectedMIMEPrefix: "video/"
                    )
                    guard let self, self.currentGen == gen else {
                        logger.info("load stale gen (cur=\(self?.currentGen ?? -1, privacy: .public) my=\(gen, privacy: .public)), drop")
                        return
                    }
                    self.playLocal(fileURL: localPath, gen: gen)
                } catch {
                    logger.warning("URLDiskCache.fetch failed url=\(url.absoluteString, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                }
            }
        }

        private func playLocal(fileURL: URL, gen: Int) {
            guard currentGen == gen, let player, let containerView else {
                logger.info("playLocal skipped: currentGen=\(self.currentGen, privacy: .public) my=\(gen, privacy: .public) player=\(self.player == nil ? "nil" : "ok", privacy: .public)")
                return
            }
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? -1
            logger.info("playLocal start file=\(fileURL.path, privacy: .public) size=\(fileSize, privacy: .public)")
            let item = AVPlayerItem(url: fileURL)

            // v4 关键修复（code-review #9）：**观察 AVPlayerLayer.isReadyForDisplay** 而非
            // `player.timeControlStatus`。`.playing` 可能在 layer 首帧 draw 前 1-2 帧提前 fire，
            // 导致 placeholder 淡出瞬间用户看到黑闪。`isReadyForDisplay = true` 是"首帧已可见"
            // 的严格信号 —— Apple 官方推荐用来判定视频首帧就绪。
            readyObservation = containerView.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let ready = layer.isReadyForDisplay
                    logger.info("playerLayer isReadyForDisplay=\(ready, privacy: .public)")
                    if ready {
                        guard !self.onReadyFired else { return }
                        self.onReadyFired = true
                        self.onReady?()
                    }
                }
            }
            // player.status 独立观察：`.failed` 时清缓存 + log（code-review #6）
            playerStatusObservation = player.observe(\.status, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if player.status == .failed {
                        logger.warning("player status=failed error=\(String(describing: player.error), privacy: .public)")
                        // 清掉可能损坏的缓存文件，让下次进房重新拉
                        if let remote = self.currentRemoteURL {
                            URLDiskCache.invalidate(url: remote, namespace: LoopingVideoView.cacheNamespace)
                        }
                    }
                }
            }

            looper = AVPlayerLooper(player: player, templateItem: item)
            player.play()
            logger.info("playLocal player.play() called")
        }
    }
}
