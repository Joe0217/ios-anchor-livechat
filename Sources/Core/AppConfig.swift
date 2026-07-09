import Foundation
import os

/// 全局配置：值由 xcconfig 注入到 Info.plist，运行时从 plist 读出。
/// 多环境切换走 Config/Config-Dev.xcconfig ↔ Config/Config-Prod.xcconfig。
///
/// **fallback 策略**（防 prod 悄悄落回 dev 密钥）：
/// - **DEBUG**：plist 缺失 / 残留字面 "$(VAR)" 时回 dev 默认值（`DevDefaults.*`）——真机直跑
///   （无 configFiles）或忘配 xcconfig 时仍能跑通 dev，不至于硬崩。
/// - **Release**：`DevDefaults.*` 在 `#else` 分支全部为 ""，dev 真值字面量**不参与 Release 编译**
///   （防 `strings IPA` 提取 dev 密钥）；plistString 内 Release 路径直接 `fatalError` abort——
///   避免上次 sapi xcconfig 槽位漏配时悄悄走 dev 密钥到 prod 后端的灾难
///   （参见审查报告 P0-1 + P1-2 复合修复）。
enum AppConfig {
    // MARK: - 域名（xcconfig 只存 host，scheme 在此拼接，避开 "//" 注释坑）
    static var apiBaseURL: String    { "https://" + plistString("HilyAPIHost",   fallback: DevDefaults.apiHost) }
    static var sapiBaseURL: String   { "https://" + plistString("HilySAPIHost",  fallback: DevDefaults.sapiHost) }
    static var socketBaseURL: String { "wss://"  + plistString("HilySocketHost", fallback: DevDefaults.socketHost) }

    // MARK: - 主接口鉴权 / 业务版本
    static var appId: String       { plistString("HilyAppID",      fallback: DevDefaults.appId) }
    static var ocpApimKey: String  { plistString("HilyOcpApimKey", fallback: DevDefaults.ocpApimKey) }
    static var appVersion: String  { plistString("HilyAppVersion", fallback: DevDefaults.appVersion) }

    // MARK: - 云信 NIM
    static var nimAppKey: String   { plistString("HilyNIMAppKey",  fallback: DevDefaults.nimAppKey) }

    /// 系统通知 P2P session 的 yxAccId（H5 `VITE_NOTIFICATION_SEEION_ID`）。
    ///
    /// dev=`video-sky-test` / test|prod=`video-sky-prod`。此 session 承载后端"系统通知"类
    /// P2P 消息，在会话列表中**从常规 Flame/Prime/Stranger 3 tab 排除**，专门显示在 Flame
    /// 顶部 System 入口（对齐 H5 `session.js:81, 107, 331`）。
    static var notificationYxAccId: String {
        #if DEBUG
        return "video-sky-test"
        #else
        return "video-sky-prod"
        #endif
    }

    // MARK: - 主接口 AES-128-CBC
    static var aesKey: String      { plistString("HilyAESKey",     fallback: DevDefaults.aesKey) }
    static var aesIV: String       { plistString("HilyAESIV",      fallback: DevDefaults.aesIV) }

    // MARK: - sapi（vvi）AES-128-CBC
    // dev 巧合与主接口同套（已在 Config-Dev.xcconfig 显式声明 HILY_SAPI_AES_KEY/IV，不再共用 HILY_AES_KEY/IV）；
    // test 是 cbilx4v7vgz6jpw7 / dmnry3u8bhk5zq9f；prod 是另一套（Config-Prod.xcconfig 切换时务必同时换 sapi 密钥）。
    static var sapiAesKey: String  { plistString("HilySAPIAESKey", fallback: DevDefaults.sapiAesKey) }
    static var sapiAesIV: String   { plistString("HilySAPIAESIV",  fallback: DevDefaults.sapiAesIV) }

    // MARK: - WebSocket 握手 AES-128-ECB（与主接口 CBC 是两套）
    static var wsAesKey: String    { plistString("HilyWSAESKey",   fallback: DevDefaults.wsAesKey) }

    // MARK: - Settings 外链 & 静态资源（H5 config.js 蓝本一致）
    /// 主播规范图（View anchor policy 页显示的远程 png）
    static let anchorPolicyImageURL = "https://img.hnhily.link/default/anchor.png"
    /// 用户协议外链
    static let termsOfServiceURL    = "https://h5.livehot.site/#/agreement"
    /// 隐私政策外链
    static let privacyPolicyURL     = "https://h5.livehot.site/#/privacy"

    // MARK: - 内部

    /// "$(VAR)" 说明 xcconfig 没绑或变量未定义，DEBUG 用 fallback；Release abort。
    /// 这是审查报告 P0-1 + P1-2 的修复关键：dev 默认值绝不能进 prod 二进制运行时路径。
    /// 暴露为 internal static：让 AgoraConfig / 其他配置类复用同一守卫路径（避免旁路）。
    static func plistString(_ key: String, fallback: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        if raw.isEmpty || raw.hasPrefix("$(") {
            #if DEBUG
            return fallback
            #else
            let logger = Logger(subsystem: "com.anchor.livechat", category: "AppConfig")
            logger.fault("AppConfig: \(key, privacy: .public) missing from Info.plist (xcconfig not configured for this build)")
            fatalError("AppConfig: \(key) missing from Info.plist (xcconfig not configured for this build)")
            #endif
        }
        return raw
    }

    /// dev 兜底常量集中管理。
    ///
    /// **Release 隔离**：`#if DEBUG` 分支只在 DEBUG 编译时被纳入 binary，`#else` 分支
    /// 全为 ""——Release 二进制不带任何 dev 密钥字面量，攻击者 `strings IPA` 提取不到。
    /// 实际 Release 路径 `plistString` 命中 fatalError 不会真用 fallback，但仍需在编译期把
    /// dev 真值字面量从 binary 中剥离（finding P1-2 关注的 binary footprint 收尾）。
    private enum DevDefaults {
        #if DEBUG
        static let apiHost      = "anchor.cphub.link"
        static let sapiHost     = "vvi.cphub.link"
        static let socketHost   = "api.seain.site"
        static let appId        = "20735424"
        static let ocpApimKey   = "9ec52f6d03cd4d5985a6a2c8bb1ce5ee"
        static let appVersion   = "2.2.0"
        static let nimAppKey    = "124f689baed25c488e1330bc42e528af"
        static let aesKey       = "9986sdff5s4f1123"
        static let aesIV        = "9986sdff5s4y456a"
        static let sapiAesKey   = "9986sdff5s4f1123"
        static let sapiAesIV    = "9986sdff5s4y456a"
        static let wsAesKey     = "9976kk4322578894"
        #else
        static let apiHost      = ""
        static let sapiHost     = ""
        static let socketHost   = ""
        static let appId        = ""
        static let ocpApimKey   = ""
        static let appVersion   = ""
        static let nimAppKey    = ""
        static let aesKey       = ""
        static let aesIV        = ""
        static let sapiAesKey   = ""
        static let sapiAesIV    = ""
        static let wsAesKey     = ""
        #endif
    }
}
