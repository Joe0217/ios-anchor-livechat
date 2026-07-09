import Foundation

/// L 里程碑：MatchToast → L10n 展示文案映射。
///
/// **仅 UI 层引用**：本文件不入 test target sources（依赖 `L10n`，而 L10n 又依赖 `AppLocaleStore`
/// SwiftUI 环境栈）。MatchStore 层的 `@Published var lastToast: MatchToast?` 是纯 enum，UI 端 render
/// 时调用 `toast.localized` 转具体文案。
extension MatchToast {
    /// 转本地化展示文案（对应 `Localizable.strings` `match.toast.*` key）
    var localized: String {
        switch self {
        case .networkError:      return L10n.matchToastNetworkError
        case .noFaceDetected:    return L10n.matchToastNoFaceDetected
        case .exceedCount:       return L10n.matchToastExceedCount
        case .turnOnFailed:      return L10n.matchToastTurnOnFailed
        case .turnOnSucceed:     return L10n.matchToastTurnOnSucceed
        case .turnOffSucceed:    return L10n.matchToastTurnOffSucceed
        case .cameraStartFailed: return L10n.matchToastCameraStartFailed
        case .cameraUnavailable: return L10n.matchToastCameraUnavailable
        case .imOffline:         return L10n.matchToastImOffline
        }
    }
}
