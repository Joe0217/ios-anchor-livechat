import Foundation

/// 榜单埋点统一入口。工程尚未接入 ThinkingData SDK 时先收敛到 AppLogger；
/// 接 SDK 后仅替换此处即可保持与 H5 h_rank_* 事件一致。
enum HomeRankingAnalytics {
    static func report(_ event: String, properties: [String: String]) {
        AppLogger.net.info("[Analytics] \(event, privacy: .public) \(properties.description, privacy: .public)")
    }
}
