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
    /// 动图资源不可用时的静态 asset 名，避免关键 UI 留空。
    var fallbackImageName: String?
    /// 本地 bundle 尚未包含资源时使用的远端地址。用于与 H5 同源的 animated WebP 灰度资源。
    var remoteURL: URL?
    /// 每次循环时长（秒）；nil = 使用资源内嵌帧时长求和
    var explicitDuration: TimeInterval?

    private var resourceKey: String {
        "\(name).\(fileExtension)|\(remoteURL?.absoluteString ?? "")"
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
        let localImage = Self.animatedImage(name: name, fileExtension: fileExtension, duration: explicitDuration)

        imageView.stopAnimating()
        imageView.image = localImage ?? fallbackImageName.flatMap(UIImage.init(named:))
        imageView.accessibilityIdentifier = resourceKey
        imageView.startAnimating()

        // 正常包体优先使用本地资源。旧工程尚未收录新 WebP 时，直接使用 H5 同源动图，
        // 期间保留静态 fallback，网络失败也不会出现空白。
        guard localImage == nil, let remoteURL else { return }
        let expectedKey = resourceKey
        coordinator.loadTask = Task { [weak imageView] in
            guard let remoteImage = await Self.remoteAnimatedImage(from: remoteURL), !Task.isCancelled else { return }
            await MainActor.run {
                guard let imageView, imageView.accessibilityIdentifier == expectedKey else { return }
                imageView.image = remoteImage
                imageView.startAnimating()
            }
        }
    }

    /// 从 Sources/Assets/GIFs 加载 GIF / animated WebP 并拆帧。
    static func animatedImage(name: String, fileExtension: String, duration: TimeInterval?) -> UIImage? {
        let key = "\(name).\(fileExtension)|\(duration ?? -1)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // Xcode 对 resource folder 的打包形态因构建设置而异：可能平铺在 bundle 根目录，
        // 也可能保留 GIFs 子目录。两种路径都支持，避免真机取不到资源导致中心图空白。
        let url = Bundle.main.url(forResource: name, withExtension: fileExtension)
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "GIFs")
        guard let url,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return animatedImage(data: data, cacheKey: key, duration: duration)
    }

    private static func remoteAnimatedImage(from url: URL) async -> UIImage? {
        let key = "remote|\(url.absoluteString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return animatedImage(data: data, cacheKey: key, duration: nil)
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
