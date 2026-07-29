import Foundation

/// 榜单埋点统一入口，保持 H5 `h_rank_*` 事件契约。
enum HomeRankingAnalytics {
    static func report(_ event: String, properties: [String: String]) {
        AnalyticsTracker.track(event, properties: properties)
    }
}
