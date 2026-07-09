import Foundation

/// OSS 凭证服务 protocol —— 通用能力（Sources/Core/Upload/）。
///
/// 单一职责：拿 STS PostObject 直传所需凭证。
/// 业务方（朋友圈发布 / 反馈上传 / 头像 / 相册）都可注入本 protocol 的实现，无需感知 API 细节。
protocol OssCredentialServiceProtocol {
    /// 拉取 OSS 凭证。走主接口加密通道（`APIClient.shared.post`）。
    /// 失败 throw `APIError`。
    func getOssUploadParam() async throws -> OssCredential
}
