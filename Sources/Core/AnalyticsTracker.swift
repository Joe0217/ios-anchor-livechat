import Foundation
import ThinkingSDK

/// 数数 ThinkingData 的唯一接入点。
///
/// 未配置本机 xcconfig 时静默停用，不影响业务链路。默认事件即时 flush；RTC/IM 高频的
/// Party 事件通过 `PartyAnalytics` 改用 SDK 批量发送。
enum AnalyticsTracker {
    private static let lock = NSLock()
    private static var started = false
    private static var reportedMissingConfiguration = false

    static func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        guard let config = AppConfig.thinkingDataConfiguration else {
            if !reportedMissingConfiguration {
                reportedMissingConfiguration = true
                AppLogger.net.warning("[Analytics] ThinkingData disabled: configuration is unavailable")
            }
            return
        }

        TDAnalytics.start(withAppId: config.appId, serverUrl: config.serverURL)
        TDAnalytics.setSuperProperties(["#app_version": AppConfig.appVersion])
        started = true
        AppLogger.net.info("[Analytics] ThinkingData started")
    }

    static func login(userId: Int?) {
        guard let userId, userId > 0 else { return }
        start()
        guard isStarted else { return }
        TDAnalytics.login(String(userId))
    }

    static func logout() {
        guard isStarted else { return }
        TDAnalytics.flush()
        TDAnalytics.logout()
    }

    static func track(_ event: String,
                      properties: [String: Any] = [:],
                      immediately: Bool = true) {
        start()
        guard isStarted else { return }
        TDAnalytics.track(event, properties: properties)
        if immediately {
            TDAnalytics.flush()
        }
    }

    private static var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}

/// Party 房埋点的轻量入口。
///
/// Party 房内有 RTC、IM 和礼物等高频链路，不能因单次用户操作立即 flush 造成额外网络工作。
/// ThinkingData SDK 自行批量持久化和发送；该封装只用于明确的用户动作或已发生的业务结果，且永不参与业务分支。
enum PartyAnalytics {
    static func track(_ event: String, properties: [String: Any] = [:]) {
        var enriched = properties
        if enriched["moduleType"] == nil {
            enriched["moduleType"] = "party"
        }
        AnalyticsTracker.track(event, properties: enriched, immediately: false)
    }

    static func roomProperties(
        roomId: String?,
        ownerId: String?,
        roomTempId: String? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [:]
        if let roomId, !roomId.isEmpty {
            // H5 同时保留两个历史字段，数据平台依赖这两个字段做跨端聚合。
            properties["roomid"] = roomId
            properties["room_id"] = roomId
        }
        if let ownerId, !ownerId.isEmpty {
            properties["roomHost_id"] = ownerId
        }
        if let roomTempId, !roomTempId.isEmpty {
            properties["modeNum"] = roomTempId
        }
        return properties
    }
}
