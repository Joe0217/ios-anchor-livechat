import SwiftUI
import UIKit
import SVGAPlayer
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PartyEmojiSVGA")

/// 派对房麦位 emoji SVGA 播放层（F 里程碑 · 2026-07-17）。
///
/// **职责**：观察 `PartyStore.emojiQueueMap[seatUserId]` 队首 → 播 SVGA 一次 → 播完 dequeue →
/// 队列非空自动播下一个 · 队列空隐藏。
///
/// **与既有 SVGA 组件的区别**（[prefer-shared-component-over-adhoc] preflight 结论）：
/// - `RemoteSVGAImageView`：**无限循环**（头像装饰框），不合适 emoji 单段播完
/// - `SVGAAnimationPlayer`：**GiftEffectCenter 独占**（礼物 pipeline），抢占礼物动画
/// - `PKSVGAPlayerView`：**bundle-local 资源**（PK 结果动画），URL 场景不适配
/// 故新建：融合 RemoteSVGAImageView 的 URL 加载 + loops=1 + onFinish 幂等派发。
///
/// **播放策略**：
/// - `.loops = 1`：播一次
/// - `.clearsAfterStop = false`：末帧定格（H5 侧确认 SVGA 资源末尾自带定格帧 · UI 视觉平滑到下一个入队）
/// - `.id(head.uuid)` 强制 SwiftUI 每次 payload 切换重建 UIView · 避免 SVGAPlayer 复用状态错乱
struct PartyEmojiSVGAOverlay: View {
    @ObservedObject private var store = PartyStore.shared
    @ObservedObject private var giftEffects = PartyGiftEffectCoordinator.shared

    /// 该 overlay 挂靠的 seat 上用户 id（nil = 空位 · 不播）
    let seatUserId: String?

    var body: some View {
        Group {
            if let userId = seatUserId,
               !userId.isEmpty,
               !giftEffects.isShowingReceiverGift(for: userId),
               let head = store.emojiQueueMap[userId]?.first {
                PartyEmojiSVGAPlayerView(
                    payload: head,
                    onFinish: { store.dequeueEmoji(seatUserId: userId, expected: head) }
                )
                .id(head.uuid)   // uuid 变化触发 UIView 重建
                .allowsHitTesting(false)   // 覆盖层不拦截点击（保留 seat cell 原 tap）
                .accessibilityHidden(true)
            }
        }
    }
}

/// 单段 SVGA 播放器（URL + loops=1 + onFinish 幂等派发）。私有 · 由 `PartyEmojiSVGAOverlay` 驱动。
///
/// **不做**：
/// - 无限循环（用 `RemoteSVGAImageView`）
/// - URL 复用检测（`.id(head.uuid)` 层已保证每次都是新 UIView · 简化 updateUIView 逻辑）
/// - 前后台切换 resume（SVGAPlayer 内部 CADisplayLink 后台暂停 · 回前台 SwiftUI ForEach id 变化时会重新
///   dispatch · emoji 单段场景 <5s · 用户切后台 5s 内的 emoji 直接跳过语义合理）
private struct PartyEmojiSVGAPlayerView: UIViewRepresentable {
    let payload: PartyEmojiPayload
    let onFinish: () -> Void

    /// 跨实例 videoItem 复用（同一 emoji URL 短时间内多用户/多发送共享 · countLimit 30 覆盖 typical 派对场景）
    static let videoEntityCache: NSCache<NSString, SVGAVideoEntity> = {
        let c = NSCache<NSString, SVGAVideoEntity>()
        c.countLimit = 30
        return c
    }()

    func makeUIView(context: Context) -> SVGAPlayer {
        let player = SVGAPlayer(frame: .zero)
        player.contentMode = .scaleAspectFit
        player.loops = 1
        player.clearsAfterStop = false   // 末帧定格 · H5 侧 SVGA 资源自带停留帧
        player.backgroundColor = .clear
        player.delegate = context.coordinator
        context.coordinator.player = player
        context.coordinator.onFinish = onFinish
        context.coordinator.load(url: payload.playUrl)
        return player
    }

    func updateUIView(_ uiView: SVGAPlayer, context: Context) {
        // .id(head.uuid) 让 payload 切换直接重建 UIView · updateUIView 内部无需 diff
    }

    static func dismantleUIView(_ uiView: SVGAPlayer, coordinator: Coordinator) {
        uiView.stopAnimation()
        uiView.clear()
        coordinator.generation &+= 1   // in-flight parse callback 失效
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, SVGAPlayerDelegate {
        weak var player: SVGAPlayer?
        var onFinish: (() -> Void)?
        /// generation counter：URL parse 是异步 · dismantle / re-create 时自增 · in-flight parse 完成时 gen 不匹配丢弃
        var generation: Int = 0
        /// onFinish 幂等：SVGAPlayer 可能 didFinishedAnimation + didFinishAnimation2 双 delegate · parse 失败 + 播完
        /// 双路径都可能 fire · 加锁只 fire 一次
        private var didFire: Bool = false

        func load(url: String) {
            guard !url.isEmpty, let u = URL(string: url) else {
                fireOnce()
                return
            }
            generation &+= 1
            let myGen = generation

            // cache 命中直接播
            if let cached = PartyEmojiSVGAPlayerView.videoEntityCache.object(forKey: url as NSString) {
                player?.videoItem = cached
                player?.startAnimation()
                return
            }
            let parser = SVGAParser()
            parser.parse(with: u) { [weak self] videoItem in
                DispatchQueue.main.async {
                    guard let self, self.generation == myGen else { return }
                    guard let videoItem else {
                        self.fireOnce()
                        return
                    }
                    PartyEmojiSVGAPlayerView.videoEntityCache.setObject(videoItem, forKey: url as NSString)
                    self.player?.videoItem = videoItem
                    self.player?.startAnimation()
                }
            } failureBlock: { [weak self] error in
                logger.warning("SVGA emoji parse fail url=\(url, privacy: .private) err=\(String(describing: error), privacy: .private)")
                DispatchQueue.main.async {
                    guard let self, self.generation == myGen else { return }
                    // parse 失败也要 fire onFinish · 否则该 payload 永远卡在队首堵后续 emoji
                    self.fireOnce()
                }
            }
        }

        private func fireOnce() {
            guard !didFire else { return }
            didFire = true
            onFinish?()
        }

        // MARK: - SVGAPlayerDelegate

        func svgaPlayerDidFinishedAnimation(_ player: SVGAPlayer!) {
            fireOnce()
        }
    }
}
