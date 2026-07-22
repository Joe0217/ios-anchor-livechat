import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "OssUploadService")

/// OSS PostObject 表单直传真实现（J spec §3.2 + INV1 / Step 2）。
///
/// **职责**：拼 multipart body（[OssMultipartBodyBuilder](OssMultipartBodyBuilder.swift)）+ POST 到 credential.host。
///
/// **不变量**：
/// - **不走 APIClient**（INV1，OSS 不要业务加密，不要双 token）
/// - **单例 URLSession + httpMaximumConnectionsPerHost = 6**（红队 #11：复用 TLS 连接避免 9 张图 9 次握手）
/// - 200 视为成功；非 200 抛 `OssUploadError.http(statusCode:, body:)`，让 ViewModel 识别 SecurityTokenExpired 等
final class OssUploadService: OssUploadServiceProtocol {

    static let shared = OssUploadService()

    /// 单例 URLSession（INV1 + 红队 #11）。
    /// 复用 TLS / TCP 连接，9 张图并发上传只握手 1 次。
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6  // OSS 推荐
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        // OSS 凭证短期有效，不缓存请求
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// 视频专用 URLSession（H-2 spec §R-18）。
    /// 视频体积可达 50MB，慢网 30s 不够，专用 timeout 60s / resource 300s。
    /// 独立 session 避免污染图片路径 timeout 配置。
    private let videoSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private init() {}

    func uploadImage(imageData: Data,
                     credential: OssCredential,
                     objectKey: String) async throws -> String {
        try await performUpload(
            fileData: imageData,
            credential: credential,
            objectKey: objectKey,
            contentType: "image/jpeg",
            objectAcl: nil,
            useVideoSession: false
        )
    }

    /// 视频上传（H-2 spec §5.2）：
    /// - acl=private（uploadVideo.vue:139-143 契约）
    /// - contentType 按扩展名（.mp4 → video/mp4；.mov → video/quicktime）
    /// - 走 videoSession（60s timeoutForRequest）
    func uploadVideo(videoData: Data,
                     credential: OssCredential,
                     objectKey: String,
                     contentType: String) async throws -> String {
        try await performUpload(
            fileData: videoData,
            credential: credential,
            objectKey: objectKey,
            contentType: contentType,
            objectAcl: "private",
            useVideoSession: true
        )
    }

    /// 视频上传 —— **公开可见变体**（I-spec-用户资料编辑页 §6B.1）。
    ///
    /// 与 `uploadVideo` 唯一差异：`objectAcl: nil`（默认继承 bucket policy，公开可见）。
    /// EditProfile 相册视频 / 来电视频面向所有观众，与 GiftMessage 私密视频 acl=private 语义不同。
    /// 仍走 `videoSession` 60s timeout。
    func uploadPublicVideo(videoData: Data,
                           credential: OssCredential,
                           objectKey: String,
                           contentType: String) async throws -> String {
        try await performUpload(
            fileData: videoData,
            credential: credential,
            objectKey: objectKey,
            contentType: contentType,
            objectAcl: nil,
            useVideoSession: true
        )
    }

    /// 公开文件上传。音频等非图像媒体复用同一份 STS / PostObject 链路，
    /// 仅由调用方提供 MIME 与 object key；音频也使用长超时 session。
    func uploadPublicFile(fileData: Data,
                          credential: OssCredential,
                          objectKey: String,
                          contentType: String) async throws -> String {
        try await performUpload(
            fileData: fileData,
            credential: credential,
            objectKey: objectKey,
            contentType: contentType,
            objectAcl: nil,
            useVideoSession: true
        )
    }

    private func performUpload(fileData: Data,
                               credential: OssCredential,
                               objectKey: String,
                               contentType: String,
                               objectAcl: String?,
                               useVideoSession: Bool) async throws -> String {
        let boundary = OssMultipartBodyBuilder.generateBoundary()
        let built = OssMultipartBodyBuilder.build(
            credential: credential,
            objectKey: objectKey,
            fileData: fileData,
            contentType: contentType,
            objectAcl: objectAcl,
            boundary: boundary
        )

        guard let url = URL(string: credential.host) else {
            throw OssUploadError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(built.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(built.body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = built.body

        let workingSession = useVideoSession ? videoSession : session
        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await workingSession.data(for: request)
        } catch is CancellationError {
            throw OssUploadError.network
        } catch let urlError as URLError {
            logger.error("OSS upload network error: \(urlError.code.rawValue) \(urlError.localizedDescription)")
            throw OssUploadError.network
        }

        guard let httpResp = response as? HTTPURLResponse else {
            throw OssUploadError.network
        }

        if httpResp.statusCode == 200 {
            let cdnObject = "\(credential.cdnUrl)/\(objectKey)"
            logger.info("OSS upload ok key=\(objectKey, privacy: .public) type=\(contentType, privacy: .public)")
            return cdnObject
        }

        let bodyString = String(data: responseData, encoding: .utf8) ?? ""
        logger.warning("OSS upload failed status=\(httpResp.statusCode, privacy: .public) bytes=\(responseData.count, privacy: .public)")
        throw OssUploadError.http(statusCode: httpResp.statusCode, body: bodyString)
    }
}
