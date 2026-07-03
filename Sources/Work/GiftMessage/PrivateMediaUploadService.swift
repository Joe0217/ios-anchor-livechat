import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PrivateMediaUploadService")

/// 私密媒体 OSS 上传服务（H-2 spec §2.3 / §5.2 真实现，step 1c）。
///
/// **图片路径**：走 [ImageUploader](../../Core/Upload/ImageUploader.swift) 一站式封装
///   （自动压缩 + 拿凭证 + PostObject 上传，`.moment` 预设）
///
/// **视频路径**：
///   1. 校验扩展名（R-16 白名单：`.mp4/.mov`）
///   2. 校验尺寸（R-17：≤50MB）
///   3. 拿凭证（复用 OssCredentialService，假设视频与图片同一 `/sts/getOssUploadParam`）
///   4. 拼 objectKey（保留原扩展名 → `.mp4/.mov`）
///   5. 走 [OssUploadService.uploadVideo](../../Core/Upload/OssUploadService.swift)
///      （60s timeout URLSession + `x-oss-object-acl: private`）
///
/// spec §6 Q1 未确认视频凭证接口是否与图片同源，先按同源实现；抓包如发现独立 STS，
/// 扩 [OssCredentialServiceProtocol](../../Core/Upload/OssCredentialServiceProtocol.swift) 新方法。
final class PrivateMediaUploadService: PrivateMediaUploadServiceProtocol {

    static let shared = PrivateMediaUploadService()

    /// 视频扩展名白名单（R-16 spec §Q5）
    private static let allowedVideoExts: Set<String> = ["mp4", "mov"]
    /// 视频最大尺寸 50MB（R-17 spec §Q4）
    private static let maxVideoBytes: Int = 50 * 1024 * 1024

    private let credentialService: OssCredentialServiceProtocol
    private let ossService: OssUploadServiceProtocol
    private let imageUploader: ImageUploader

    init(credentialService: OssCredentialServiceProtocol = OssCredentialService.shared,
         ossService: OssUploadServiceProtocol = OssUploadService.shared,
         imageUploader: ImageUploader = ImageUploader.shared) {
        self.credentialService = credentialService
        self.ossService = ossService
        self.imageUploader = imageUploader
    }

    func uploadImage(_ data: Data) async throws -> String {
        // .moment 预设：压缩后 ≤800KB、长边 ≤1080（对齐朋友圈；私密图片同规格）
        try await imageUploader.upload(rawData: data, preset: .moment)
    }

    func uploadVideo(fileURL: URL) async throws -> String {
        // 1. 扩展名白名单（R-16）
        let ext = fileURL.pathExtension.lowercased()
        guard Self.allowedVideoExts.contains(ext) else {
            logger.warning("uploadVideo unsupported ext=\(ext, privacy: .public)")
            throw GiftMessageServiceError.unsupportedVideoFormat(ext)
        }

        // 2. 读取 + 尺寸校验（R-17）
        let videoData: Data
        do {
            videoData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            logger.error("uploadVideo read file failed: \(String(describing: error), privacy: .public)")
            throw GiftMessageServiceError.invalidVideoFile
        }
        guard videoData.count <= Self.maxVideoBytes else {
            logger.warning("uploadVideo too large bytes=\(videoData.count, privacy: .public)")
            throw GiftMessageServiceError.videoTooLarge(sizeBytes: videoData.count)
        }

        // 3. 拿凭证（复用 OssCredentialService）
        let credential = try await credentialService.getOssUploadParam()

        // 4. 拼 objectKey（保留原扩展名）
        let objectKey = Self.makeVideoObjectKey(ext: ext)

        // 5. 上传（走 videoSession 60s timeout + acl=private）
        let contentType = Self.contentType(for: ext)
        let url = try await ossService.uploadVideo(
            videoData: videoData,
            credential: credential,
            objectKey: objectKey,
            contentType: contentType
        )
        logger.info("uploadVideo ok bytes=\(videoData.count, privacy: .public) ext=\(ext, privacy: .public)")
        return url
    }

    // MARK: - Helpers

    /// 拼 OSS object key：`00000000/{yyyyMMdd}/{UUID}.<ext>`（对齐 [ImageUploader.makeObjectKey](../../Core/Upload/ImageUploader.swift)）。
    /// 时区 Asia/Shanghai（CLAUDE.md 时区纪律）。
    static func makeVideoObjectKey(ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let dateStr = formatter.string(from: Date())
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "00000000/\(dateStr)/\(uuid).\(ext)"
    }

    /// 视频 MIME（R-16 按扩展名动态映射，非硬编 mp4）。
    static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp4":  return "video/mp4"
        case "mov":  return "video/quicktime"
        default:     return "application/octet-stream"    // 兜底（此分支已被白名单挡住）
        }
    }
}
