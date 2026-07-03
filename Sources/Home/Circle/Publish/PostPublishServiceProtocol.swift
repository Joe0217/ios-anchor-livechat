import Foundation

/// 朋友圈发布业务 protocol（J spec §3.3）。
///
/// 单一职责：调 `/api/expand/friendsCircle/create`。
///
/// **不含**拿 OSS 凭证——那部分已上移到 [OssCredentialServiceProtocol](../../../Core/Upload/OssCredentialServiceProtocol.swift)
/// （多业务共享的通用能力）。
protocol PostPublishServiceProtocol {
    /// 创建朋友圈帖子。
    /// - parameter textContent: 文本（已 trim，≤500 字）
    /// - parameter imgUrls: 已上传到 OSS 的 cdnUrl 数组（非空，对齐 H5 Q3 决策）
    ///
    /// 业务码非 0000 → throw `APIError(code, message)`；调用方按 v3 spec 不区分审核拒绝。
    func createPost(textContent: String, imgUrls: [String]) async throws
}
