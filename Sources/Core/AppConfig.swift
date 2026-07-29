import Foundation
import os

/// 全局配置：值由 xcconfig 注入到 Info.plist，运行时从 plist 读出。
/// 多环境切换走 Config/Config-Dev.xcconfig ↔ Config-Test.xcconfig ↔ Config-Prod.xcconfig
/// （当前 Debug 绑 Test / Release 绑 Prod；切回 dev 改 project.yml configFiles.Debug + ./bin/regen.sh）。
///
/// 配置缺失时直接失败，绝不在源码中保留开发环境凭证。
/// `HilyTests` 使用仅限测试 target 的无敏感假值，保证纯逻辑测试不依赖本机 xcconfig。
enum AppConfig {
    // MARK: - 域名（xcconfig 只存 host，scheme 在此拼接，避开 "//" 注释坑）
    static var apiBaseURL: String    { "https://" + plistString("HilyAPIHost") }
    static var sapiBaseURL: String   { "https://" + plistString("HilySAPIHost") }
    static var socketBaseURL: String { "wss://"  + plistString("HilySocketHost") }

    // MARK: - 主接口鉴权 / 业务版本
    static var appId: String       { plistString("HilyAppID") }
    static var ocpApimKey: String  { plistString("HilyOcpApimKey") }
    static var appVersion: String  { plistString("HilyAppVersion") }

    // MARK: - 云信 NIM
    static var nimAppKey: String   { plistString("HilyNIMAppKey") }

    /// 系统通知 P2P session 的 yxAccId（H5 `VITE_NOTIFICATION_SEEION_ID`）。
    ///
    /// dev=`video-sky-test` / test|prod=`video-sky-prod`（值随 xcconfig 环境切换而变，
    /// 不再绑 build config —— Debug + Config-Test 也能取到 prod 的 session id，避免 P2P 系统消息路由错乱）。
    /// 此 session 承载后端"系统通知"类 P2P 消息，在会话列表中**从常规 Flame/Prime/Stranger 3 tab 排除**，
    /// 专门显示在 Flame 顶部 System 入口（对齐 H5 `session.js:81, 107, 331`）。
    static var notificationYxAccId: String {
        plistString("HilyNotificationYxAccId")
    }

    // MARK: - 主接口 AES-128-CBC
    static var aesKey: String      { plistString("HilyAESKey") }
    static var aesIV: String       { plistString("HilyAESIV") }

    // MARK: - sapi（vvi）AES-128-CBC
    // Each environment supplies these independently through local xcconfig.
    static var sapiAesKey: String  { plistString("HilySAPIAESKey") }
    static var sapiAesIV: String   { plistString("HilySAPIAESIV") }

    // MARK: - WebSocket 握手 AES-128-ECB（与主接口 CBC 是两套）
    static var wsAesKey: String    { plistString("HilyWSAESKey") }

    // MARK: - 数数 ThinkingData
    /// 埋点为可选基础设施：配置未注入时业务可正常启动，但不会发送埋点。
    static var thinkingDataConfiguration: (appId: String, serverURL: String)? {
        guard let appId = optionalPlistString("HilyThinkingDataAppID"),
              let serverURL = optionalPlistString("HilyThinkingDataServerURL"),
              let url = URL(string: serverURL),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return (appId, serverURL)
    }

    /// WebView H5 的受信任部署入口。xcconfig 只保存 host，避免 `//` 被当作注释；路由以 history path 附加。
    static var webFeatureBaseURL: URL? {
        guard let host = optionalPlistString("HilyWebFeatureBaseURL"),
              !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"),
              !host.contains("?"),
              !host.contains("#"),
              let url = URL(string: "https://\(host)"),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.host == host,
              url.port == nil else {
            return nil
        }
        return url
    }

    // MARK: - Settings 外链 & 静态资源（H5 config.js 蓝本一致）
    /// 主播规范图（View anchor policy 页显示的远程 png）
    static let anchorPolicyImageURL = "https://img.hnhily.link/default/anchor.png"
    /// 用户协议外链
    static let termsOfServiceURL    = "https://h5.livehot.site/#/agreement"
    /// 隐私政策外链
    static let privacyPolicyURL     = "https://h5.livehot.site/#/privacy"

    /// F 期便利功能：派对房 ShareLink 深链前缀（2026-07-17）。
    /// 完整格式：`\(partyShareBaseURL)\(roomId)`；由用户端 h5ui 承接跳转，主播端只做**站外分享出口**，
    /// 不承接进入侧 deep link（主播不会通过分享链回自己房）。
    /// 后端若下发短链 API（`apiGetShareUrl`）时可替换；暂用兜底常量。
    static let partyShareBaseURL    = "https://h5.livehot.site/#/party?roomId="

    // MARK: - 内部

    /// "$(VAR)" 说明 xcconfig 没绑或变量未定义。生产与开发构建均 fail-fast，避免误连错误环境。
    /// 暴露为 internal static：让 AgoraConfig / 其他配置类复用同一守卫路径（避免旁路）。
    static func plistString(_ key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        if !raw.isEmpty && !raw.hasPrefix("$(") {
            return raw
        }

        #if HILY_TESTS
        return TestDefaults.value(for: key)
        #else
        let logger = Logger(subsystem: "com.anchor.livechat", category: "AppConfig")
        logger.fault("AppConfig: \(key, privacy: .public) missing from Info.plist (xcconfig not configured for this build)")
        fatalError("AppConfig: \(key) missing from Info.plist (xcconfig not configured for this build)")
        #endif
    }

    private static func optionalPlistString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.hasPrefix("$("),
              !value.hasPrefix("__REQUIRED") else { return nil }
        return value
    }

    #if HILY_TESTS
    private enum TestDefaults {
        static func value(for key: String) -> String {
            switch key {
            case "HilyAPIHost": return "test.invalid"
            case "HilySAPIHost": return "sapi.test.invalid"
            case "HilySocketHost": return "socket.test.invalid"
            case "HilyAppID": return "test-app-id"
            case "HilyOcpApimKey": return "test-ocp-key"
            case "HilyAppVersion": return "0.0.0-test"
            case "HilyNIMAppKey": return "test-nim-app-key"
            case "HilyNotificationYxAccId": return "test-notification"
            case "HilyAESKey": return "test-aes-key-123"
            case "HilyAESIV": return "test-aes-iv-1234"
            case "HilySAPIAESKey": return "sapi-aes-key-123"
            case "HilySAPIAESIV": return "sapi-aes-iv-1234"
            case "HilyWSAESKey": return "test-ws-key-1234"
            case "HilyAgoraAppID": return "test-agora-app-id"
            default: fatalError("Unexpected AppConfig test key: \(key)")
            }
        }
    }
    #endif
}
