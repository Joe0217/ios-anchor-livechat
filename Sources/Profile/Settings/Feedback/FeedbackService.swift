import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "FeedbackService")

/// 反馈提交数据层。
///
/// 对齐 H5 `src/api/settings/index.ts:4` — `postFeedback(data)` → `POST /api/feedback/save`（H5 字面 path）。
/// 响应只关心 code，无 result 数据；APIClient 已处理 code=='0000' 判定与非 0 抛 APIError。
protocol FeedbackServiceProtocol {
    func submit(_ request: FeedbackRequest) async throws
}

final class FeedbackService: FeedbackServiceProtocol {

    static let shared = FeedbackService()

    private init() {}

    func submit(_ request: FeedbackRequest) async throws {
        let body: [String: Any] = [
            "pics": request.pics,
            "suggestion": request.suggestion,
            "feedbackType": request.feedbackType,
            "email": request.email,
        ]
        _ = try await APIClient.shared.post("/api/feedback/save", body: body)
        logger.info("submit ok type=\(request.feedbackType, privacy: .public) picCount=\(request.pics.count)")
    }
}
