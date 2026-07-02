import SwiftUI

/// K 需求 4（2026-07-02）：贴纸元数据。
///
/// 数据源：`Vendor/FaceUnity/bundles/stickers/*.bundle`（8 张，2026-07-02 从 Faceunity/FULiveDemo
/// `FULiveDemo/Resource/Sticker/` 拷入）
///
/// **bundle 命名约束**：`id` 必须与 `.bundle` 文件名前缀完全一致（大小写敏感），
/// 内部走 `FUManager.loadSticker:` → `[NSBundle mainBundle] pathForResource:ofType:@"bundle"]`
///
/// **未来加/删贴纸**：
/// 1. 拷 / 删 `.bundle` 到 `Vendor/FaceUnity/bundles/stickers/`
/// 2. 修改本表 `items` 数组（加行 or 删行）
/// 3. `xcodegen generate && LANG=en_US.UTF-8 pod install`
enum BeautyStickerCatalog {
    struct Item: Identifiable {
        let id: String       // bundle 文件名（不含 .bundle 扩展名）
        let label: String    // UI 显示 label
        let iconSymbol: String  // SF Symbol 占位（未来可换真图缩略图）
    }

    /// 首发 8 张贴纸（对齐 `Vendor/FaceUnity/bundles/stickers/` 实际 bundle）
    static let items: [Item] = [
        .init(id: "CatSparks",     label: "Sparks",       iconSymbol: "sparkle"),
        .init(id: "DaisyPig",      label: "Pig",          iconSymbol: "pawprint.fill"),
        .init(id: "newy1",         label: "New Year",     iconSymbol: "gift.fill"),
        .init(id: "redribbt",      label: "Ribbon",       iconSymbol: "giftcard.fill"),
        .init(id: "fu_zh_fenshu",  label: "Score",        iconSymbol: "number.circle.fill"),
        .init(id: "sdlr",          label: "Cute 1",       iconSymbol: "face.smiling"),
        .init(id: "sdlu",          label: "Cute 2",       iconSymbol: "face.smiling.inverse"),
        .init(id: "xlong_zh_fu",   label: "Fortune",      iconSymbol: "star.circle.fill"),
    ]
}
