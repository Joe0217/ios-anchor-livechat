import Foundation

/// 声网接入配置。
/// 仅保留运行时常量 AppID（多环境通过 xcconfig 注入）；
/// channelId / rtcToken / uid 全部由后端 `/api/index/getAgoraRtmToken`、`/api/live/beginLiveRoom` 动态下发，
/// 原 POC 长期常量已删除。
///
/// 走 AppConfig.plistString 守卫。任何构建漏配 HILY_AGORA_APP_ID 都会直接失败，
/// 避免源码 fallback 让应用误连错误的声网项目。
enum AgoraConfig {
    /// 声网 AppID（由 xcconfig 注入）
    static var appId: String {
        AppConfig.plistString("HilyAgoraAppID")
    }
}
