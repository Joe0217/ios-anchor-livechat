import SwiftUI

/// PK notify 富文本片段（H5 pk_notification 用 v-html 拼接混排 img+span）。
/// iOS 侧用离散 segment 数组承载，Row 内按顺序渲染 —— 避免解析 HTML。
enum RichSegment: Equatable {
    case text(String, color: Color = .white)
    case iconURL(String, size: CGSize)
    case highlight(String, color: Color)
}
