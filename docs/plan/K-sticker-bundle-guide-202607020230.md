# Sticker Bundles

**用户拷 bundle 步骤**（K 需求 4，2026-07-02）：

1. Clone [Faceunity/FULiveDemo](https://github.com/Faceunity/FULiveDemo)
2. 进 `FULiveDemo/Resource/` 找 sticker `.bundle` 文件
3. 拷到本目录（保留 `.bundle` 后缀）
4. `xcodegen generate && LANG=en_US.UTF-8 pod install`
5. 真机运行 → BeautySettings → 贴纸 tab 点某项立即生效

**Bundle 命名约定**：
- 文件名前缀（去掉 `.bundle`）= `Sources/Beauty/Settings/BeautyStickerCatalog.swift` 里的 `id` 字段
- 首发 6 张：BlueMask / XingGanHuZi / DaisyPig / CatSparks / HeartEyes / Christmas

**加/改贴纸**：
- 拷更多 bundle 后，在 `BeautyStickerCatalog.swift` 里 append `Item(id:, label:, iconSymbol:)`
- id 必须与 bundle 前缀完全一致（大小写敏感）

**放置于 .gitignore（如商业授权）**：本目录已在 `Vendor/FaceUnity/.gitignore` 内，bundle 不入库。
