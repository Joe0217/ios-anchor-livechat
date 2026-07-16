import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "URLDiskCache")

/// 远端媒体资源磁盘缓存（对齐 code-review §13 抽公共，
/// 复用 YYEVAAnimationPlayer 已生产验证的"SHA256 → Caches/{ns}/{hex}.<ext>"策略）。
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
/// **抽取纪律**：本组件仅针对 iOS 主播端"远端音视频/动画资源"缓存场景，
/// 不承担 CachedAsyncImage 的图片路径（那边有专属 ImageCache 内存 + 磁盘两级）。
///
/// **未来 refactor 提示**：YYEVAAnimationPlayer.swift:207-219 内嵌了同款
/// 逻辑（namespace 为 "YYEVACache"），后续可平移到本组件。
enum URLDiskCache {

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
        expectedMIMEPrefix: String? = nil
    ) async throws -> URL {
        precondition(!url.isFileURL, "URLDiskCache.fetch called with file URL; caller must short-circuit")
        let dest = localPath(for: url, namespace: namespace)
        if FileManager.default.fileExists(atPath: dest.path) {
            logger.info("cache hit ns=\(namespace, privacy: .public) path=\(dest.path, privacy: .public)")
            return dest
        }
        return try await download(url: url, dest: dest, expectedMIMEPrefix: expectedMIMEPrefix)
    }

    /// 计算给定 URL 在指定 namespace 下的本地缓存路径（不下载、不验证存在）。
    static func localPath(for url: URL, namespace: String) -> URL {
        let dir = directory(namespace: namespace)
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        return dir.appendingPathComponent("\(hex).\(ext)")
    }

    /// 主动清一个缓存文件（用于播放失败等场景，配合 code-review #6）。
    static func invalidate(url: URL, namespace: String) {
        let path = localPath(for: url, namespace: namespace)
        try? FileManager.default.removeItem(at: path)
        logger.info("invalidate ns=\(namespace, privacy: .public) path=\(path.path, privacy: .public)")
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
    case emptyTempURL
    case badStatusCode(Int)
    case badMIMEType(actual: String, expected: String)

    var errorDescription: String? {
        switch self {
        case .emptyTempURL: return "download completed but tempURL is nil"
        case .badStatusCode(let code): return "HTTP \(code) (expected 2xx)"
        case .badMIMEType(let actual, let expected): return "MIME '\(actual)' does not match expected prefix '\(expected)'"
        }
    }
}
