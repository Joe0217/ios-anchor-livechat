import Foundation

/// 声网接入配置。
/// 仅保留运行时常量 AppID（多环境通过 xcconfig 注入）；
/// channelId / rtcToken / uid 全部由后端 `/api/index/getAgoraRtmToken`、`/api/live/beginLiveRoom` 动态下发，
/// 原 POC 长期常量已删除。
///
/// 走 AppConfig.plistString 同款守卫（DEBUG fallback / Release fatalError），
/// 避免 prod 漏配 HILY_AGORA_APP_ID 时悄悄落回 dev AppID 误连 dev 声网项目。
///
/// **Release binary 隔离**：`DevDefaults` `#if DEBUG/#else` 切换，Release 编译时 dev AppID
/// 字面量不参与编译，防 `strings IPA` 提取（与 AppConfig.DevDefaults 同款机制）。
enum AgoraConfig {
    /// 声网 AppID（dev 默认；prod 通过 xcconfig 覆盖）
    static var appId: String {
        AppConfig.plistString("HilyAgoraAppID", fallback: DevDefaults.appId)
    }

    private enum DevDefaults {
        #if DEBUG
        static let appId = "4af61c7a92f447d3a582308b5817dbd2"
        #else
        static let appId = ""
        #endif
    }
}
