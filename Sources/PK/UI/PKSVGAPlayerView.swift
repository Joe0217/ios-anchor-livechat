import SwiftUI
import UIKit
import SVGAPlayer
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PKSVGAPlayerView")

/// PK 场景 SVGA 动画 SwiftUI 包装（CDN-only）。
///
/// **为什么不复用 `SVGAAnimationPlayer`**：那个基于 `GiftEffectItem.animationUrl` (远端 URL)
/// + 单例复用 + 缓存池，PK 动画是本地 bundle 资源 + 短生命周期一次性播放，模型不同。
///
/// **用法**：
/// ```swift
/// PKSVGAPlayerView(resource: "pk-result-win", loops: 1, onFinish: { ... })
///     .frame(width: 300, height: 300)
/// ```
///
/// **loops 语义**：`SVGAPlayer.loops = Int32` — `0` = 无限循环；`1` = 播 1 次后 stop。
/// `onFinish` 只在 loops>0 有限次数播完时 fire，无限循环时永远不 fire。
struct PKSVGAPlayerView: UIViewRepresentable {
    let resource: String
    var loops: Int = 1
    var contentMode: UIView.ContentMode = .scaleAspectFit
    var onFinish: (() -> Void)? = nil

    func makeUIView(context: Context) -> SVGAPlayer {
        let player = SVGAPlayer(frame: .zero)
        player.contentMode = contentMode
        player.loops = Int32(loops)
        player.clearsAfterStop = true
        player.delegate = context.coordinator
        player.backgroundColor = .clear
        loadAndPlay(player: player, context: context)
        return player
    }

    func updateUIView(_ uiView: SVGAPlayer, context: Context) {
        // `resource` 变化时重新加载（少见场景，本组件通常固定 resource 单次播放）
        if context.coordinator.currentResource != resource {
            uiView.stopAnimation()
            uiView.loops = Int32(loops)
            loadAndPlay(player: uiView, context: context)
        }
    }

    static func dismantleUIView(_ uiView: SVGAPlayer, coordinator: Coordinator) {
        uiView.stopAnimation()
        uiView.delegate = nil
        coordinator.loadTask?.cancel()
        coordinator.generation &+= 1
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    private func loadAndPlay(player: SVGAPlayer, context: Context) {
        context.coordinator.loadTask?.cancel()
        context.coordinator.currentResource = resource
        context.coordinator.generation &+= 1
        let generation = context.coordinator.generation
        let coordinator = context.coordinator

        coordinator.loadTask = Task { [weak player] in
            let cdnURL = CDNAssetURL.svgaURL(resource: resource)
            let downloadedURL: URL?
            if let cdnURL {
                downloadedURL = try? await URLDiskCache.fetch(
                    url: cdnURL,
                    namespace: URLDiskCache.publicAssetNamespace,
                    maximumCacheBytes: URLDiskCache.publicAssetCacheLimit
                )
            } else {
                downloadedURL = nil
            }
            guard !Task.isCancelled, coordinator.generation == generation else { return }

            guard let downloadedURL else {
                logger.warning("SVGA CDN resource unavailable: \(resource, privacy: .public)")
                coordinator.finishIfCurrent(generation)
                return
            }
            Self.parse(downloadedURL, resource: resource, player: player, coordinator: coordinator, generation: generation)
        }
    }

    private static func parse(
        _ url: URL,
        resource: String,
        player: SVGAPlayer?,
        coordinator: Coordinator,
        generation: Int
    ) {
        let parser = SVGAParser()
        parser.parse(with: url) { [weak player] videoItem in
            DispatchQueue.main.async {
                guard coordinator.generation == generation, let player, let videoItem else {
                    logger.warning("SVGA parse failed: \(resource, privacy: .public)")
                    coordinator.finishIfCurrent(generation)
                    return
                }
                player.videoItem = videoItem
                player.startAnimation()
            }
        } failureBlock: { error in
            logger.warning("SVGA parse error \(resource, privacy: .public): \(String(describing: error), privacy: .private)")
            DispatchQueue.main.async {
                coordinator.finishIfCurrent(generation)
            }
        }
    }

    /// Delegate 承接 finish 回调（SVGAPlayerDelegate 是 OC protocol，需 NSObject 桥接）
    final class Coordinator: NSObject, SVGAPlayerDelegate {
        var currentResource: String = ""
        var generation: Int = 0
        var loadTask: Task<Void, Never>?
        let onFinish: (() -> Void)?

        init(onFinish: (() -> Void)?) {
            self.onFinish = onFinish
        }

        func svgaPlayerDidFinishedAnimation(_ player: SVGAPlayer!) {
            onFinish?()
        }

        func finishIfCurrent(_ generation: Int) {
            guard self.generation == generation else { return }
            onFinish?()
        }

        deinit { loadTask?.cancel() }
    }
}
