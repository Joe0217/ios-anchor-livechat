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
