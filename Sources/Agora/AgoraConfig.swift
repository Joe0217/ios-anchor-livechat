import Foundation

/// 声网接入配置。
/// 仅保留运行时常量 AppID（多环境通过 xcconfig 注入）；
/// channelId / rtcToken / uid 全部由后端 `/api/index/getAgoraRtmToken`、`/api/live/beginLiveRoom` 动态下发，
/// 原 POC 长期常量已删除。
enum AgoraConfig {
    /// 声网 AppID（dev 默认；prod 通过 xcconfig 覆盖）
    static var appId: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "HilyAgoraAppID") as? String ?? ""
        if raw.isEmpty || raw.hasPrefix("$(") { return "4af61c7a92f447d3a582308b5817dbd2" }
        return raw
    }
}
