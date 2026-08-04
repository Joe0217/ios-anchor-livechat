import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "URLDiskCache")

/// 远端媒体资源磁盘缓存。
///
/// 文件按 URL 的 SHA-256 落在 `Caches/<namespace>/`，因此不依赖 CDN 的 HTTP
/// 缓存头；命中后直接返回本地文件。`Caches` 仍可能被系统回收，上层必须能接受
/// 下一次重新下载。
///
/// **优势 vs 直接用 URLSession.shared.downloadTask**：
/// 1. **同步 move**：URLSession 契约"tempURL 只在 completion 同步块内有效"
///    → 在 delegate queue 上同步 move 到 Caches，然后再 hop main —— 避免
///    "Task { @MainActor } 延到下 runloop 后 tempURL 已删" UB（code-review #4）
/// 2. **HTTP 状态 + Content-Type 校验**：非 2xx / MIME 不符 → 不入缓存
///    → 防 404/500 错误页被缓存为 mp4 后每次进房挂（code-review #5）
/// 3. **短 timeout + 一次重试**：CDN 边缘节点抽风时不再等 60s
///    → 快速失败让上层 fallback（code-review #11）
///
/// 用途包括远端图片、视频和动画；UI 层仍通过各自的图片/播放器组件消费本地文件，
/// 不直接把不受信任的 `file://` URL 暴露给服务端数据。
enum URLDiskCache {

    /// 公共运营资源（礼物图片、MP4 动画、服务端图片配置等）共用一个目录和容量上限。
    /// 这些文件不含账号私密内容，因此登出后可继续复用；设置页的"清缓存"会显式删除。
    static let publicAssetNamespace = "HilyPublicAssetCache"
    static let publicAssetCacheLimit = 200 * 1024 * 1024

    private static let inflightStore = InflightStore()

    // MARK: - Public API

    /// 拉取远端 URL 到本地缓存文件。
    ///
    /// - Parameters:
    ///   - url: 远端 URL；`isFileURL` 场景不应调此方法（上层短路）
    ///   - namespace: 子目录（如 "PartyBGCache" / "YYEVACache"），跨用途隔离
    ///   - expectedMIMEPrefix: content-type 前缀白名单（如 "video/"），nil 表不校验
    /// - Returns: 本地文件路径；失败 throw
    static func fetch(
        url: URL,
        namespace: String,
        expectedMIMEPrefix: String? = nil,
        maximumCacheBytes: Int? = nil
    ) async throws -> URL {
        guard isRemoteURL(url) else {
            throw URLDiskCacheError.unsupportedURL
        }
        let dest = localPath(for: url, namespace: namespace)
        if FileManager.default.fileExists(atPath: dest.path) {
            touch(dest)
            trim(namespace: namespace, maximumCacheBytes: maximumCacheBytes, preserving: dest)
            logger.info("cache hit ns=\(namespace, privacy: .public) path=\(dest.path, privacy: .public)")
            return dest
        }

        let key = "\(namespace)|\(expectedMIMEPrefix ?? "")|\(url.absoluteString)"
        let task = inflightStore.task(for: key) {
            Task<URL, Error> {
                try await download(url: url, dest: dest, expectedMIMEPrefix: expectedMIMEPrefix)
            }
        }

        do {
            let localURL = try await task.value
            inflightStore.remove(key)
            trim(namespace: namespace, maximumCacheBytes: maximumCacheBytes, preserving: localURL)
            return localURL
        } catch {
            inflightStore.remove(key)
            throw error
        }
    }

    /// 后台预下载一组公共资源。失败只影响当前文件，不会中断剩余资源。
    /// 采用分批并发，避免登录后一次创建过多 URLSession 请求。
    static func prefetch(
        urls: [URL],
        namespace: String = publicAssetNamespace,
        expectedMIMEPrefix: String? = nil,
        maximumCacheBytes: Int? = publicAssetCacheLimit,
        maximumConcurrentRequests: Int = 3
    ) async {
        let uniqueURLs = Array(Set(urls.filter(isRemoteURL)))
        let batchSize = max(1, maximumConcurrentRequests)

        for start in stride(from: 0, to: uniqueURLs.count, by: batchSize) {
            let end = min(start + batchSize, uniqueURLs.count)
            await withTaskGroup(of: Void.self) { group in
                for url in uniqueURLs[start..<end] {
                    group.addTask {
                        do {
                            _ = try await fetch(
                                url: url,
                                namespace: namespace,
                                expectedMIMEPrefix: expectedMIMEPrefix,
                                maximumCacheBytes: maximumCacheBytes
                            )
                        } catch {
                            logger.warning("prefetch failed ns=\(namespace, privacy: .public) url=\(url.absoluteString, privacy: .private) err=\(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        }
    }

    /// 计算给定 URL 在指定 namespace 下的本地缓存路径（不下载、不验证存在）。
    static func localPath(for url: URL, namespace: String) -> URL {
        let dir = directory(namespace: namespace)
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let rawExtension = url.pathExtension.lowercased()
        let ext = rawExtension.allSatisfy({ $0.isLetter || $0.isNumber }) && !rawExtension.isEmpty
            ? rawExtension
            : "bin"
        return dir.appendingPathComponent("\(hex).\(ext)")
    }

    /// 仅查询已落盘的文件，不触发网络。用于图片组件优先读取登录期预下载的公共资源。
    static func cachedFile(for url: URL, namespace: String) -> URL? {
        let path = localPath(for: url, namespace: namespace)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        touch(path)
        return path
    }

    /// 主动清一个缓存文件（用于播放失败等场景，配合 code-review #6）。
    static func invalidate(url: URL, namespace: String) {
        let path = localPath(for: url, namespace: namespace)
        try? FileManager.default.removeItem(at: path)
        logger.info("invalidate ns=\(namespace, privacy: .public) path=\(path.path, privacy: .public)")
    }

    /// 删除一个缓存分类。仅用于用户主动清缓存或资源包版本整体失效，日常按 URL 更新即可。
    static func clear(namespace: String) {
        let path = directory(namespace: namespace)
        try? FileManager.default.removeItem(at: path)
        logger.info("clear ns=\(namespace, privacy: .public)")
    }

    // MARK: - Internals

    /// 独立 URLSession：短 timeoutIntervalForResource + reload-ignoring-cache
    /// （本组件已做磁盘缓存，禁 URLCache 二次副本；code-review #11）
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private static func directory(namespace: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func isRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// 按最后使用时间删除最旧文件。这里只针对显式传入上限的公共资源目录，
    /// 以免改变已有视频缓存的生命周期。
    private static func trim(namespace: String, maximumCacheBytes: Int?, preserving: URL? = nil) {
        guard let maximumCacheBytes, maximumCacheBytes > 0 else { return }
        let dir = directory(namespace: namespace)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let entries: [(url: URL, bytes: Int, accessedAt: Date)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: keys),
                  let bytes = values.fileSize else { return nil }
            return (file, bytes, values.contentModificationDate ?? .distantPast)
        }
        var totalBytes = entries.reduce(0) { $0 + $1.bytes }
        guard totalBytes > maximumCacheBytes else { return }

        for entry in entries.sorted(by: { $0.accessedAt < $1.accessedAt }) {
            // 单个新资源异常大时，宁可临时超过上限也不能删掉刚返回给播放器的文件。
            if let preserving, entry.url == preserving { continue }
            try? FileManager.default.removeItem(at: entry.url)
            totalBytes -= entry.bytes
            if totalBytes <= maximumCacheBytes { break }
        }
        logger.info("trim ns=\(namespace, privacy: .public) remaining=\(totalBytes, privacy: .public)")
    }

    /// 锁只封装在同步方法内，调用方可安全地位于 async 上下文。
    private final class InflightStore: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [String: Task<URL, Error>] = [:]

        func task(for key: String, make: () -> Task<URL, Error>) -> Task<URL, Error> {
            lock.lock()
            defer { lock.unlock() }
            if let existing = tasks[key] { return existing }
            let task = make()
            tasks[key] = task
            return task
        }

        func remove(_ key: String) {
            lock.lock()
            tasks[key] = nil
            lock.unlock()
        }
    }

    /// 内部下载：**在 URLSession delegate queue 同步 move**，然后返回 dest URL。
    /// 一次重试：首次网络失败（timeout / connection lost）自动重试 1 次。
    private static func download(
        url: URL,
        dest: URL,
        expectedMIMEPrefix: String?
    ) async throws -> URL {
        do {
            return try await downloadOnce(url: url, dest: dest, expectedMIMEPrefix: expectedMIMEPrefix)
        } catch {
            let retryable = (error as? URLError).map { retryableCodes.contains($0.code) } ?? false
            guard retryable else {
                logger.warning("download failed (non-retryable) url=\(url.absoluteString, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                throw error
            }
            logger.notice("download retry (transient) url=\(url.absoluteString, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            return try await downloadOnce(url: url, dest: dest, expectedMIMEPrefix: expectedMIMEPrefix)
        }
    }

    private static let retryableCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
    ]

    private static func downloadOnce(
        url: URL,
        dest: URL,
        expectedMIMEPrefix: String?
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let task = session.downloadTask(with: url) { tempURL, response, error in
                // **关键**：在 URLSession delegate queue 同步完成 move（不 hop main）
                // —— Apple 契约要求 tempURL 只在 completion 同步块内有效
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL else {
                    cont.resume(throwing: URLDiskCacheError.emptyTempURL)
                    return
                }
                // HTTP 状态 + MIME 校验：防错误页被缓存成媒体文件
                if let http = response as? HTTPURLResponse {
                    guard (200..<300).contains(http.statusCode) else {
                        cont.resume(throwing: URLDiskCacheError.badStatusCode(http.statusCode))
                        return
                    }
                    if let expect = expectedMIMEPrefix,
                       let mime = http.mimeType,
                       !mime.hasPrefix(expect) {
                        cont.resume(throwing: URLDiskCacheError.badMIMEType(actual: mime, expected: expect))
                        return
                    }
                }
                // 同步 move 到 dest（overwrite 若已存在——并发同 URL 竞争兜底）
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            task.resume()
        }
    }
}

enum URLDiskCacheError: LocalizedError {
    case unsupportedURL
    case emptyTempURL
    case badStatusCode(Int)
    case badMIMEType(actual: String, expected: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedURL: return "only http/https URLs can be cached"
        case .emptyTempURL: return "download completed but tempURL is nil"
        case .badStatusCode(let code): return "HTTP \(code) (expected 2xx)"
        case .badMIMEType(let actual, let expected): return "MIME '\(actual)' does not match expected prefix '\(expected)'"
        }
    }
}
