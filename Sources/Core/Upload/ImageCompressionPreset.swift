import Foundation

/// 图片压缩参数（可被单独构造用于 `.custom`）。
public struct ImageCompressionParams: Equatable {
    /// 触发压缩的阈值（KB）。原图 ≤ 阈值时不压缩，直接输出（若原本是 JPEG 直接返，否则转 JPEG）。
    let compressThresholdKB: Int
    /// 目标大小（KB）。渐进降 quality 直到 ≤ target 或 quality < 0.3。
    let targetKB: Int
    /// JPEG 起始 quality（迭代降阶起点）。
    let jpegQuality: Double
    /// 缩略图最大边长（像素）。`CGImageSource` thumbnail 管线用此上限（防 OOM）。
    let thumbnailMaxPixel: Int
    /// 原图大小硬顶（KB）。超过 → `ImageCompressor` throw `.originalTooLarge`，让业务层拒图。
    let maxRawKB: Int

    public init(compressThresholdKB: Int,
                targetKB: Int,
                jpegQuality: Double,
                thumbnailMaxPixel: Int,
                maxRawKB: Int) {
        self.compressThresholdKB = compressThresholdKB
        self.targetKB = targetKB
        self.jpegQuality = jpegQuality
        self.thumbnailMaxPixel = thumbnailMaxPixel
        self.maxRawKB = maxRawKB
    }
}

/// 图片压缩预设 —— 按场景选，业务方无需了解参数细节。
///
/// **添加新预设指南**：如果新场景与现有 3 个预设都不匹配，请优先加 case（而不是滥用 `.custom`）——
/// 让"哪些场景用什么压缩策略"作为工程知识沉淀在此 enum。
///
/// **参数选取原则**（jpegQuality × maxPixel × target 三者协同）：
/// - 展示尺寸大（朋友圈图/相册）→ 高 quality + 高像素上限
/// - 展示尺寸小（头像/缩略图）→ 低像素上限起主导，quality 中等即可
/// - 压缩优先场景（反馈/日志上传）→ 低 quality + 中等像素，追求小体积
public enum ImageCompressionPreset {

    /// **默认**：朋友圈发布 / 相册照片。对齐 H5 `useOssHooks.js`：
    /// 触发 300KB，目标 2MB，quality 0.7，最大边 2048px，原图硬顶 10MB。
    case moment

    /// **激进**：反馈截图 / bug 上报 / 日志附件 —— 用户能看清即可，追求最小体积。
    /// 触发 100KB，目标 500KB，quality 0.5，最大边 1280px，原图硬顶 10MB。
    case feedback

    /// **头像**：正方形小图，极致压缩。展示尺寸小（36-96pt），肉眼分辨不出 quality 差异。
    /// 触发 50KB，目标 200KB，quality 0.6，最大边 800px，原图硬顶 5MB。
    case avatar

    /// 完全自定义参数。**仅用于已存 3 个预设不覆盖的边缘场景**——考虑加新 case 而不是长期用 custom。
    case custom(ImageCompressionParams)

    /// 返回预设参数。
    public var params: ImageCompressionParams {
        switch self {
        case .moment:
            return ImageCompressionParams(
                compressThresholdKB: 300,
                targetKB: 2048,
                jpegQuality: 0.7,
                thumbnailMaxPixel: 2048,
                maxRawKB: 10_240
            )
        case .feedback:
            return ImageCompressionParams(
                compressThresholdKB: 100,
                targetKB: 500,
                jpegQuality: 0.5,
                thumbnailMaxPixel: 1280,
                maxRawKB: 10_240
            )
        case .avatar:
            return ImageCompressionParams(
                compressThresholdKB: 50,
                targetKB: 200,
                jpegQuality: 0.6,
                thumbnailMaxPixel: 800,
                maxRawKB: 5_120
            )
        case .custom(let params):
            return params
        }
    }
}
