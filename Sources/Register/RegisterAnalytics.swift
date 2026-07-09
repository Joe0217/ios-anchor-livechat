import Foundation
import os

/// 一期埋点桩：no-op + os.Logger 打日志（对齐 spec §0.15 v3 + 用户 2026-07-08 决策"先不接埋点，优先完成功能"）
///
/// J 里程碑接 ThinkingData 后一处改：把 `logger.info` 换为 `ThinkingData.track(event.rawValue, properties: extra)`
enum RegisterAnalytics {

    private static let logger = Logger(subsystem: "com.anchor.livechat", category: "RegisterAnalytics")

    static func report(_ event: Event, extra: [String: Any] = [:]) {
        logger.info("[Analytics] \(event.rawValue, privacy: .public) \(extra.description, privacy: .public)")
    }

    /// 对齐 H5 4 个埋点事件（`login/index.vue:94` + `register/index.vue:24,60,62`）
    enum Event: String {
        case signUp   = "h_signUp"      // login 1005 → push register（进入注册页）
        case reviewInf = "h_reviewInf"  // Page 1 → Page 2（基本信息填完）
        case videoInf = "h_videoInf"    // Page 2 视频 OSS 上传完成
        case appSign  = "app_sign"      // 注册接口成功（首次或重录）
    }
}
