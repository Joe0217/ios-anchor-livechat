import Foundation

/// 反馈类型（对齐 H5 `src/views/settings/feedBack/index.vue:53-69`）。
///
/// **提交值**：H5 硬编码英文字符串直接作为 `feedbackType` 提交，iOS 保持一致；
/// UI 显示走 L10n 三语，值端一律英文（后端识别与统计以英文为准）。
enum FeedbackType: String, CaseIterable, Identifiable {
    case appError     = "App Error"
    case accountError = "Account Error"
    case suggestion   = "Suggestion"
    case other        = "Other"

    var id: String { rawValue }

    /// UI 显示文案（走 L10n 三语）
    var displayName: String {
        switch self {
        case .appError:     return L10n.feedbackTypeAppError
        case .accountError: return L10n.feedbackTypeAccountError
        case .suggestion:   return L10n.feedbackTypeSuggestion
        case .other:        return L10n.feedbackTypeOther
        }
    }
}

/// POST /api/feedback/save body（对齐 H5 `postFeedback` payload）
struct FeedbackRequest {
    /// 图片 CDN URL 列表（可空）
    let pics: [String]
    /// 用户填写正文（对应 H5 `message`）
    let suggestion: String
    /// 反馈类型英文字符串
    let feedbackType: String
    /// 联系邮箱
    let email: String
}
