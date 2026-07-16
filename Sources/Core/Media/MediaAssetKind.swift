import Foundation

/// 远端媒体资源类型（按 URL 后缀分流）。
///
/// 用途：跨 UI dispatch 层 + 渲染层共用同一识别逻辑，避免"新增格式时两处忘同步"漂移
/// （对齐 code-review §15 altitude 建议 —— 派对房背景当前为唯一使用点，未来扩到礼物/头饰/朋友圈时复用）。
///
/// **对齐 H5 `room-bg.vue:19-26 bgType computed`**：
/// - `.svga` → SVGA
/// - `.mp4` → MP4
/// - 其他 → image（含 png/jpg/webp/gif/...；animated gif 由图片层的 SDWebImage/CachedAsyncImage 自行处理）
enum MediaAssetKind: Equatable {
    case image
    case svga
    case mp4

    /// 从 URL 字符串识别。允许 query string（先切 `?`）；大小写不敏感。
    init(urlString: String) {
        let path = urlString.split(separator: "?").first.map(String.init) ?? urlString
        let lower = path.lowercased()
        if lower.hasSuffix(".svga") { self = .svga }
        else if lower.hasSuffix(".mp4") { self = .mp4 }
        else { self = .image }
    }

    init(url: URL) {
        self.init(urlString: url.absoluteString)
    }
}
