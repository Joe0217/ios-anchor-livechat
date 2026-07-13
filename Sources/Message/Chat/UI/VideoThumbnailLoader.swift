import SwiftUI
import AVFoundation
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "VideoThumbnailLoader")

/// Batch 4：视频首帧异步提取 + 内存缓存（服务于私密相册视频 cell，无独立 coverUrl 时兜底）。
///
/// **策略**：
/// - `AVAsset` 走 HTTP live streaming（视频 CDN URL）从 t=0.1s 抓首帧
/// - `AVAssetImageGenerator.copyCGImage(at:)` 同步阻塞 → 用 `Task.detached` 后台执行
/// - 内存 `NSCache` LRU 20 项上限（cover 缩略图约 100KB/张，总内存 ~2MB）
///
/// **不做**：磁盘持久化（离开 chat 页丢弃可接受；H5 私密视频封面也无持久化）
@MainActor
final class VideoThumbnailCache {
    static let shared = VideoThumbnailCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 20
        return c
    }()

    func get(_ url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func set(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }

    /// 异步提取首帧。返回 nil = 提取失败（网络 / 视频格式 / 权限）
    /// S-8:iOS 16+ 用 async `image(at:)` 新 API 替代已弃用的 `copyCGImage(at:actualTime:)`
    /// (老 API iOS 18/19 可能移除;新 API 内建后台执行,无需 Task.detached)
    static func extractFirstFrame(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)

        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await gen.image(at: time)
            return UIImage(cgImage: cgImage)
        } catch {
            logger.warning("extract failed url=\(url.absoluteString, privacy: .private): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// SwiftUI View：视频 URL → 首帧缩略图 + fallback placeholder。
///
/// **用法**（对齐 CachedAsyncImage）：
/// ```swift
/// VideoThumbnailImage(url: videoUrl) {
///     ChatPalette.cardBackground   // fallback placeholder
/// }
/// ```
struct VideoThumbnailImage<Placeholder: View>: View {
    let url: URL
    let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(url: URL, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            // cache hit → 立即渲染
            if let cached = VideoThumbnailCache.shared.get(url) {
                image = cached
                return
            }
            // cache miss → 后台异步生成
            guard let extracted = await VideoThumbnailCache.extractFirstFrame(from: url) else { return }
            VideoThumbnailCache.shared.set(extracted, for: url)
            image = extracted
        }
    }
}
