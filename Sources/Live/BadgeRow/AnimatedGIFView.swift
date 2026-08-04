import Foundation
import SwiftUI
import UIKit
import ImageIO

/// v17 动图渲染 —— SwiftUI 包装 UIImageView 帧动画
///
/// **设计**：无第三方依赖，用 iOS 原生 ImageIO 拆 GIF / WebP 帧 → UIImage.animatedImage(with:duration:) 播放。
///
/// **用法**：
/// ```swift
/// AnimatedGIFView(name: "diamond-yellow")
/// AnimatedGIFView(name: "pk-progress-win", fileExtension: "webp")
///     .frame(width: 28, height: 28)
/// ```
struct AnimatedGIFView: UIViewRepresentable {
    let name: String
    /// 资源扩展名。默认 GIF，PK 进度图使用 H5 同源的 animated WebP。
    var fileExtension: String = "gif"
    /// 已废弃，仅保留参数兼容现有调用点；CDN-only 模式不读取本地静态图。
    var fallbackImageName: String?
    /// 未纳入公共 CDN 清单的服务端动图地址（公共资源优先尝试 CDN）。
    var remoteURL: URL?
    /// 每次循环时长（秒）；nil = 使用资源内嵌帧时长求和
    var explicitDuration: TimeInterval?

    private var resourceKey: String {
        "\(name).\(fileExtension)|\(remoteURL?.absoluteString ?? "")|\(explicitDuration ?? -1)"
    }

    final class Coordinator {
        var loadTask: Task<Void, Never>?

        deinit { loadTask?.cancel() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        configure(v, coordinator: context.coordinator)
        // v21 关键：让 UIImageView 尊重 SwiftUI .frame() 约束（否则会按 intrinsicContentSize = gif 原始 56×56 显示，
        // 用户看到的 gif 尺寸 >>> SwiftUI frame 声明；hugging/compression 双低让 SwiftUI 完全接管布局）
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.clipsToBounds = true
        return v
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        // 胜/负/平状态切换时替换动画，不能沿用 UIImageView 的旧 animationImages。
        if uiView.accessibilityIdentifier != resourceKey || uiView.image == nil {
            configure(uiView, coordinator: context.coordinator)
        }
    }

    /// 缓存已解析的动画帧（避免每次 view 创建都重新拆帧）
    private static let cache = NSCache<NSString, UIImage>()

    private func configure(_ imageView: UIImageView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        imageView.stopAnimating()
        imageView.image = nil
        imageView.accessibilityIdentifier = resourceKey

        let urls = [CDNAssetURL.animatedURL(name: name, fileExtension: fileExtension), remoteURL]
            .compactMap { $0 }
        guard !urls.isEmpty else { return }
        let expectedKey = resourceKey
        coordinator.loadTask = Task { [weak imageView] in
            var remoteImage: UIImage?
            for url in urls {
                remoteImage = await Self.remoteAnimatedImage(from: url, duration: explicitDuration)
                if remoteImage != nil { break }
            }
            guard let remoteImage, !Task.isCancelled else { return }
            await MainActor.run {
                guard let imageView, imageView.accessibilityIdentifier == expectedKey else { return }
                imageView.image = remoteImage
                imageView.startAnimating()
            }
        }
    }

    private static func remoteAnimatedImage(from url: URL, duration: TimeInterval?) async -> UIImage? {
        let key = "remote|\(url.absoluteString)|\(duration ?? -1)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let localURL = try? await URLDiskCache.fetch(
            url: url,
            namespace: URLDiskCache.publicAssetNamespace,
            maximumCacheBytes: URLDiskCache.publicAssetCacheLimit
        ), let data = try? Data(contentsOf: localURL) else {
            return nil
        }
        return animatedImage(data: data, cacheKey: key, duration: duration)
    }

    private static func animatedImage(data: Data, cacheKey: NSString, duration: TimeInterval?) -> UIImage? {
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [UIImage] = []
        var totalDuration: TimeInterval = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            totalDuration += Self.frameDelay(source: source, index: i)
        }
        guard !frames.isEmpty else { return nil }

        let dur = duration ?? (totalDuration > 0 ? totalDuration : Double(frames.count) * 0.05)
        let img = UIImage.animatedImage(with: frames, duration: dur)
        if let img { cache.setObject(img, forKey: cacheKey) }
        return img
    }

    /// 读取 GIF / WebP 单帧 delay（优先 UnclampedDelayTime）。
    ///
    /// **v18 修复**：GIF 内嵌 delay 若过小（如 0.02s）会导致播放过快闪烁。加**最小 0.1s 兜底**：
    /// 常见 gif 帧率 10-15fps（0.067-0.1s/帧），iOS 强制不低于 0.1s（10fps）保持视觉稳定
    private static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        let minDelay: TimeInterval = 0.1   // v18: 强制最小 0.1s/帧，避免过快闪烁
        let defaultDelay: TimeInterval = 0.15
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return defaultDelay
        }
        if let webpDict = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let d = webpDict[kCGImagePropertyWebPUnclampedDelayTime] as? TimeInterval, d > 0 {
                return max(d, minDelay)
            }
            if let d = webpDict[kCGImagePropertyWebPDelayTime] as? TimeInterval, d > 0 {
                return max(d, minDelay)
            }
        }
        if let gifDict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let d = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval, d > 0 {
                return max(d, minDelay)
            }
            if let d = gifDict[kCGImagePropertyGIFDelayTime] as? TimeInterval, d > 0 {
                return max(d, minDelay)
            }
        }
        return defaultDelay
    }
}
