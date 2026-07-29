import SwiftUI
import UIKit

/// H5 `chat-bubble-custom` 的统一尺寸。
///
/// H5 通过 `border-width: 14px 24px` 预留文字内容区；所有聊天场景共用这套尺寸，
/// 防止私聊、公屏和通话使用同一张皮肤时出现不同的边距。
enum ChatSkinMetrics {
    static let horizontalContentInset: CGFloat = 24
    /// H5 `border-image-width: 32px 44px`，是皮肤四周实际可见的装饰宽度。
    static let horizontalBorderWidth: CGFloat = 44
    static let verticalBorderWidth: CGFloat = 32
    /// H5 `border-width: 14px 24px` 的内容区上下边距。
    static let verticalContentInset: CGFloat = 14
    /// 皮肤挂饰视觉会超出普通气泡的紧凑感，行与行之间额外预留的空间。
    static let messageVerticalSpacing: CGFloat = 4
    /// 直播公屏的皮肤文字行采用更紧凑的外部行距；不影响气泡内容区高度。
    static let livePublicMessageVerticalSpacing: CGFloat = 2
    /// H5 图源以 63/87 像素切片，渲染为 32/44 CSS px，接近 2x 缩放。
    static let sourceScale: CGFloat = 2
}

/// H5 Chat Skin 的点九图背景。
///
/// H5 CSS：`border-image-slice: 63 87 63 87 fill; border-image-width: 32px 44px`。
/// 先以 2x 逻辑尺寸载入图源，再使用 32/44pt cap inset，等价于 H5 的切片与显示尺寸。
///
/// 不能直接使用 `CachedAsyncImage`，因为它没有暴露九宫格拉伸能力；下载与缓存仍复用
/// `ImageCache`，避免同一气泡图片在每条消息中重复请求。
struct NinePatchImageView: View {
    let url: URL?
    let capInsets: UIEdgeInsets

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    init(
        url: URL?,
        capInsets: UIEdgeInsets = .init(
            top: ChatSkinMetrics.verticalBorderWidth,
            left: ChatSkinMetrics.horizontalBorderWidth,
            bottom: ChatSkinMetrics.verticalBorderWidth,
            right: ChatSkinMetrics.horizontalBorderWidth
        )
    ) {
        self.url = Self.safeRemoteURL(url)
        self.capInsets = capInsets
        if let url = self.url, let cached = ImageCache.shared.cached(for: url) {
            _image = State(initialValue: Self.h5SizedImage(from: cached))
            _loadedURL = State(initialValue: url)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable(capInsets: EdgeInsets(
                        top: capInsets.top,
                        leading: capInsets.left,
                        bottom: capInsets.bottom,
                        trailing: capInsets.right
                    ), resizingMode: .stretch)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else {
            image = nil
            loadedURL = nil
            return
        }
        if loadedURL == url, image != nil { return }

        if let cached = ImageCache.shared.cached(for: url) {
            image = Self.h5SizedImage(from: cached)
            loadedURL = url
            return
        }

        let fetched = await ImageCache.shared.fetch(url)
        guard !Task.isCancelled, self.url == url else { return }
        image = fetched.map(Self.h5SizedImage(from:))
        loadedURL = fetched == nil ? nil : url
    }

    private static func h5SizedImage(from source: UIImage) -> UIImage {
        guard let cgImage = source.cgImage else { return source }
        return UIImage(cgImage: cgImage, scale: ChatSkinMetrics.sourceScale, orientation: source.imageOrientation)
    }

    private static func safeRemoteURL(_ url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
