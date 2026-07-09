#if canImport(UIKit)
import UIKit
import ImageIO

/// 图片压缩工具 —— 通用能力（Sources/Core/Upload/）。
///
/// **职责**（纯函数式，UIKit only，无 ViewModel 依赖）：
/// 1. **原图硬顶拦截**：`preset.maxRawKB` 以上直接 throw `.originalTooLarge`，业务层拒图
/// 2. **HEIC/Live Photo/大图安全解码**：用 `CGImageSourceCreateThumbnailAtIndex` 限制 `preset.thumbnailMaxPixel`
///    防 OOM（iPhone 4032×3024 多张直接 UIImage(data:) 老机型会 OOM）
/// 3. **压缩**：仅当 > `preset.compressThresholdKB` 时；目标 ≤ `preset.targetKB`；起始 quality 由 preset 定
/// 4. **fallback**：压缩失败（极小概率）回退原图（已知 ≤ maxRawKB 安全）
/// 5. **EXIF GPS strip**：转 JPEG 走 jpegData 路径，GPS 自然丢弃（隐私）
///
/// **调用方**：通过 [ImageCompressionPreset](ImageCompressionPreset.swift) 选择场景化预设，
/// 或用 `.custom(ImageCompressionParams(...))` 微调。
public enum ImageCompressor {

    public enum CompressError: Error, Equatable {
        /// 原图超过 preset.maxRawKB
        case originalTooLarge(bytes: Int)
        /// 解码失败（数据损坏 / 不支持的格式）
        case decodeFailed
        /// 压缩失败且 fallback 也失败（理论不可达）
        case compressFailed
    }

    /// 主入口：原始数据（HEIC/PNG/JPG）→ 压缩后 JPEG 数据。
    /// - parameter rawData: 原始图片数据
    /// - parameter preset: 压缩预设（默认 `.moment` = 朋友圈参数，对齐 H5 useOssHooks.js）
    /// - throws: `CompressError`
    public static func compress(rawData: Data,
                                preset: ImageCompressionPreset = .moment) throws -> Data {
        try compress(rawData: rawData, params: preset.params)
    }

    /// 参数化入口（供单测注入极端参数验证边界）。
    public static func compress(rawData: Data, params: ImageCompressionParams) throws -> Data {
        // 1. 原图硬顶拦截
        let rawKB = rawData.count / 1024
        guard rawKB <= params.maxRawKB else {
            throw CompressError.originalTooLarge(bytes: rawData.count)
        }

        // 2. 安全解码（HEIC 等大图走 thumbnail 管线）
        guard let image = decodeSafely(data: rawData, maxPixel: params.thumbnailMaxPixel) else {
            throw CompressError.decodeFailed
        }

        // 3. 是否需要压缩
        if rawKB <= params.compressThresholdKB {
            // 已小于阈值 + 原是 JPEG → 直接返；HEIC/PNG 也需转 JPEG 保证 Content-Type 统一
            if isJpeg(data: rawData) {
                return rawData
            }
            if let jpeg = image.jpegData(compressionQuality: params.jpegQuality) {
                return jpeg
            }
            throw CompressError.compressFailed
        }

        // 4. 迭代降阶压缩到 ≤ targetKB
        if let compressed = compressIteratively(image: image,
                                                targetKB: params.targetKB,
                                                initialQuality: params.jpegQuality) {
            return compressed
        }

        // 5. fallback 原图（已知 ≤ maxRawKB 安全；转 JPEG 防 content-type 不一致）
        if let jpeg = image.jpegData(compressionQuality: params.jpegQuality) {
            return jpeg
        }
        throw CompressError.compressFailed
    }

    // MARK: - Internals

    /// 安全解码：HEIC/大图走 CGImageSource thumbnail 管线限制最大像素。
    /// 防 OOM；保留 orientation；EXIF GPS 在转 JPEG 时自然 strip。
    private static func decodeSafely(data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // 保留 orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// 渐进降阶压缩：从 initialQuality 起，每次 -0.1 直到 ≤ targetKB 或 quality < 0.3。
    private static func compressIteratively(image: UIImage,
                                            targetKB: Int,
                                            initialQuality: Double) -> Data? {
        var quality = initialQuality
        while quality >= 0.3 {
            guard let data = image.jpegData(compressionQuality: quality) else {
                return nil
            }
            if data.count / 1024 <= targetKB {
                return data
            }
            quality -= 0.1
        }
        // 最低质量仍超目标，返最低质量数据（已是最小，让上层决定是否拒）
        return image.jpegData(compressionQuality: 0.3)
    }

    /// 简单嗅探：JPEG 文件头 `FF D8 FF`
    private static func isJpeg(data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        return data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }
}
#endif
