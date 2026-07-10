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
    /// generation 计数器（2026-07-09 code-review P1 修复）：
    /// SVGAParser.parse 是**异步**网络+解压，若 play(A) parse 中途 → stop() 或 play(B) → parse A
    /// 迟到 fire 会：(a) A stop 后仍 startAnimation 播几帧 A；(b) B 已经 startAnimation 时用 A 的
    /// videoItem 覆盖 → 视觉播 A 而非 B。用 gen 让 parse 闭包 fire 时对比自己那次的 gen，不匹配丢弃。
    private var currentGen: Int = 0

    /// SVGAVideoEntity 缓存（2026-07-10 code-review E-2 修复）：
    /// 同 URL 重复 parse 会付网络下载 + zip 解压 + 帧图片解码开销；同一直播场景热门礼物
    /// 1 分钟送 20 次 → 累计 ~600ms 主线程 parse 工作全浪费。用 NSCache 保留最近 30 条解析结果，
    /// 命中直接复用 videoItem，只走 startAnimation。
    private let videoEntityCache: NSCache<NSString, SVGAVideoEntity> = {
        let c = NSCache<NSString, SVGAVideoEntity>()
        c.countLimit = 30
        return c
    }()

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
        currentGen &+= 1
        let gen = currentGen
        currentFinish = onFinish

        let p = ensurePlayer(in: host)

        // E-2 cache 命中：直接复用 videoItem 跳过 parse
        if let cached = videoEntityCache.object(forKey: urlStr as NSString) {
            p.videoItem = cached
            p.loops = 1
            p.clearsAfterStop = true
            p.startAnimation()
            return
        }

        let parser = ensureParser()
        let cacheKey = urlStr as NSString

        parser.parse(with: url) { [weak self, weak p] videoItem in
            guard let self else { return }
            // parse 是异步：若 gen 不匹配说明期间已 stop/替换 → 丢弃本次 parse 结果（无论 success/failure）
            // 避免 (a) 播已 stop 的 item；(b) 用旧 videoItem 覆盖新 item；(c) 迟到的 videoItem=nil 误 fire 下一段 onFinish
            guard self.currentGen == gen else {
                logger.info("SVGA parse stale gen (current=\(self.currentGen, privacy: .public) my=\(gen, privacy: .public)), drop")
                return
            }
            guard let p, let videoItem else {
                self.fireFinishOnce()
                return
            }
            // E-2 缓存 parse 结果供下次命中
            self.videoEntityCache.setObject(videoItem, forKey: cacheKey)
            p.videoItem = videoItem
            p.loops = 1
            p.clearsAfterStop = true
            p.startAnimation()
        } failureBlock: { [weak self] err in
            guard let self, self.currentGen == gen else { return }   // 迟到的失败不误 fire 当前 onFinish
            logger.warning("SVGA parse fail url=\(url.absoluteString, privacy: .public) err=\(err?.localizedDescription ?? "nil", privacy: .public)")
            self.fireFinishOnce()
        }
    }

    func stop() {
        player?.stopAnimation()
        player?.clear()
        currentGen &+= 1   // 让所有 in-flight parse callback 失效
        fireFinishOnce()
    }

    func tearDown() {
        player?.stopAnimation()
        player?.removeFromSuperview()
        player = nil
        parser = nil
        currentFinish = nil
        currentGen &+= 1
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

    // OC 协议签名带 IUO；改为 optional 与 Swift override 兼容且防 SDK 边界值传 nil 时 unwrap crash
    // （函数体不使用 player 参数，语义上就是无害的 optional）
    func svgaPlayerDidFinishedAnimation(_ player: SVGAPlayer?) {
        fireFinishOnce()
    }
}
