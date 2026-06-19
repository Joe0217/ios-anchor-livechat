import Foundation

/// 全局配置（dev 环境，对应 H5 .env.development）。
enum AppConfig {
    /// 主 API 基址（/api 路由）
    static let apiBaseURL = "https://anchor.cphub.link"
    /// 背包商城基址（/sapi 路由）
    static let sapiBaseURL = "https://vvi.cphub.link"
    /// 在线态心跳 WebSocket 基址（dev，对应 H5 src/config/index.js socketUrl）
    static let socketBaseURL = "wss://api.seain.site"

    static let appId = "20735424"
    static let ocpApimKey = "9ec52f6d03cd4d5985a6a2c8bb1ce5ee"
    static let appVersion = "2.2.0"

    /// 云信 NIM appKey（dev，来自 H5 src/config/index.js）
    static let nimAppKey = "124f689baed25c488e1330bc42e528af"

    /// 请求体/响应体 AES-128-CBC 密钥（dev）
    static let aesKey = "9986sdff5s4f1123"
    static let aesIV = "9986sdff5s4y456a"
}
