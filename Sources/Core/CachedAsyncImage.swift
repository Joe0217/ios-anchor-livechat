import SwiftUI

/// SwiftUI `AsyncImage` 替代品：内存 + 磁盘缓存命中后立即同步显示，无闪烁。
///
/// 命中策略：
/// - body 渲染时先同步查 `ImageCache.shared.cached(url)` 立即赋初值
///   → 内存里有图就**首次渲染就是最终图**，看不到 placeholder 闪烁
/// - .task(id: url) 兜底：URL 变化或首次拉取走网络
///
/// 用法（与 AsyncImage 类似）：
/// ```
/// CachedAsyncImage(url: vm.iconURL, contentMode: .fill) {
///     Color.gray.opacity(0.3)  // placeholder
/// }
/// ```
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// 是否写入持久缓存（NSCache + URLCache）。
    /// `true`（默认）：本人头像 / 相册 / 视频封面 / 礼物图等需要跨 view 持久的资源
    /// `false`：他人头像等不需要持久化的临时资源 —— view dismount 后即丢
    var persistent: Bool = true
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var lastLoadedURL: URL?

    init(url: URL?,
         contentMode: ContentMode = .fill,
         persistent: Bool = true,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.persistent = persistent
        self.placeholder = placeholder
        // 同步预填：无论 persistent 都查 NSCache（读不写）。这样 persistent=false 的
        // 调用方（如他人头像）若 URL 恰好等于本人头像（已被 persistent=true 写入缓存），
        // 仍能复用而非重拉。
        if let url, let cached = ImageCache.shared.cached(for: url) {
            _image = State(initialValue: cached)
            _lastLoadedURL = State(initialValue: url)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            lastLoadedURL = nil
            return
        }
        if url == lastLoadedURL, image != nil { return }
        // 无论 persistent，先查内存（命中即用，复用他人传 false 时本人头像缓存）
        if let cached = ImageCache.shared.cached(for: url) {
            image = cached
            lastLoadedURL = url
            return
        }
        // 未命中走网络：persistent 决定是否写入 NSCache + URLCache
        let fetched: UIImage?
        if persistent {
            fetched = await ImageCache.shared.fetch(url)
        } else {
            fetched = await ImageCache.shared.fetchEphemeral(url)
        }
        if self.url == url {
            image = fetched
            lastLoadedURL = url
        }
    }
}
