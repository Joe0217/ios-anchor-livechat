import Foundation

/// OSS 上传错误，便于 ViewModel 区分"凭证过期需重拉"vs"普通失败"（spec R19）。
enum OssUploadError: Error, Equatable {
    /// HTTP 4xx/5xx，附 statusCode 与 body 关键字（识别 SecurityTokenExpired 等）
    case http(statusCode: Int, body: String)
    /// 网络层错误（URLError / 超时）
    case network
    /// 客户端构造请求失败（如 URL 无法解析）
    case invalidRequest

    /// 是否是 STS 凭证过期错误（OSS 文档：403 + body 含相关关键字）
    /// spec R19：识别后触发重拉 STS + 仅重传未完成的图（最多 2 次）。
    var isTokenExpired: Bool {
        guard case .http(let code, let body) = self, code == 403 else { return false }
        return body.contains("SecurityTokenExpired")
            || body.contains("InvalidAccessKeyId")
            || body.contains("RequestTimeTooSkewed")
    }
}

/// OSS 上传 protocol（J spec §3.2 流程 B：PostObject 表单直传）。
///
/// **职责**：
/// - 拼 multipart body（含 key/policy/Signature/OSSAccessKeyId/success_action_status/file）
/// - POST 到 credential.host（**独立 URLSession，不走 APIClient**，OSS 不要业务加密）
/// - 返回 `cdnUrl + "/" + key` 形式的最终 URL
///
/// **OSS 凭证过期**：实现方应识别 OssUploadError.isTokenExpired，ViewModel 据此决定重拉 STS。
protocol OssUploadServiceProtocol {
    /// 上传一张图。
    /// - parameter imageData: JPEG 数据（已压缩，Content-Type: image/jpeg）
    /// - parameter credential: STS 凭证
    /// - parameter objectKey: OSS object key，格式 `00000000/{yyyyMMdd}/{UUID}.jpg`（由 ViewModel 拼装）
    /// - returns: 上传成功后的 cdnUrl
    /// - throws: OssUploadError
    func uploadImage(imageData: Data,
                     credential: OssCredential,
                     objectKey: String) async throws -> String

    /// 上传一个视频（H-2 spec §5.2 v2）。
    /// - parameter videoData: 视频数据（.mp4/.mov 原始文件）
    /// - parameter credential: STS 凭证
    /// - parameter objectKey: OSS object key，格式 `00000000/{yyyyMMdd}/{UUID}.mp4`（由 ViewModel 拼装）
    /// - parameter contentType: MIME（`video/mp4` / `video/quicktime`）
    /// - returns: 上传成功后的 cdnUrl
    /// - throws: OssUploadError
    /// - Note: 实现方需强制 `x-oss-object-acl: private` + 独立 60s timeout URLSession
    func uploadVideo(videoData: Data,
                     credential: OssCredential,
                     objectKey: String,
                     contentType: String) async throws -> String
}
