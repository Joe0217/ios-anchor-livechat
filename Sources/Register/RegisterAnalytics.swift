import Foundation
/// 注册链路数数事件，对齐 H5 事件名。
enum RegisterAnalytics {
    static func report(_ event: Event, extra: [String: Any] = [:]) {
        AnalyticsTracker.track(event.rawValue, properties: extra)
    }

    /// 对齐 H5 4 个埋点事件（`login/index.vue:94` + `register/index.vue:24,60,62`）
    enum Event: String {
        case signUp   = "h_signUp"      // login 1005 → push register（进入注册页）
        case reviewInf = "h_reviewInf"  // Page 1 → Page 2（基本信息填完）
        case videoInf = "h_videoInf"    // Page 2 视频 OSS 上传完成
        case appSign  = "app_sign"      // 注册接口成功（首次或重录）
    }
}
