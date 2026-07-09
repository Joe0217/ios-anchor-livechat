import SwiftUI

/// 图片消息气泡（H-2 spec §1 表 1.2，对齐 H5 `msgItem.vue:256-259`）。
///
/// **视觉**：宽 100 圆角 16，异步加载 CDN URL，失败显破图占位。
struct ImageBubbleView: View {
    let url: URL

    var body: some View {
        // 走 ImageCache 持久缓存（persistent: true），滚动回来不重新下载。
        // failure/empty 合并 placeholder 视觉（Chat 场景失败率低；命中率优先）。
        CachedAsyncImage(url: url, contentMode: .fill, persistent: true) {
            placeholder
        }
        .frame(width: ChatConstants.imageBubbleWidth, height: ChatConstants.imageBubbleWidth * 1.25)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var placeholder: some View {
        ChatPalette.cardBackground
            .overlay { ProgressView().tint(.white.opacity(0.5)) }
    }
}
