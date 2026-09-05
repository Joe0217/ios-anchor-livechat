import Foundation
import os

#if !DEBUG
/// Release builds keep the logging call sites source-compatible while dropping
/// every AppLogger message before it reaches the unified logging system.
struct ReleaseLogSink {
    @_transparent func debug(_ message: OSLogMessage) {}
    @_transparent func info(_ message: OSLogMessage) {}
    @_transparent func notice(_ message: OSLogMessage) {}
    @_transparent func warning(_ message: OSLogMessage) {}
    @_transparent func error(_ message: OSLogMessage) {}
}
#endif

/// 统一日志门面：替代直接的 `print()`，按模块分 category，方便控制台过滤与隐私脱敏。
///
/// 使用要点：
/// - Debug 使用 `Logger`；Release 使用空实现，完全丢弃所有 AppLogger 消息
/// - token / 用户输入 / 服务端响应等敏感字段须用 `\(value, privacy: .private)` 插值（Release 显示 `<private>`）
/// - 一律走 logger.debug/info/notice/error，禁止留下裸 `print()`
enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.hilly.anchor"

#if DEBUG
    typealias Sink = Logger
#else
    typealias Sink = ReleaseLogSink
#endif

#if DEBUG
    static let net = Sink(subsystem: subsystem, category: "network")
    static let auth = Sink(subsystem: subsystem, category: "auth")
    static let live = Sink(subsystem: subsystem, category: "live")
    static let call = Sink(subsystem: subsystem, category: "call")
    static let im = Sink(subsystem: subsystem, category: "im")
    static let heartbeat = Sink(subsystem: subsystem, category: "heartbeat")
    static let rtm = Sink(subsystem: subsystem, category: "rtm")
    static let match = Sink(subsystem: subsystem, category: "match")
    static let party = Sink(subsystem: subsystem, category: "party")
#else
    static let net = Sink()
    static let auth = Sink()
    static let live = Sink()
    static let call = Sink()
    static let im = Sink()
    static let heartbeat = Sink()
    static let rtm = Sink()
    static let match = Sink()
    static let party = Sink()
#endif
}
