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
    var contentMode: UIView.ContentMode = .scaleAspectFit
    /// 首次 `startAnimation()` 调用后回调（幂等）。用于外层 placeholder 淡出等就绪信号。
    /// 对齐 H5 `room-bg.vue` 的 `!svgaIsPlaying` 判定，同一 URL 只 fire 一次。
    var onFirstPlay: (() -> Void)? = nil

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
        loadAndPlay(player: player, coordinator: context.coordinator)
        return player
    }

    func updateUIView(_ uiView: SVGAPlayer, context: Context) {
        let newURLStr = url?.absoluteString ?? ""
        if context.coordinator.loadedURLStr != newURLStr {
            // URL 变化：停旧动画 + 加载新（对齐 H5 head-frame.vue destroySvgaPlayer + rebuild）
            uiView.stopAnimation()
            uiView.clear()
            uiView.loops = Int32(loops)
            uiView.contentMode = contentMode
            loadAndPlay(player: uiView, coordinator: context.coordinator)
        }
    }

    static func dismantleUIView(_ uiView: SVGAPlayer, coordinator: Coordinator) {
        // view 消亡时清 Player（对齐 H5 onUnmounted destroySvgaPlayer）
        uiView.stopAnimation()
        uiView.clear()
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
        coordinator.currentGen &+= 1
        let myGen = coordinator.currentGen

        // NSCache 命中：直接复用 videoItem 跳过 parse 网络+解压+解码开销
        if let cached = Self.videoEntityCache.object(forKey: urlStr as NSString) {
            player.videoItem = cached
            player.startAnimation()
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
                player.startAnimation()
                self.fireFirstPlayIfNeeded(coordinator: coordinator)
            }
        } failureBlock: { [self] error in
            logger.warning("SVGA parse fail url=\(urlStr, privacy: .private) err=\(String(describing: error), privacy: .private)")
            // v18 修复（code-review #10）：解析失败时也 fire "ready" —— 让外层 placeholder 淡出，
            // 避免 placeholder 永久盖住（对齐 H5 用户端 <video> 加载失败仍触发 canplay=false → 不阻塞）。
            // 上层的 fallback UX 语义：SVGA 显不出来时应露出下层（用户看到透明或 default 兜底），
            // 而不是让 placeholder 静态图误导用户"以为动图播出但不动"。
            DispatchQueue.main.async {
                self.fireFirstPlayIfNeeded(coordinator: coordinator)
            }
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

    final class Coordinator {
        /// 已发起 parse 的 URL 字符串（用来判 updateUIView 时 URL 是否变化）
        var loadedURLStr: String = ""
        /// generation 计数：URL 变化 / dismantle 时自增；parse callback 检查 gen 不匹配丢弃
        var currentGen: Int = 0
        /// onFirstPlay 已 fire 的 gen（-1 = 从未 fire）；仅 `firstPlayFiredGen != currentGen` 才允许再 fire
        var firstPlayFiredGen: Int = -1
    }
}
