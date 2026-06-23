import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "ImageCache")

/// 全局远端图片缓存（NSCache 内存层 + URLSession 下载）。
///
/// 解决 SwiftUI `AsyncImage` 的痛点：
/// - AsyncImage 自身不缓存图片，view 离开再回来会重发请求；
/// - 切 tab / 切页时头像会"消失再加载"一遍。
///
/// 设计：
/// - `NSCache<NSURL, UIImage>` 线程安全的内存缓存，50MB 上限按图像像素估算
/// - `inflight` dict 去重：同一 URL 同时多次请求合并为单次下载
/// - `actualFetch` 内部调 `URLSession.shared.data(from:)`，底层 `URLCache.shared`
///   也会再缓一份（HilyApp 启动时配置了 100MB 磁盘容量）
/// - 不引第三方（Kingfisher/SDWebImage），符合工程纪律
final class ImageCache {

    static let shared = ImageCache()

    private let memCache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 50 * 1024 * 1024  // 50MB by estimated bytes
        return c
    }()

    /// inflight 任务表（同 URL 多次请求合并）；用 lock 保护字典写入
    private let lock = NSLock()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    private init() {}

    /// 同步命中查询：用于 view body 内立即显示缓存（无闪烁）
    func cached(for url: URL) -> UIImage? {
        memCache.object(forKey: url as NSURL)
    }

    /// 全清：登出 / 切账号时调，确保下个账号看不到上个账号的图。
    /// URLCache 磁盘层一并 removeAllCachedResponses。
    func clear() {
        memCache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        lock.lock(); inflight.removeAll(); lock.unlock()
        logger.info("clear all")
    }

    /// 精准 invalidate 单 URL：下拉刷新时把"上次显示的图"踢出缓存，强制重拉。
    /// 内存层 + URLCache 磁盘层一起清。
    func invalidate(_ url: URL) {
        memCache.removeObject(forKey: url as NSURL)
        URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
    }

    /// 批量 invalidate（Profile 整页图片一次性失效）。
    func invalidate(_ urls: [URL]) {
        for u in urls { invalidate(u) }
    }

    /// 异步获取：先查内存 → 再走网络。失败返回 nil。
    func fetch(_ url: URL) async -> UIImage? {
        if let cached = cached(for: url) { return cached }

        // 同 URL 已有任务在跑：等同一个
        lock.lock()
        if let existing = inflight[url] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            await self?.actualFetch(url) ?? nil
        }
        inflight[url] = task
        lock.unlock()

        let img = await task.value

        lock.lock()
        inflight[url] = nil
        lock.unlock()

        return img
    }

    /// 临时拉取（不写 NSCache、不读写 URLCache 磁盘层）：用于他人头像等不需要持久化的场景。
    /// view 端 @State 持有当次结果；view dismount 后即丢，不污染缓存。
    func fetchEphemeral(_ url: URL) async -> UIImage? {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    private func actualFetch(_ url: URL) async -> UIImage? {
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let netElapsed = Date().timeIntervalSince(start)
            guard let img = UIImage(data: data) else {
                logger.warning("decode failed url=\(url.absoluteString, privacy: .public) bytes=\(data.count)")
                return nil
            }
            let fromCache = (response as? HTTPURLResponse)
                .flatMap { _ in URLCache.shared.cachedResponse(for: URLRequest(url: url)) != nil } ?? false
            logger.info("fetch \(url.lastPathComponent, privacy: .public) net=\(String(format: "%.2f", netElapsed))s bytes=\(data.count) px=\(Int(img.size.width))x\(Int(img.size.height)) urlCache=\(fromCache)")
            memCache.setObject(img, forKey: url as NSURL, cost: Self.cost(of: img))
            return img
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            logger.error("fetch failed url=\(url.absoluteString, privacy: .public) elapsed=\(String(format: "%.2f", elapsed))s err=\(String(describing: error))")
            return nil
        }
    }

    /// 单张图的内存成本估算（像素 × 4 字节 RGBA）。用于 NSCache 容量控制。
    private static func cost(of img: UIImage) -> Int {
        let scale = img.scale
        let w = Int(img.size.width * scale)
        let h = Int(img.size.height * scale)
        return max(1, w * h * 4)
    }
}
