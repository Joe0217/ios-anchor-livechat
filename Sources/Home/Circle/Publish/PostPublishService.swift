import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PostPublishService")

/// 朋友圈发布业务真实现（J spec §3.3）。
///
/// 单一职责：调 `/api/expand/friendsCircle/create`。
/// 拿凭证走 [OssCredentialService](../../../Core/Upload/OssCredentialService.swift)（通用能力）。
final class PostPublishService: PostPublishServiceProtocol {

    static let shared = PostPublishService()

    private init() {}

    /// `POST /api/expand/friendsCircle/create`（spec §3.3）
    ///
    /// body: `{displayRange: 1, textContent, imgUrls}` —— 对齐 H5 `circle/posts/index.vue:30-33`。
    /// `displayRange = 1` 硬编（spec §7 Q12 自然解决，朋友圈仅一种可见范围）。
    func createPost(textContent: String, imgUrls: [String]) async throws {
        let body: [String: Any] = [
            "displayRange": 1,
            "textContent": textContent,
            "imgUrls": imgUrls,
        ]
        _ = try await APIClient.shared.post("/api/expand/friendsCircle/create", body: body)
        logger.info("createPost ok text=\(textContent.count, privacy: .public) chars imgs=\(imgUrls.count, privacy: .public)")
    }
}
