#if canImport(UIKit)
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PublicVideoUploader")

/// 一站式公开可见视频上传（Sources/Core/Upload/）。
///
/// 对齐 `ImageUploader` 一站式风格：业务方一行拿 cdnUrl，无需处理凭证 / multipart / URLSession。
/// 与 `OssUploadService.uploadVideo`（acl=private，GiftMessage 私密视频）区分——本类
/// 走 `uploadPublicVideo`（acl=nil，默认继承 bucket policy 公开可见）。
///
/// **用法**：
/// ```swift
/// let url = try await PublicVideoUploader.shared.upload(
///     videoData: data,
///     fileExtension: "mp4"
/// )
/// ```
///
/// **适用**：EditProfile 相册视频 / 来电视频等公开可见的视频上传。
public final class PublicVideoUploader {

    public static let shared = PublicVideoUploader()

    private let credentialService: OssCredentialServiceProtocol
    private let ossService: OssUploadService

    init(credentialService: OssCredentialServiceProtocol = OssCredentialService.shared,
         ossService: OssUploadService = OssUploadService.shared) {
        self.credentialService = credentialService
        self.ossService = ossService
    }

    /// 一站式上传：拿凭证 → PostObject 上传 → 返 cdnUrl。
    /// - parameter videoData: 视频原始数据（.mp4 / .mov）
    /// - parameter fileExtension: 文件扩展名（.mp4 → contentType=video/mp4；其他 → video/mp4 兜底）
    /// - throws: `APIError`（凭证）/ `OssUploadError`（上传）
    public func upload(videoData: Data, fileExtension: String) async throws -> String {
        let credential = try await credentialService.getOssUploadParam()
        let ext = normalizedExtension(fileExtension)
        let objectKey = Self.makeObjectKey(ext: ext)
        let contentType = Self.contentType(for: ext)

        let url = try await ossService.uploadPublicVideo(
            videoData: videoData,
            credential: credential,
            objectKey: objectKey,
            contentType: contentType
        )
        logger.info("upload public video ok ext=\(ext, privacy: .public) bytes=\(videoData.count, privacy: .public)")
        return url
    }

    private func normalizedExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        return ["mp4", "mov"].contains(lower) ? lower : "mp4"
    }

    private static func contentType(for ext: String) -> String {
        switch ext {
        case "mov": return "video/quicktime"
        default:    return "video/mp4"
        }
    }

    /// 对齐 ImageUploader.makeObjectKey pattern：`00000000/{yyyyMMdd}/{UUID}.{ext}`
    /// 时区固定 Asia/Shanghai（CLAUDE.md 时区纪律）。
    private static func makeObjectKey(ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let dateStr = formatter.string(from: Date())
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "00000000/\(dateStr)/\(uuid).\(ext)"
    }
}
#endif
