import SwiftUI

/// K spec §4.4：11 首发滤镜元数据（key + L10n label + 缩略图占位 SF Symbol）。
///
/// **缩略图占位策略**（Q3 (a) 实施债）：
/// 本期用 SF Symbol + brand color 作缩略图占位；生产真图由用户跑相芯 SDK 生成脚本
/// 应用 filter 到 60×60 自拍图，一次性烘焙进 `Assets.xcassets/BeautyFilterThumbnails/`。
/// 有真图后，UI 层从 SF Symbol 切到 `Image("BeautyFilterThumbnails/\(key)")`。
enum BeautyFilterCatalog {
    struct Item: Identifiable {
        let id: String
        let key: String
        let label: String
        /// SF Symbol 占位（未来替换为 asset image name）
        let placeholderSymbol: String
        let placeholderTint: Color

        init(_ key: String, label: String, symbol: String, tint: Color) {
            self.id = key
            self.key = key
            self.label = label
            self.placeholderSymbol = symbol
            self.placeholderTint = tint
        }
    }

    /// 按 UI 展示顺序（与 §4.4 白名单顺序一致）
    static let items: [Item] = [
        .init(FilterKey.origin,      label: L10n.BeautySettings.filterOrigin,      symbol: "camera.circle",         tint: Theme.Palette.textSecondary),
        .init(FilterKey.ziran1,      label: L10n.BeautySettings.filterZiran,       symbol: "leaf.fill",             tint: Color(hex: 0x74C69D)),
        .init(FilterKey.zhiganhui1,  label: L10n.BeautySettings.filterZhiganhui,   symbol: "square.grid.3x3.fill",  tint: Color(hex: 0x8D99AE)),
        .init(FilterKey.mitao1,      label: L10n.BeautySettings.filterMitao,       symbol: "circle.hexagongrid",    tint: Color(hex: 0xFFB4A2)),
        .init(FilterKey.bailiang1,   label: L10n.BeautySettings.filterBailiang,    symbol: "sun.max.fill",          tint: Color(hex: 0xFFE066)),
        .init(FilterKey.fennen1,     label: L10n.BeautySettings.filterFennen,      symbol: "sparkles",              tint: Color(hex: 0xFFC2E2)),
        .init(FilterKey.lengsediao1, label: L10n.BeautySettings.filterLengsediao,  symbol: "snowflake",             tint: Color(hex: 0x9AD4F5)),
        .init(FilterKey.nuansediao1, label: L10n.BeautySettings.filterNuansediao,  symbol: "flame.fill",            tint: Color(hex: 0xFF9F5A)),
        .init(FilterKey.gexing1,     label: L10n.BeautySettings.filterGexing,      symbol: "bolt.fill",             tint: Color(hex: 0xC77DFF)),
        .init(FilterKey.xiaoqingxin1,label: L10n.BeautySettings.filterXiaoqingxin, symbol: "cloud.sun.fill",        tint: Color(hex: 0xB5EAD7)),
        .init(FilterKey.heibai1,     label: L10n.BeautySettings.filterHeibai,      symbol: "circle.lefthalf.filled", tint: Color.white),
    ]
}
