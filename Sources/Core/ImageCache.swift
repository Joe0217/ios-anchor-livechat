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
/// - `NSCache<NSURL, UIImage>` 线程安全的内存缓存，150MB 上限按图像像素估算
/// - `inflight` dict 去重：同一 URL 同时多次请求合并为单次下载
/// - 普通图片仍使用 `URLCache.shared`，以保持账号切换时可整体清理的既有语义
/// - 礼物和运营图片等公共资源另走 `URLDiskCache`，不依赖 CDN 的缓存响应头，
///   登出后仍可复用，且受统一容量上限控制
/// - 不引第三方（Kingfisher/SDWebImage），符合工程纪律
final class ImageCache {

    static let shared = ImageCache()

    private let memCache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        // 150MB by estimated bytes：NSCache 有 LRU + iOS 内存告警自动 flush，撑得下上千头像 + 数百封面。
        // 上限提升源于：直播卡/头像多次进入不重新加载，是本工程主要流量痛点。
        c.totalCostLimit = 150 * 1024 * 1024
        return c
    }()

    /// inflight 任务表（同 URL 多次请求合并）。锁封装在同步存储内，
    /// 避免在 async 方法直接调用 NSLock 触发 Swift 6 并发告警。
    private let inflightStore = InflightStore()

    private init() {}

    /// 同步命中查询：用于 view body 内立即显示缓存（无闪烁）
    func cached(for url: URL) -> UIImage? {
        memCache.object(forKey: url as NSURL)
    }

    /// 全清：登出 / 切账号时调，确保下个账号看不到上个账号的图。
    /// 仅清账号相关图片；公共礼物/运营资源保留在独立文件缓存中。
    func clear() {
        memCache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        inflightStore.clear()
        logger.info("clear session cache")
    }

    /// 用户在设置页主动清缓存时调用。公共资源默认跨账号复用，不能挂在 `clear()`。
    func clearPublicAssets() {
        URLDiskCache.clear(namespace: URLDiskCache.publicAssetNamespace)
        logger.info("clear public assets")
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
        if let publicFile = URLDiskCache.cachedFile(
            for: url,
            namespace: URLDiskCache.publicAssetNamespace
        ) {
            if let image = decodePublicAsset(at: publicFile, sourceURL: url) {
                return image
            }
            URLDiskCache.invalidate(url: url, namespace: URLDiskCache.publicAssetNamespace)
        }

        // 同 URL 已有任务在跑：等同一个
        let task = inflightStore.task(for: url) { [weak self] in
            Task<UIImage?, Never> {
                await self?.actualFetch(url) ?? nil
            }
        }

        let img = await task.value
        inflightStore.remove(url)

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

    /// 获取可跨登录态长期复用的公共图片（礼物图、运营图等）。
    ///
    /// 文件缓存命中后不发网络请求；`Caches` 被系统回收或文件损坏时自动回落到重新下载。
    func fetchPublicAsset(_ url: URL) async -> UIImage? {
        if let cached = cached(for: url) { return cached }

        do {
            let fileURL = try await URLDiskCache.fetch(
                url: url,
                namespace: URLDiskCache.publicAssetNamespace,
                maximumCacheBytes: URLDiskCache.publicAssetCacheLimit
            )
            if let image = decodePublicAsset(at: fileURL, sourceURL: url) {
                return image
            }

            // 防止错误页或中途损坏文件永久占住缓存；删掉后本次再尝试一次。
            URLDiskCache.invalidate(url: url, namespace: URLDiskCache.publicAssetNamespace)
            let retryURL = try await URLDiskCache.fetch(
                url: url,
                namespace: URLDiskCache.publicAssetNamespace,
                maximumCacheBytes: URLDiskCache.publicAssetCacheLimit
            )
            let image = decodePublicAsset(at: retryURL, sourceURL: url)
            if image == nil {
                URLDiskCache.invalidate(url: url, namespace: URLDiskCache.publicAssetNamespace)
            }
            return image
        } catch {
            logger.error("public asset fetch failed url=\(url.absoluteString, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 登录后预拉取公共图片，完成后由各图片 View 从本地文件缓存读取。
    func prefetchPublicAssets(_ urls: [URL]) async {
        await URLDiskCache.prefetch(
            urls: urls,
            namespace: URLDiskCache.publicAssetNamespace,
            maximumCacheBytes: URLDiskCache.publicAssetCacheLimit
        )
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

    private func decodePublicAsset(at fileURL: URL, sourceURL: URL) -> UIImage? {
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            logger.warning("public asset decode failed url=\(sourceURL.absoluteString, privacy: .public)")
            return nil
        }
        memCache.setObject(image, forKey: sourceURL as NSURL, cost: Self.cost(of: image))
        return image
    }

    private final class InflightStore: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [URL: Task<UIImage?, Never>] = [:]

        func task(
            for url: URL,
            make: () -> Task<UIImage?, Never>
        ) -> Task<UIImage?, Never> {
            lock.lock()
            defer { lock.unlock() }
            if let existing = tasks[url] { return existing }
            let task = make()
            tasks[url] = task
            return task
        }

        func remove(_ url: URL) {
            lock.lock()
            tasks[url] = nil
            lock.unlock()
        }

        func clear() {
            lock.lock()
            tasks.removeAll()
            lock.unlock()
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
