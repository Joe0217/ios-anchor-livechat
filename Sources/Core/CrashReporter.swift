import Foundation
import Sentry

/// Sentry 崩溃上报的唯一接入点。
///
/// DSN 仅通过本机 xcconfig 注入；未配置时保持关闭，避免测试/开发构建误上报。
/// 用户信息只使用业务用户 ID，不写入昵称、邮箱、token、IM 内容或风控资料。
enum CrashReporter {
    private static let lock = NSLock()
    private static var started = false
    private static var reportedMissingConfiguration = false

    static func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !started else { return }
        guard let dsn = AppConfig.sentryDSN else {
            if !reportedMissingConfiguration {
                reportedMissingConfiguration = true
                AppLogger.net.notice("[Crash] Sentry disabled: DSN is unavailable")
            }
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn.absoluteString
            options.environment = AppConfig.crashReportingEnvironment
            options.releaseName = "com.anchor.livechat@\(AppConfig.appVersion)"
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            // APIClient carries loginToken/anchorToken and the sapi clients carry auth_token.
            // Keep crash reporting focused on failures: Sentry's automatic breadcrumbs include UI
            // control titles and view descriptions, which can contain user-generated text.
            options.enableAutoBreadcrumbTracking = false
            options.enableCaptureFailedRequests = false
            options.enableNetworkBreadcrumbs = false
        }
        started = true
        AppLogger.net.info("[Crash] Sentry started")
    }

    static func setUser(userID: Int?) {
        guard let userID, userID > 0 else { return }
        start()
        guard isStarted else { return }

        SentrySDK.configureScope { scope in
            scope.setUser(User(userId: String(userID)))
        }
    }

    static func clearUser() {
        guard isStarted else { return }
        SentrySDK.configureScope { scope in
            scope.setUser(nil)
        }
    }

    private static var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}
