import UIKit
import SVGAPlayer
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "SVGAAnimationPlayer")

/// SVGA 真封装（Task 5）—— 单实例复用，parser 缓存，onFinish 幂等
///
/// 生命周期：init 空 → 首次 play 时懒创建 SVGAPlayer/SVGAParser →
/// 之后每次 play 复用同一 player 实例（换 videoItem）→ tearDown 时销毁
@MainActor
final class SVGAAnimationPlayer: NSObject, GiftAnimationPlayer, SVGAPlayerDelegate {

    private var player: SVGAPlayer?
    private var parser: SVGAParser?
    private var currentFinish: (() -> Void)?

    override init() { super.init() }

    /// 冷启 5s 后调（HilyApp Task 7）预热 parser，减少首条动画首帧延迟
    func warmup() {
        if parser == nil { parser = SVGAParser() }
        logger.info("SVGA warmed up")
    }

    func play(item: GiftEffectItem, in host: UIView, onFinish: @escaping () -> Void) {
        guard let urlStr = item.animationUrl,
              let url = URL(string: urlStr) else {
            onFinish()
            return
        }
        // 保证前一段 onFinish 若未 fire，此刻先 fire 一次防漏
        fireFinishOnce()
        currentFinish = onFinish

        let p = ensurePlayer(in: host)
        let parser = ensureParser()

        parser.parse(with: url) { [weak self, weak p] videoItem in
            guard let self, let p, let videoItem else {
                self?.fireFinishOnce()
                return
            }
            p.videoItem = videoItem
            p.loops = 1
            p.clearsAfterStop = true
            p.startAnimation()
        } failureBlock: { [weak self] err in
            logger.warning("SVGA parse fail url=\(url.absoluteString, privacy: .public) err=\(err?.localizedDescription ?? "nil", privacy: .public)")
            self?.fireFinishOnce()
        }
    }

    func stop() {
        player?.stopAnimation()
        player?.clear()
        fireFinishOnce()
    }

    func tearDown() {
        player?.stopAnimation()
        player?.removeFromSuperview()
        player = nil
        parser = nil
        currentFinish = nil
    }

    // MARK: - private

    private func ensurePlayer(in host: UIView) -> SVGAPlayer {
        if let p = player, p.superview === host { return p }
        player?.removeFromSuperview()
        let p = SVGAPlayer(frame: host.bounds)
        p.contentMode = .scaleAspectFit
        p.delegate = self
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(p)
        player = p
        return p
    }

    private func ensureParser() -> SVGAParser {
        if let p = parser { return p }
        let p = SVGAParser()
        parser = p
        return p
    }

    /// 幂等 fire：多次调用只 fire 一次；player delegate 回调 + stop() 都会走这里
    private func fireFinishOnce() {
        let f = currentFinish
        currentFinish = nil
        f?()
    }

    // MARK: - SVGAPlayerDelegate

    func svgaPlayerDidFinishedAnimation(_ player: SVGAPlayer!) {
        fireFinishOnce()
    }
}
