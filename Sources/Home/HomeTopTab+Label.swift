import Foundation

/// 视图层用的本地化 label —— L10n 依赖隔离，不入 HilyTests sources。
extension HomeTopTab {
    /// 设计稿标签 (视觉文本，i18n 走 L10n)
    var label: String {
        switch self {
        case .live:   return L10n.homeTopTabLive
        case .list:   return L10n.homeTopTabList
        case .match:  return L10n.homeTopTabMatch
        case .circle: return L10n.homeTopTabCircle
        }
    }
}
