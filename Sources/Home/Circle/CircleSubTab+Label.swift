import Foundation

/// 视图层用的本地化 label —— L10n 依赖隔离，不入 HilyTests sources。
extension CircleSubTab {
    /// 设计稿标签 (视觉文本，trial #1 占位用 L10n key)
    var label: String {
        switch self {
        case .official: return L10n.circleSubTabOfficial
        case .moment:   return L10n.circleSubTabMoment
        case .me:       return L10n.circleSubTabMe
        }
    }
}
