import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftPlayerRouter")

/// 生产环境播放路由：按 URL 后缀分发 SVGA / MP4 到具体 player
///
/// Task 4：内部两个 player 用 StubGiftAnimationPlayer（假 2.5s 播放）
/// Task 5：替换为真 SVGAAnimationPlayer / YYEVAAnimationPlayer
///
/// **不进 HilyTests 白名单**：Task 5 后本类会 import SVGAPlayer / YYEVA 引入 SDK 依赖；
/// tests 用 FakeGiftPlayerRouter 显式注入，不走本类。
@MainActor
public final class GiftPlayerRouter: GiftPlayerRouting {

    private lazy var svgaPlayer: SVGAAnimationPlayer = SVGAAnimationPlayer()
    private lazy var yyevaPlayer: YYEVAAnimationPlayer = YYEVAAnimationPlayer()

    private var activePlayer: GiftAnimationPlayer?

    public init() {}

    public func play(item: GiftEffectItem, in host: UIView, onFinish: @escaping () -> Void) {
        guard let url = item.animationUrl,
              let parsed = URL(string: url) else {
            onFinish()
            return
        }
        let ext = parsed.pathExtension.lowercased()
        let player: GiftAnimationPlayer? = {
            switch ext {
            case "svga": return svgaPlayer
            case "mp4":  return yyevaPlayer
            default: return nil
            }
        }()
        guard let p = player else {
            logger.warning("unsupported ext=\(ext, privacy: .public) skip url=\(url, privacy: .public)")
            onFinish()
            return
        }
        activePlayer = p
        p.play(item: item, in: host) { [weak self] in
            self?.activePlayer = nil
            onFinish()
        }
    }

    public func stopAll() {
        activePlayer?.stop()
        activePlayer = nil
    }

    public func tearDownPlayers() {
        svgaPlayer.tearDown()
        yyevaPlayer.tearDown()
        activePlayer = nil
    }

    public func warmupSVGA() {
        // 命名保留（RootView 调用点用）；实际两个 player 都预热
        // 2026-07-10 code-review E-1 修复：加 YYEVA 预热避免首条 mp4 gift 卡帧
        svgaPlayer.warmup()
        yyevaPlayer.warmup()
    }
}
