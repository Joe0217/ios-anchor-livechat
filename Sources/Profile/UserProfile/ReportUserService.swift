import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "ReportUserService")

/// 用户举报数据层（H-0 补齐）。
///
/// 对齐 H5 `src/api/home/index.ts:123` — `userFeedbackSubmit(data)` → `POST /api/feedback/feedbackVideo`（字面 path）。
/// 调用点：H5 `c-feedbackPopup.vue` type='userProfile' 分支（line 108-119）。
///
/// 响应只关心 code，无 result 数据；APIClient 已处理 code=='0000' 判定与非 0 抛 APIError。
protocol ReportUserServiceProtocol {
    func submit(_ request: ReportUserRequest) async throws
}

/// 举报请求体（严格对齐 H5 c-feedbackPopup.vue:110-118）。
struct ReportUserRequest {
    /// 反馈文本（description）。H5 userProfile 分支不校验空，允许空字符串。
    let suggestion: String
    /// 是否同步拉黑：1=是 / 2=否。H5 写死 2（line 112）。
    let block: Int
    /// 被举报用户 id。H5 传 `props.userId`（Number 或 String，后端宽松）。
    let beBlockUid: String
    /// 5 个原因 dictValue 之一（英文原文，非数字）：
    /// - "Incorrect information"
    /// - "Sexual content"
    /// - "Harassment or repulsive Language"
    /// - "Unreasonable demands"
    /// - "Other"
    let feedbackType: String
    /// H5 写死空字符串（line 115）。
    let url: String

    init(suggestion: String,
         beBlockUid: String,
         feedbackType: String,
         block: Int = 2,
         url: String = "") {
        self.suggestion = suggestion
        self.block = block
        self.beBlockUid = beBlockUid
        self.feedbackType = feedbackType
        self.url = url
    }
}

final class ReportUserService: ReportUserServiceProtocol {

    static let shared = ReportUserService()

    private init() {}

    func submit(_ request: ReportUserRequest) async throws {
        // beBlockUid 转 Int 优先（对齐 H5 后端习惯接 Number），转不出则原样传 String 兜底
        let uidValue: Any = Int(request.beBlockUid) ?? request.beBlockUid
        let body: [String: Any] = [
            "suggestion": request.suggestion,
            "block": request.block,
            "beBlockUid": uidValue,
            "feedbackType": request.feedbackType,
            "url": request.url,
        ]
        _ = try await APIClient.shared.post("/api/feedback/feedbackVideo", body: body)
        logger.info("report ok reason=\(request.feedbackType, privacy: .public) uid=\(request.beBlockUid, privacy: .public)")
    }
}
