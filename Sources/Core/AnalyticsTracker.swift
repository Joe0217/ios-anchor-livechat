import Foundation
import ThinkingSDK

/// 数数 ThinkingData 的唯一接入点。
///
/// 未配置本机 xcconfig 时静默停用，不影响业务链路；配置到位后所有事件即时 flush，行为与 H5
/// `reportShuShuCustomEvent` 一致。
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
