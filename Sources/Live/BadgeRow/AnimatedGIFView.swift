import SwiftUI
import UIKit
import ImageIO

/// v17 GIF 动图渲染 —— SwiftUI 包装 UIImageView 帧动画
///
/// **设计**：无第三方依赖，用 iOS 原生 ImageIO 拆 gif 帧 → UIImage.animatedImage(with:duration:) 播放
///
/// **用法**：
/// ```swift
/// AnimatedGIFView(name: "diamond-yellow")   // Sources/Assets/GIFs/diamond-yellow.gif
///     .frame(width: 28, height: 28)
/// ```
struct AnimatedGIFView: UIViewRepresentable {
    let name: String
    /// 每次循环时长（秒）；nil = 使用 gif 内嵌 delay 求和
    var explicitDuration: TimeInterval?

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.image = Self.animatedImage(gifName: name, duration: explicitDuration)
        v.startAnimating()
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
        // 静态资源不需要 update；如果 name 变了才重建
        if uiView.animationImages == nil {
            uiView.image = Self.animatedImage(gifName: name, duration: explicitDuration)
            uiView.startAnimating()
        }
    }

    /// 缓存已解析的 gif 帧（避免每次 view 创建都重新拆帧）
    private static let cache = NSCache<NSString, UIImage>()

    /// 从 Sources/Assets/GIFs/<name>.gif 加载 gif 并拆帧为 UIImage.animatedImage
    static func animatedImage(gifName: String, duration: TimeInterval?) -> UIImage? {
        let key = "\(gifName)|\(duration ?? -1)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let url = Bundle.main.url(forResource: gifName, withExtension: "gif"),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
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
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    /// 读取 gif 单帧 delay（对齐 gif spec：DelayTime / UnclampedDelayTime）
    ///
    /// **v18 修复**：GIF 内嵌 delay 若过小（如 0.02s）会导致播放过快闪烁。加**最小 0.1s 兜底**：
    /// 常见 gif 帧率 10-15fps（0.067-0.1s/帧），iOS 强制不低于 0.1s（10fps）保持视觉稳定
    private static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        let minDelay: TimeInterval = 0.1   // v18: 强制最小 0.1s/帧，避免过快闪烁
        let defaultDelay: TimeInterval = 0.15
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let gifDict = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
            return defaultDelay
        }
        if let d = gifDict[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval, d > 0 {
            return max(d, minDelay)
        }
        if let d = gifDict[kCGImagePropertyGIFDelayTime as String] as? TimeInterval, d > 0 {
            return max(d, minDelay)
        }
        return defaultDelay
    }
}
