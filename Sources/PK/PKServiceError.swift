import Foundation

/// G 里程碑 spec §4 PK 业务错误类型。
///
/// - `business(code:message:)`：APIClient 抛 `APIError` 后由 PKService 转译；保留原 code/message 给 UI
/// - `notImplemented`：6 个占位接口（getPkRankList / getRecommendAnchorList / getPkRecordList /
///    queryInviteSwitch / getPkInfo / selectPKRuleIcon）未在 G 范围内实现
/// - `decode(Error)`：JSONDecoder 失败
enum PKServiceError: Error, LocalizedError {
    case business(code: String, message: String)
    case notImplemented
    case decode(Error)

    var errorDescription: String? {
        switch self {
        case .business(_, let message): return message
        case .notImplemented: return "PK API not implemented in G milestone"
        case .decode(let err): return "PK decode failed: \(err)"
        }
    }
}
