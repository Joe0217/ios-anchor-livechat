import SwiftUI

/// 通用头像框（对齐 H5 `components/head-frame.vue`）。
///
/// **职责**：按 URL 语义分流 —— SVGA 动画（远端循环播放）/ 静态图（PNG/WebP）。
///
/// **URL 判断对齐 H5**：`toLowerCase().includes('.svga')` —— 用 `contains` 而非 `hasSuffix`，
/// 因后端 URL 常带 query string（如 `xxx.svga?token=abc`），`hasSuffix` 会 miss。
///
/// **用法**：
/// ```swift
/// HeadFrameView(urlString: user.headFrame, size: 55)
///     .allowsHitTesting(false)     // 装饰层不响应点击
/// ```
struct HeadFrameView: View {
    let urlString: String?
    let size: CGFloat

    /// H5 对齐：任何 URL 内含 `.svga`（不区分大小写）→ SVGA；否则静态图
    static func isSVGAURL(_ raw: String) -> Bool {
        raw.lowercased().contains(".svga")
    }

    var body: some View {
        if let raw = urlString, !raw.isEmpty {
            if Self.isSVGAURL(raw) {
                RemoteSVGAImageView(url: URL(string: raw),
                                    loops: 0,
                                    contentMode: .scaleAspectFit)
                    .frame(width: size, height: size)
            } else {
                CachedAsyncImage(url: URL(string: raw),
                                 contentMode: .fit,
                                 persistent: true) {
                    Color.clear
                }
                .frame(width: size, height: size)
            }
        }
    }
}
