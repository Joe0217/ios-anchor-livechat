#if canImport(UIKit)
import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "EditProfileService")

/// 用户资料编辑页真数据层实现（I-spec §4.1 · Step 1c）。
///
/// **接口**（对齐 rule `api-http-method-strict.md` 追字面 path）：
/// - `POST /api/anchor/checkUserInfo` 拉审核中字段
/// - `POST /api/anchor/userInfo` 拉完整用户信息 + latestIconAndCallVideo
/// - `POST /api/user/updateUserInfo` 智能字段检测后的核心保存
/// - 上传委托：`ImageUploader.shared`（图片）+ `PublicVideoUploader.shared`（视频 acl 公开）
final class EditProfileService: EditProfileServiceProtocol, @unchecked Sendable {

    static let shared = EditProfileService()

    private let apiClient: APIClient
    private let imageUploader: ImageUploader
    private let videoUploader: PublicVideoUploader

    init(apiClient: APIClient = .shared,
         imageUploader: ImageUploader = .shared,
         videoUploader: PublicVideoUploader = .shared) {
        self.apiClient = apiClient
        self.imageUploader = imageUploader
        self.videoUploader = videoUploader
    }

    // MARK: - API

    func fetchCheckUserInfo() async throws -> CheckUserInfoResponse {
        let data = try await apiClient.post("/api/anchor/checkUserInfo")
        do {
            return try JSONDecoder().decode(CheckUserInfoResponse.self, from: data)
        } catch {
            logger.error("checkUserInfo decode failed: \(String(describing: error))")
            throw error
        }
    }

    func fetchUserInfoWithReview() async throws -> UserInfoWithReviewResponse {
        let data = try await apiClient.post("/api/anchor/userInfo")
        do {
            return try JSONDecoder().decode(UserInfoWithReviewResponse.self, from: data)
        } catch {
            logger.error("userInfo decode failed: \(String(describing: error))")
            throw error
        }
    }

    func updateUserInfo(_ request: UpdateUserInfoRequest) async throws {
        // 转 [String: Any] 字典（APIClient.post 只接 dict body）
        let body = try encodeRequestAsDict(request)
        _ = try await apiClient.post("/api/user/updateUserInfo", body: body)
        logger.info("updateUserInfo ok")
    }

    // MARK: - Upload delegation

    func uploadImage(data: Data, preset: ImageCompressionPreset) async throws -> String {
        try await imageUploader.upload(rawData: data, preset: preset)
    }

    func uploadVideo(data: Data, fileExtension: String) async throws -> String {
        try await videoUploader.upload(videoData: data, fileExtension: fileExtension)
    }

    // MARK: - Helpers

    /// 把 Encodable request 转成 APIClient 期望的 [String: Any]（跳过 nil 字段，符合 H5 智能 diff）
    private func encodeRequestAsDict(_ request: UpdateUserInfoRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        guard
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw EncodingError.invalidValue(
                request,
                EncodingError.Context(codingPath: [], debugDescription: "request → dict conversion failed")
            )
        }
        return raw
    }
}
#endif
