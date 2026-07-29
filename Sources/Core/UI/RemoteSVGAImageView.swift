import SwiftUI
import UIKit
import SVGAPlayer
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "RemoteSVGAImageView")

/// 远端 URL SVGA 循环动画 SwiftUI 组件（对齐 H5 `head-frame.vue` 逻辑）。
///
/// **与 PKSVGAPlayerView 的区别**：
/// - PKSVGAPlayerView：**bundle-local 资源** + **一次性播放**（PK 结果动画）
/// - RemoteSVGAImageView：**远端 URL** + **无限循环**（头像装饰框、荣耀勋章等长期展示元素）
///
/// **与 SVGAAnimationPlayer 的区别**：
/// - SVGAAnimationPlayer：礼物特效 pipeline（GiftEffectItem 一次性播 + onFinish）
/// - RemoteSVGAImageView：SwiftUI Representable，随 view 生命周期自动播放/停止
///
/// **NSCache 复用**：同 URL 的 SVGAVideoEntity 跨实例共享（同一装饰框多处使用 / 用户反复进房只解析一次）。
///
/// 用法：
/// ```swift
/// RemoteSVGAImageView(url: URL(string: user.headFrame))
///     .frame(width: 55, height: 55)
///     .allowsHitTesting(false)
/// ```
struct RemoteSVGAImageView: UIViewRepresentable {
    let url: URL?
    /// SVGAPlayer.loops：`0` = 无限循环；`n>0` = 播 n 次后 stop
    var loops: Int = 0
    /// false 时保留已解析资源但暂停动画，用于预加载后按业务状态再显示。
    var isPlaying: Bool = true
    var contentMode: UIView.ContentMode = .scaleAspectFit
    /// 首次 `startAnimation()` 调用后回调（幂等）。用于外层 placeholder 淡出等就绪信号。
    /// 对齐 H5 `room-bg.vue` 的 `!svgaIsPlaying` 判定，同一 URL 只 fire 一次。
    var onFirstPlay: (() -> Void)? = nil
    /// 当前 URL 解析失败时回调（同一 URL 只触发一次）。调用方可退回静态图或默认动效。
    var onLoadFailure: (() -> Void)? = nil
    /// 当前 URL 成功解析并开始播放时回调（同一 URL 只触发一次）。
    var onLoadSuccess: (() -> Void)? = nil
    /// 单次播放完成回调。循环播放（`loops == 0`）不会触发，用于阶段奖励等短动画串联。
    var onFinished: (() -> Void)? = nil

    /// 静态 NSCache：跨实例复用同 URL 的解析结果（对齐 SVGAAnimationPlayer.videoEntityCache 思路）。
    /// countLimit 20 覆盖主播端派对房内可能同时展示的装饰框数量（房主 1 + 麦位 12 + 榜单动画 3 等）。
    static let videoEntityCache: NSCache<NSString, SVGAVideoEntity> = {
        let c = NSCache<NSString, SVGAVideoEntity>()
        c.countLimit = 20
        return c
    }()

    func makeUIView(context: Context) -> SVGAPlayer {
        let player = SVGAPlayer(frame: .zero)
        player.contentMode = contentMode
        player.loops = Int32(loops)
        player.clearsAfterStop = true
        player.backgroundColor = .clear
        context.coordinator.player = player
        context.coordinator.onFinished = onFinished
        player.delegate = context.coordinator
        loadAndPlay(player: player, coordinator: context.coordinator)
        return player
    }

    func updateUIView(_ uiView: SVGAPlayer, context: Context) {
        context.coordinator.onFinished = onFinished
        let newURLStr = url?.absoluteString ?? ""
        if context.coordinator.loadedURLStr != newURLStr {
            // URL 变化：停旧动画 + 加载新（对齐 H5 head-frame.vue destroySvgaPlayer + rebuild）
            uiView.stopAnimation()
            uiView.clear()
            uiView.loops = Int32(loops)
            uiView.contentMode = contentMode
            loadAndPlay(player: uiView, coordinator: context.coordinator)
        } else if context.coordinator.isPlaying != isPlaying {
            context.coordinator.isPlaying = isPlaying
            updatePlayback(player: uiView, coordinator: context.coordinator)
        }
    }

    static func dismantleUIView(_ uiView: SVGAPlayer, coordinator: Coordinator) {
        // view 消亡时清 Player（对齐 H5 onUnmounted destroySvgaPlayer）
        uiView.stopAnimation()
        uiView.clear()
        uiView.delegate = nil
        // 让所有 in-flight parse callback 失效
        coordinator.currentGen &+= 1
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadAndPlay(player: SVGAPlayer, coordinator: Coordinator) {
        guard let url else {
            coordinator.loadedURLStr = ""
            return
        }
        let urlStr = url.absoluteString
        coordinator.loadedURLStr = urlStr
        coordinator.isPlaying = isPlaying
        coordinator.currentGen &+= 1
        let myGen = coordinator.currentGen

        // NSCache 命中：直接复用 videoItem 跳过 parse 网络+解压+解码开销
        if let cached = Self.videoEntityCache.object(forKey: urlStr as NSString) {
            player.videoItem = cached
            updatePlayback(player: player, coordinator: coordinator)
            fireLoadSuccessIfNeeded(coordinator: coordinator, expectedGeneration: myGen)
            fireFirstPlayIfNeeded(coordinator: coordinator)
            return
        }

        let parser = SVGAParser()
        parser.parse(with: url) { [weak player] videoItem in
            DispatchQueue.main.async {
                // gen 校验：URL 变化 / view dismantle 期间 in-flight callback 到 → 丢弃
                guard coordinator.currentGen == myGen,
                      let player, let videoItem else {
                    return
                }
                Self.videoEntityCache.setObject(videoItem, forKey: urlStr as NSString)
                player.videoItem = videoItem
                self.updatePlayback(player: player, coordinator: coordinator)
                self.fireLoadSuccessIfNeeded(coordinator: coordinator, expectedGeneration: myGen)
                self.fireFirstPlayIfNeeded(coordinator: coordinator)
            }
        } failureBlock: { [self] error in
            logger.warning("SVGA parse fail url=\(urlStr, privacy: .private) err=\(String(describing: error), privacy: .private)")
            DispatchQueue.main.async {
                self.fireLoadFailureIfNeeded(coordinator: coordinator, expectedGeneration: myGen)
            }
            // v18 修复（code-review #10）：解析失败时也 fire "ready" —— 让外层 placeholder 淡出，
            // 避免 placeholder 永久盖住（对齐 H5 用户端 <video> 加载失败仍触发 canplay=false → 不阻塞）。
            // 上层的 fallback UX 语义：SVGA 显不出来时应露出下层（用户看到透明或 default 兜底），
            // 而不是让 placeholder 静态图误导用户"以为动图播出但不动"。
            DispatchQueue.main.async {
                self.fireFirstPlayIfNeeded(coordinator: coordinator)
            }
        }
    }

    private func updatePlayback(player: SVGAPlayer, coordinator: Coordinator) {
        guard player.videoItem != nil else { return }
        if coordinator.isPlaying {
            player.startAnimation()
        } else {
            player.stopAnimation()
        }
    }

    /// 同一 URL 只 fire 一次（幂等）；URL 变化时 `loadAndPlay` 会 `currentGen &+= 1`，
    /// `firstPlayFiredGen` 与 `currentGen` 对比重新允许 fire。
    /// **必须 async dispatch**：cache hit 路径下本方法从 `makeUIView` / `updateUIView` 同步调用，
    /// 直接 fire 若触发 caller `@State` 变更会撞 SwiftUI "Modifying state during view update" 警告。
    private func fireFirstPlayIfNeeded(coordinator: Coordinator) {
        guard coordinator.firstPlayFiredGen != coordinator.currentGen else { return }
        let gen = coordinator.currentGen
        DispatchQueue.main.async {
            guard coordinator.currentGen == gen,
                  coordinator.firstPlayFiredGen != gen else { return }
            coordinator.firstPlayFiredGen = gen
            self.onFirstPlay?()
        }
    }

    private func fireLoadFailureIfNeeded(coordinator: Coordinator, expectedGeneration: Int) {
        guard coordinator.currentGen == expectedGeneration,
              coordinator.loadFailureFiredGen != expectedGeneration else { return }
        coordinator.loadFailureFiredGen = expectedGeneration
        onLoadFailure?()
    }

    private func fireLoadSuccessIfNeeded(coordinator: Coordinator, expectedGeneration: Int) {
        // 缓存命中路径会在 makeUIView/updateUIView 同步触发；异步派发避免调用方写
        // SwiftUI @State 时出现 "Modifying state during view update"。
        DispatchQueue.main.async {
            guard coordinator.currentGen == expectedGeneration,
                  coordinator.loadSuccessFiredGen != expectedGeneration else { return }
            coordinator.loadSuccessFiredGen = expectedGeneration
            self.onLoadSuccess?()
        }
    }

    final class Coordinator: NSObject, SVGAPlayerDelegate {
        /// 已发起 parse 的 URL 字符串（用来判 updateUIView 时 URL 是否变化）
        var loadedURLStr: String = ""
        /// generation 计数：URL 变化 / dismantle 时自增；parse callback 检查 gen 不匹配丢弃
        var currentGen: Int = 0
        /// onFirstPlay 已 fire 的 gen（-1 = 从未 fire）；仅 `firstPlayFiredGen != currentGen` 才允许再 fire
        var firstPlayFiredGen: Int = -1
        /// onLoadFailure 已 fire 的 gen；避免解析器重复失败回调导致上层重复写 State。
        var loadFailureFiredGen: Int = -1
        /// onLoadSuccess 已 fire 的 gen；缓存命中和网络解析成功都只通知一次。
        var loadSuccessFiredGen: Int = -1
        /// 当前业务层是否允许动画播放；资源仍可在 false 时下载和解析。
        var isPlaying: Bool = true
        var onFinished: (() -> Void)?
        /// weak 引用当前 SVGAPlayer,供 foreground observer 回前台时恢复动画
        weak var player: SVGAPlayer?
        /// SVGAPlayer 内部 CADisplayLink 在 app 后台被系统暂停,回前台需显式 startAnimation() 恢复
        private var foregroundObserver: NSObjectProtocol?

        override init() {
            super.init()
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let player = self.player else { return }
                // videoItem 尚未加载完成时 startAnimation 无副作用;已加载且业务允许时恢复。
                if self.isPlaying, player.videoItem != nil {
                    player.startAnimation()
                    logger.info("foreground resume: startAnimation()")
                }
            }
        }

        deinit {
            if let obs = foregroundObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func svgaPlayerDidFinishedAnimation(_ player: SVGAPlayer!) {
            onFinished?()
        }
    }
}
