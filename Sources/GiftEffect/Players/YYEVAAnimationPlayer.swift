import UIKit
import YYEVA
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "YYEVAAnimationPlayer")

/// YYEVA 真封装（Task 5）—— 单实例复用，onFinish 幂等
///
/// 真 API（Pods/YYEVA/YYEVA/Classes/core/YYEVAPlayer.h）：
/// - `YYEVAPlayer: UIView` + `IYYEVAPlayerDelegate`
/// - `play(_ fileUrl: String)` **只吃本地文件路径**（YYEVAAssets.m:135 fileExistsAtPath 硬性守卫）
/// - `loop: BOOL` 单次/循环；本 impl 单次
/// - Delegate: `evaPlayerDidCompleted:` / `evaPlayer:playFail:`
///
/// **v24（2026-07-13）URL 下载缓存**：传 HTTPS URL 到 YYEva → `fileExistsAtPath` 判定失败 → 立即
/// `NSURLErrorDomain code=1 (FileNotExits)` → 真机永远无法播出座驾 mp4。
/// 修复：URL → `URLDiskCache` 下载到公共资源缓存 → 传本地路径给 YYEva.play
/// - 命中缓存直接复用（避免同 URL 反复下载）
/// - 下载失败 fireFinishOnce 推动 Center 队列继续
/// - gen 计数器防止 stale download 迟到误播
@MainActor
final class YYEVAAnimationPlayer: NSObject, GiftAnimationPlayer, IYYEVAPlayerDelegate {

    private var player: YYEVAPlayer?
    private var currentFinish: (() -> Void)?
    /// gen 计数：URL 下载是异步的，中途 stop 或 play(B) 会 &+= gen，
    /// 下载完成 callback 前对比 gen，不匹配则 drop
    private var currentGen: Int = 0
    private var cacheTask: Task<Void, Never>?
    private var currentRemoteURL: URL?

    override init() { super.init() }

    /// 冷启预热：提前 lazy init YYEVAPlayer 触发 Metal shader 预编译，避免首条 mp4 gift 首帧卡帧 100-400ms
    /// （2026-07-10 code-review E-1 修复：warmupSVGA 只暖 SVGA，YYEVA 首次 use 时 Metal newLibraryWithFile
    /// + shader compile 阻塞 main queue；此 warmup 无 host UIView，不 addSubview，等真正 play 时 ensurePlayer 加入）
    func warmup() {
        if player == nil {
            player = Self.makePlayer(frame: .zero, delegate: self)
            logger.info("YYEVA warmed up (Metal shader precompile)")
        }
    }

    func play(item: GiftEffectItem, in host: UIView, onFinish: @escaping () -> Void) {
        guard let urlStr = item.animationUrl, let url = URL(string: urlStr) else {
            onFinish()
            return
        }
        // 前一段 onFinish 若未 fire，此刻先 fire 防漏
        fireFinishOnce()
        currentGen &+= 1
        let gen = currentGen
        currentFinish = onFinish

        // 本地路径直接播（file:// scheme）
        if url.isFileURL {
            currentRemoteURL = nil
            playLocal(path: url.path, in: host)
            return
        }
        currentRemoteURL = url

        // `URLDiskCache` 在 URLSession completion 同步 move 临时文件，避免 tempURL 切回主线程后失效。
        // 公共礼物/座驾动画与礼物图片共用 200MB LRU，登出后仍可复用。
        cacheTask?.cancel()
        cacheTask = Task { @MainActor [weak self, weak host] in
            do {
                // Hily OSS 为部分 MP4 返回 application/octet-stream；路由已按 .mp4
                // 过滤，继续由 URLDiskCache 校验 HTTP 2xx，不能在这里强制 video/* MIME。
                let localURL = try await URLDiskCache.fetch(
                    url: url,
                    namespace: URLDiskCache.publicAssetNamespace,
                    maximumCacheBytes: URLDiskCache.publicAssetCacheLimit
                )
                guard let self else { return }
                guard self.currentGen == gen else {
                    logger.info("YYEVA download stale gen (current=\(self.currentGen, privacy: .public) my=\(gen, privacy: .public)), drop")
                    return
                }
                guard let host else {
                    logger.warning("YYEVA download host released, drop")
                    self.fireFinishOnce()
                    return
                }
                self.playLocal(path: localURL.path, in: host)
            } catch {
                guard let self, self.currentGen == gen else { return }
                logger.warning("YYEVA download failed: \(error.localizedDescription, privacy: .public)")
                self.fireFinishOnce()
            }
        }
    }

    func stop() {
        player?.stopAnimation()
        currentGen &+= 1
        cacheTask?.cancel()
        cacheTask = nil
        currentRemoteURL = nil
        fireFinishOnce()
    }

    func tearDown() {
        player?.stopAnimation()
        player?.removeFromSuperview()
        player = nil
        currentFinish = nil
        currentRemoteURL = nil
        currentGen &+= 1
        cacheTask?.cancel()
        cacheTask = nil
    }

    // MARK: - private

    private func playLocal(path: String, in host: UIView) {
        let p = ensurePlayer(in: host)
        p.loop = false
        p.play(path)
    }

    private func ensurePlayer(in host: UIView) -> YYEVAPlayer {
        // v23（2026-07-13）code-review 修复：复用 warmup 创建的 player 实例（superview == nil）
        // 而非重建，保住 warmup 的 Metal shader / MTKView / delegate 预热成本
        if let p = player {
            if p.superview === host { return p }        // 已 addSubview 到当前 host，直接用
            if p.superview == nil {                       // warmup 实例（无 host）→ addSubview 复用
                p.frame = host.bounds
                p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host.addSubview(p)
                return p
            }
            // 其他 host 上（罕见，理论上 warmup + 前次 host + 新 host 三态）→ removeFromSuperview 重挂
            p.removeFromSuperview()
            p.frame = host.bounds
            p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(p)
            return p
        }
        // 无 player 实例（warmup 未执行 or tearDown 后）→ 新建
        let p = Self.makePlayer(frame: host.bounds, delegate: self)
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(p)
        player = p
        return p
    }

    /// **关键**（2026-07-13 白屏根因修复）：
    /// `YYEVAPlayer()` 无参 init 里设的默认值 —— `mode = ScaleAspectFit / regionMode = NoSpecify /
    /// volume = 1 / isFirstPlay = YES / backgroundColor = clear`。
    /// 若走 `YYEVAPlayer(frame:)`（UIView 的 initWithFrame:），会 **完全绕过** YYEva 的 `- init`，
    /// 导致 mode=0(ScaleToFill) + regionMode=0(Invaile) + volume=0(静音) 等异常状态：
    /// - mode=0 → recalculateViewGeometry 走 switch default → wRatio=hRatio=1 拉伸失真 + log "w 1, h 1"
    /// - 加上 mtkView.layer 未显式设透明导致 alpha 通道被合成器 ignore → 全屏白色
    /// 修复：先 `YYEVAPlayer()` 触发 init 默认值 → 再手动 `frame = ...` 设尺寸。
    private static func makePlayer(frame: CGRect, delegate: IYYEVAPlayerDelegate) -> YYEVAPlayer {
        let p = YYEVAPlayer()   // ← 走 YYEva 自己 init 设 mode/regionMode/volume/... 默认值
        p.frame = frame
        p.delegate = delegate
        p.backgroundColor = .clear
        // 保险：显式让 layer 透明支持 alpha 合成
        p.isOpaque = false
        p.layer.isOpaque = false
        // 2026-07-13 座驾特效颜色反转修复：座驾 mp4 内嵌 metadata (rgbFrame/alphaFrame) 与实际像素
        // 布局左右反了 —— H5 因忽略 metadata 走硬编码路径反而对，iOS 忠实读 metadata 反而错。
        // 显式设 regionMode = LGRC(3) 让 SDK 走 LGRCFragmentSharder 固定 shader (右半 RGB / 左半 alpha
        // mask)，跳过 metadata 路径 —— 与实测像素布局对齐。
        // 配合 Podfile YYEva regionMode post_install patch：patch 让 SDK 判 hasValidEffectInfo 时
        // 只有 region == NoSpecify 才走 metadata；本 setter 让 region != NoSpecify → 强制忽略 metadata。
        // ⚠️ 硬编码 LGRC 假设"全部座驾 mp4 均为 Left-Gray-Right-Color 布局"；未来若后端下发 layout
        // 字段 → 改从 GiftEffectItem 读 dynamic regionMode（.playLocal 入口 setter）。
        // 用 rawValue 兜底避免 Swift Clang importer NS_ENUM 命名解析歧义。
        // ⚠️ code-review 加 ?? 兜底：若未来 SDK 升级重排 enum 顺序（LGRC 不再是 3）→ 优雅退化到
        //    NoSpecify(999) 走原 metadata 路径而不 force-unwrap crash（配套 Pod patch 若也失效仅是
        //    座驾颜色反转 bug 回归，比 crash 好）。
        p.regionMode = YYEVAColorRegion(rawValue: 3)   // AlphaMP4_LeftGrayRightColor
            ?? YYEVAColorRegion(rawValue: 999)!        // NoSpecify (SDK 铁定保留)
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
        if let currentRemoteURL {
            URLDiskCache.invalidate(
                url: currentRemoteURL,
                namespace: URLDiskCache.publicAssetNamespace
            )
        }
        fireFinishOnce()
    }
}
