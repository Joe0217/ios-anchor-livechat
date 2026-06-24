import Foundation
import os

/// 统一日志门面：替代直接的 `print()`，按模块分 category，方便控制台过滤与隐私脱敏。
///
/// 使用要点：
/// - 生产包 `Logger` 默认不打印 `.debug` 级，无需 `#if DEBUG` 包裹诊断日志
/// - token / 用户输入 / 服务端响应等敏感字段须用 `\(value, privacy: .private)` 插值（Release 显示 `<private>`）
/// - 一律走 logger.debug/info/notice/error，禁止留下裸 `print()`
enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.anchor.livechat"

    static let net = Logger(subsystem: subsystem, category: "network")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let live = Logger(subsystem: subsystem, category: "live")
    static let call = Logger(subsystem: subsystem, category: "call")
    static let im = Logger(subsystem: subsystem, category: "im")
    static let heartbeat = Logger(subsystem: subsystem, category: "heartbeat")
    static let rtm = Logger(subsystem: subsystem, category: "rtm")
    static let party = Logger(subsystem: subsystem, category: "party")
}
