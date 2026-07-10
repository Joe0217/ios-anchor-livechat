import UIKit
import YYEVA
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "YYEVAAnimationPlayer")

/// YYEVA 真封装（Task 5）—— 单实例复用，onFinish 幂等
///
/// 真 API（Pods/YYEVA/YYEVA/Classes/core/YYEVAPlayer.h）：
/// - `YYEVAPlayer: UIView` + `IYYEVAPlayerDelegate`
/// - `play(_ fileUrl: String)` 直接播放；不用 parser
/// - `loop: BOOL` 单次/循环；本 impl 单次
/// - Delegate: `evaPlayerDidCompleted:` / `evaPlayer:playFail:`
@MainActor
final class YYEVAAnimationPlayer: NSObject, GiftAnimationPlayer, IYYEVAPlayerDelegate {

    private var player: YYEVAPlayer?
    private var currentFinish: (() -> Void)?

    override init() { super.init() }

    /// 冷启预热：提前 lazy init YYEVAPlayer 触发 Metal shader 预编译，避免首条 mp4 gift 首帧卡帧 100-400ms
    /// （2026-07-10 code-review E-1 修复：warmupSVGA 只暖 SVGA，YYEVA 首次 use 时 Metal newLibraryWithFile
    /// + shader compile 阻塞 main queue；此 warmup 无 host UIView，不 addSubview，等真正 play 时 ensurePlayer 加入）
    func warmup() {
        if player == nil {
            let p = YYEVAPlayer(frame: .zero)
            p.delegate = self
            p.backgroundColor = .clear
            player = p
            logger.info("YYEVA warmed up (Metal shader precompile)")
        }
    }

    func play(item: GiftEffectItem, in host: UIView, onFinish: @escaping () -> Void) {
        guard let urlStr = item.animationUrl else {
            onFinish()
            return
        }
        // 前一段 onFinish 若未 fire，此刻先 fire 防漏
        fireFinishOnce()
        currentFinish = onFinish

        let p = ensurePlayer(in: host)
        p.loop = false
        p.play(urlStr)
    }

    func stop() {
        player?.stopAnimation()
        fireFinishOnce()
    }

    func tearDown() {
        player?.stopAnimation()
        player?.removeFromSuperview()
        player = nil
        currentFinish = nil
    }

    // MARK: - private

    private func ensurePlayer(in host: UIView) -> YYEVAPlayer {
        if let p = player, p.superview === host { return p }
        player?.removeFromSuperview()
        let p = YYEVAPlayer(frame: host.bounds)
        p.delegate = self
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        p.backgroundColor = .clear
        host.addSubview(p)
        player = p
        return p
    }

    private func fireFinishOnce() {
        let f = currentFinish
        currentFinish = nil
        f?()
    }

    // MARK: - IYYEVAPlayerDelegate

    func evaPlayerDidCompleted(_ player: YYEVAPlayer) {
        fireFinishOnce()
    }

    func evaPlayer(_ player: YYEVAPlayer, playFail error: any Error) {
        logger.warning("YYEVA play fail: \(error.localizedDescription, privacy: .public)")
        fireFinishOnce()
    }
}
