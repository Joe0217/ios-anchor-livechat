import Foundation

/// 全局配置：值由 xcconfig 注入到 Info.plist，运行时从 plist 读出。
/// 多环境切换走 Config/Config-Dev.xcconfig ↔ Config/Config-Prod.xcconfig。
///
/// 内置 fallback：plist 缺失 / 残留字面 "$(VAR)" 时回 dev 默认值——
/// 真机直跑（无 configFiles）或忘配 xcconfig 时仍能跑通 dev，不至于硬崩。
enum AppConfig {
    // MARK: - 域名（xcconfig 只存 host，scheme 在此拼接，避开 "//" 注释坑）
    static var apiBaseURL: String    { "https://" + plistString("HilyAPIHost",   fallback: "anchor.cphub.link") }
    static var sapiBaseURL: String   { "https://" + plistString("HilySAPIHost",  fallback: "vvi.cphub.link") }
    static var socketBaseURL: String { "wss://"  + plistString("HilySocketHost", fallback: "api.seain.site") }

    // MARK: - 主接口鉴权 / 业务版本
    static var appId: String       { plistString("HilyAppID",      fallback: "20735424") }
    static var ocpApimKey: String  { plistString("HilyOcpApimKey", fallback: "9ec52f6d03cd4d5985a6a2c8bb1ce5ee") }
    static var appVersion: String  { plistString("HilyAppVersion", fallback: "2.2.0") }

    // MARK: - 云信 NIM
    static var nimAppKey: String   { plistString("HilyNIMAppKey",  fallback: "124f689baed25c488e1330bc42e528af") }

    // MARK: - 主接口 AES-128-CBC
    static var aesKey: String      { plistString("HilyAESKey",     fallback: "9986sdff5s4f1123") }
    static var aesIV: String       { plistString("HilyAESIV",      fallback: "9986sdff5s4y456a") }

    // MARK: - sapi（vvi）AES-128-CBC
    // dev 巧合与主接口同套（已在 Config-Dev.xcconfig 显式声明 HILY_SAPI_AES_KEY/IV，不再共用 HILY_AES_KEY/IV）；
    // test 是 cbilx4v7vgz6jpw7 / dmnry3u8bhk5zq9f；prod 是另一套（Config-Prod.xcconfig 切换时务必同时换 sapi 密钥）。
    // 来源：anchor-livechat-h5 .env.* VITE_AES_KEY_BAGSHOP_URL / VITE_AES_IV_BAGSHOP_URL。
    // fallback 仅为 xcconfig 缺失时的兜底，不应作为正式发布值。
    static var sapiAesKey: String  { plistString("HilySAPIAESKey", fallback: "9986sdff5s4f1123") }
    static var sapiAesIV: String   { plistString("HilySAPIAESIV",  fallback: "9986sdff5s4y456a") }

    // MARK: - WebSocket 握手 AES-128-ECB（与主接口 CBC 是两套）
    static var wsAesKey: String    { plistString("HilyWSAESKey",   fallback: "9976kk4322578894") }

    // MARK: - 内部
    private static func plistString(_ key: String, fallback: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        // "$(VAR)" 说明 xcconfig 没绑或变量未定义，按 fallback 走
        if raw.isEmpty || raw.hasPrefix("$(") { return fallback }
        return raw
    }
}
