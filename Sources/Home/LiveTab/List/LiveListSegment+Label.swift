import Foundation

/// 视图层用的本地化 label —— L10n 依赖隔离，不入 HilyTests sources。
extension LiveListSegment {
    var label: String {
        switch self {
        case .online: return L10n.liveListSegmentOnline
        case .prime:  return L10n.liveListSegmentPrime
        }
    }
}
