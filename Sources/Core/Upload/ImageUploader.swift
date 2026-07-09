#if canImport(UIKit)
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "ImageUploader")

/// 一站式图片上传 —— 通用能力（Sources/Core/Upload/）。
///
/// **用法**：单张图 raw data → 一行调用拿到 OSS cdnUrl，业务方无需处理压缩 / 凭证 / multipart / URLSession。
/// ```swift
/// // 反馈截图（激进压缩）
/// let url = try await ImageUploader.shared.upload(rawData: screenshotData, preset: .feedback)
///
/// // 头像
/// let url = try await ImageUploader.shared.upload(rawData: avatarData, preset: .avatar)
///
/// // 自定义参数
/// let url = try await ImageUploader.shared.upload(
///     rawData: data,
///     preset: .custom(ImageCompressionParams(compressThresholdKB: 200, ...))
/// )
/// ```
///
/// **适用场景**：单张、无并发、无重试要求的简单上传。
///
/// **不适用**：多张并发上传 + 部分失败保留 uploadedUrls + STS 过期自动重拉 —— 这类复杂 orchestration
/// 场景（如朋友圈发布 9 张图并发上传）应直接注入 `OssCredentialService.shared` + `OssUploadService.shared`
/// 自己写状态机（参考 [PostPublishViewModel](../../Home/Circle/Publish/PostPublishViewModel.swift)）。
public final class ImageUploader {

    public static let shared = ImageUploader()

    private let credentialService: OssCredentialServiceProtocol
    private let ossService: OssUploadServiceProtocol

    init(credentialService: OssCredentialServiceProtocol = OssCredentialService.shared,
         ossService: OssUploadServiceProtocol = OssUploadService.shared) {
        self.credentialService = credentialService
        self.ossService = ossService
    }

    /// 一站式上传：压缩 → 拿凭证 → PostObject 上传 → 返 cdnUrl。
    /// - parameter rawData: 原始图片数据（HEIC/PNG/JPG）
    /// - parameter preset: 压缩预设（默认 `.moment`）
    /// - throws: `ImageCompressor.CompressError` / `APIError` / `OssUploadError`
    public func upload(rawData: Data,
                       preset: ImageCompressionPreset = .moment) async throws -> String {
        // 1. 压缩
        let compressed = try ImageCompressor.compress(rawData: rawData, preset: preset)
        // 2. 拿凭证
        let credential = try await credentialService.getOssUploadParam()
        // 3. 拼 object key
        let objectKey = Self.makeObjectKey()
        // 4. 上传
        let url = try await ossService.uploadImage(
            imageData: compressed,
            credential: credential,
            objectKey: objectKey
        )
        logger.info("upload ok preset=\(String(describing: preset), privacy: .public)")
        return url
    }

    /// 批量上传（顺序）。任一失败 → 已成功的 url 保留，failed 处直接 throw。
    /// 简化版：不做 STS 凭证自动重拉；场景是"少量图 + 用户可接受重试"。
    /// - returns: (成功的 url 列表, 失败在第几个 idx nil 表示全部成功)
    public func uploadSerial(rawDataList: [Data],
                             preset: ImageCompressionPreset = .moment) async -> (urls: [String], failedAt: Int?) {
        var urls: [String] = []
        for (idx, raw) in rawDataList.enumerated() {
            do {
                let url = try await upload(rawData: raw, preset: preset)
                urls.append(url)
            } catch {
                logger.error("uploadSerial idx=\(idx, privacy: .public) failed: \(String(describing: error))")
                return (urls, idx)
            }
        }
        return (urls, nil)
    }

    /// 拼 OSS object key：`00000000/{yyyyMMdd}/{UUID}.jpg`（对齐安卓 OssInternationStationKtx）。
    /// 时区固定 Asia/Shanghai（CLAUDE.md 时区纪律）。
    private static func makeObjectKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let dateStr = formatter.string(from: Date())
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "00000000/\(dateStr)/\(uuid).jpg"
    }
}
#endif
