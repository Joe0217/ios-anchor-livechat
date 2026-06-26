import Foundation

/// 云信 IM 相关错误类型（H 里程碑 spec §2.4 / §4.2）。
///
/// 对齐 `APIError` 模式：使用 `LocalizedError` 暴露用户可见文案（走 L10n 三语言）；
/// 错误码分流由 `NIMService.mapError(_:)` 完成，业务侧仅 `switch` 业务态。
///
/// **关键码**（H 校验清单 §1.5 R6 / A 收尾 backlog #1）：
/// - 1004：账号在其他设备登录 → 全局 logout + post `.apiSessionInvalidated`
/// - 1005：token 过期 → 同上（与 APIClient 一致）
///
/// **跨模块联动**：1004 / 1005 触发后通过 `NotificationCenter` 广播 `.apiSessionInvalidated`，
/// `RootView` 监听后切回登录页，与 APIClient HTTP 401 / 心跳分流一致。
enum NIMServiceError: Error, LocalizedError, Equatable {

    /// 登录失败（非 1004 / 1005 之外的码统一进此 case，含底层错误描述）
    case loginFailed(code: Int, message: String)

    /// 1005 token 过期 / 鉴权失败 → 触发全局 logout
    case tokenInvalid

    /// 1004 账号在其他设备登录 → 触发全局 logout
    case kickedOut

    /// 进入聊天室失败（含底层 code 与描述）
    case chatroomEnterFailed(code: Int, message: String)

    /// 消息解码失败（payload 字段缺失 / JSON 不合法 / gzip 解压失败等）
    case decodingFailed(String)

    /// 网络错误（NIM 长连接断开等）
    case networkError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .loginFailed(let code, let msg):
            return String(format: L10n.imErrorLoginFailedFormat, "\(code)", msg)
        case .tokenInvalid:
            return L10n.imErrorTokenInvalid
        case .kickedOut:
            return L10n.imErrorKickedOut
        case .chatroomEnterFailed(let code, _):
            return String(format: L10n.imErrorChatroomEnterFailedFormat, "\(code)")
        case .decodingFailed(let reason):
            return String(format: L10n.imErrorDecodingFormat, reason)
        case .networkError(let code, _):
            return String(format: L10n.imErrorNetworkErrorFormat, "\(code)")
        }
    }

    /// 是否触发全局会话失效（A 收尾 backlog #1 对齐）：仅 1004 / 1005 两码。
    var triggersSessionInvalidation: Bool {
        switch self {
        case .kickedOut, .tokenInvalid:
            return true
        default:
            return false
        }
    }

    // MARK: - 错误码分流

    /// 从 `NSError` 映射到 `NIMServiceError`。
    ///
    /// `onKickout` / `onAutoLoginFailed` 两个 SDK 回调已经分流到 `.kickedOut` / `.tokenInvalid`，
    /// 本方法主要给 `login(account:token:)` 等同步错误使用——大部分 NIM 业务码（如鉴权失败 / 网络错误）
    /// 走 fallback；未来需要按 `NIMRemoteErrorCode` 精细分流时在此扩展。
    ///
    /// - Parameter nsError: SDK 回调下来的 `NSError`
    /// - Parameter fallback: 不识别的码走兜底值，由 caller 指定（通常 `.loginFailed` / `.networkError`）
    static func from(nsError: NSError, fallback: NIMServiceError) -> NIMServiceError {
        // H 阶段先 fallback；NIMRemoteErrorCodeKickout / NIMRemoteErrorCodeOtherClientLogined
        // 等精细分流按需补（多数场景 onKickout / onAutoLoginFailed delegate 已直接给到正确 case）。
        fallback
    }
}
