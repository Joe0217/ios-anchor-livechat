import Foundation

/// 用户资料编辑页数据层协议（I-spec §4.1）。
///
/// 抽 protocol 允许 Store 单测注入 Fake（不打真接口）。真实现 `EditProfileService` 在
/// Step 1c 落地，走 `APIClient` + `ImageUploader` + `PublicVideoUploader`（新建）。
///
/// Protocol 只覆盖**业务接口**层；OSS 直传 URL 通过 `uploadImage` / `uploadVideo` 已封装内部。
protocol EditProfileServiceProtocol: Sendable {
    /// `POST /api/anchor/checkUserInfo` — 拉审核中字段
    func fetchCheckUserInfo() async throws -> CheckUserInfoResponse

    /// `POST /api/anchor/userInfo` — 拉完整用户信息 + 头像审核态字段
    func fetchUserInfoWithReview() async throws -> UserInfoWithReviewResponse

    /// `POST /api/user/updateUserInfo` — 智能字段检测后的核心保存接口
    func updateUserInfo(_ request: UpdateUserInfoRequest) async throws

    /// 图片上传：内部走 `ImageUploader.shared.upload(rawData:preset:)`；返回 CDN URL
    func uploadImage(data: Data, preset: ImageCompressionPreset) async throws -> String

    /// 视频上传：内部走 `PublicVideoUploader`（新建 in Step 1c）；返回 CDN URL
    func uploadVideo(data: Data, fileExtension: String) async throws -> String
}
