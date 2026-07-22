import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "app-config-store")

/// H-3 横断基建：全局配置的 **有状态** 单例（对齐 H5 `useAppStore.AppConfig` + `homeStore.microsoftTranslatorConfig`）。
///
/// **为何独立于 `AppConfigService`**：
/// - `AppConfigService` 是**无状态**函数式拉取（`fetch(keys:) -> [String: Any]`）；
/// - 本 Store 是**登录会话粒度**的状态缓存 + `@Published` 派生 bridge 分发；
/// - `SessionStore.login` 后 activate；`logout` 后 clear（挂 session-scoped rule）。
///
/// **拉取的 4 个 key**（H5 `app.js:417` 一次逗号 join）：
/// - `achor_hide_button` — 视频通话按钮显隐（后端 typo 少个 r）；子串匹配 `mine.levelName`（H5 `state.myAnchorInfo.userLevel`）
/// - `microsoft_translator_config` — 翻译服务 key/area（**JSON string 二次 parse**；对齐 H5 `app.js:421` `translatorConfig.key/area`，字段名不是 region）
/// - `pay_msg_points` — 用户付费消息单条积分
/// - `free_msg_points` — 用户免费消息单条积分
///
/// **hardcoded fallback**（对齐 H5，密钥本身在 H5 前端已明文暴露；未来收紧可改 `#if DEBUG`）：
/// `microsoftTranslatorKey = "75966eed4f5c49de8635c4f004dbc5d9"` / `microsoftTranslatorArea = "eastus2"`
///
/// **失败兜底**：接口异常时仍设 `isLoaded = true`（避免 view flash 永久阻塞）+ 应用 fallback key/area。
///
/// **测试注入**：`init(fetch:)` 接收 fetch closure，`shared` 用真实 `AppConfigService.fetch`，
/// 单测传 stub 覆盖成功/失败/parse 失败三种路径。
@MainActor
final class AppConfigStore: ObservableObject {
    static let shared = AppConfigStore(fetch: { keys in try await AppConfigService.fetch(keys: keys) })

    // MARK: - 派生字段

    @Published private(set) var achorHideButton: String?
    @Published private(set) var payMsgPoints: Int?
    @Published private(set) var freeMsgPoints: Int?
    @Published private(set) var microsoftTranslatorKey: String?
    @Published private(set) var microsoftTranslatorArea: String?
    /// v26（2026-07-15）：PK 后端配置（对齐 H5 `app.js:459-466` pkStore.pkSettings）
    /// - `pk_match_duration` → 随机匹配重试阶段时长（秒；nil 兜底 300s）
    /// - `pk_effective_value` → PK 有效值阈值（PKHistoryPopup 提示用）
    /// - `pk_gift_queue` → PK 期礼物队列最大长度（GiftEffect PK 期重排用；nil 兜底 15）
    @Published private(set) var pkMatchDuration: Int?
    @Published private(set) var pkEffectiveValue: Int?
    @Published private(set) var pkGiftQueue: Int?
    /// v26（2026-07-15）：通话充值等待页 UX 参数（对齐 H5 `app.js:454-455` call_config JSON 二次 parse）
    /// - `call_wait_time` → 充值等待主倒计时秒数（nil 兜底 60；对齐 H5 topBar.vue:20 `|| 60`）
    /// - `anchor_call_balance_reward_on_low` → 提示文案预计奖励数（nil 兜底 100；对齐 H5 waitRechargeTips.vue `|| 100`）
    ///   ⚠️ iOS 目前无对应"预计奖励文案"UI 组件，字段先接入等 UI 补齐时消费
    @Published private(set) var callWaitTime: Int?
    @Published private(set) var anchorCallBalanceRewardOnLow: Int?
    @Published private(set) var isLoaded: Bool = false

    // MARK: - 硬编 fallback（对齐 H5 前端明文，密钥非新增暴露面）

    static let translatorKeyFallback = "75966eed4f5c49de8635c4f004dbc5d9"
    static let translatorAreaFallback = "eastus2"

    // MARK: - 拉取的 key 列表（H5 `app.js:417` 一次逗号 join）

    static let fetchKeys: [String] = [
        "achor_hide_button",
        "microsoft_translator_config",
        "pay_msg_points",
        "free_msg_points",
        // v26（2026-07-15）：pkSettings 3 key（对齐 H5 app.js:446 batch）
        "pk_match_duration",
        "pk_effective_value",
        "pk_gift_queue",
        // v26（2026-07-15）：通话充值等待 UX 参数（对齐 H5 app.js:446 batch；后端 JSON string 二次 parse）
        "call_config",
    ]

    // MARK: - 依赖注入

    private let fetch: ([String]) async throws -> [String: Any]

    init(fetch: @escaping ([String]) async throws -> [String: Any]) {
        self.fetch = fetch
    }

    // MARK: - 生命周期（挂 SessionStore.login/logout）

    /// login 成功后调用；一次拉取 4 key + 二次 parse microsoft 配置。
    /// 幂等：即使已 loaded 再调也重新覆盖字段。
    func activate() async {
        do {
            let dict = try await fetch(Self.fetchKeys)

            // 1. 直接扁平字段
            achorHideButton = dict["achor_hide_button"] as? String
            payMsgPoints = Self.intFromAny(dict["pay_msg_points"])
            freeMsgPoints = Self.intFromAny(dict["free_msg_points"])
            // v26（2026-07-15）：pkSettings 3 key（对齐 H5 app.js:459-466 intFromAny 转数字）
            pkMatchDuration = Self.intFromAny(dict["pk_match_duration"])
            pkEffectiveValue = Self.intFromAny(dict["pk_effective_value"])
            pkGiftQueue = Self.intFromAny(dict["pk_gift_queue"])

            // v26（2026-07-15）：call_config JSON string 二次 parse（对齐 H5 app.js:454-455 jsonStrTranslateJson）
            // H5 结构：{call_wait_time: Int|String, anchor_call_balance_reward_on_low: Int|String}
            if let raw = dict["call_config"] as? String,
               let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                callWaitTime = Self.intFromAny(obj["call_wait_time"])
                anchorCallBalanceRewardOnLow = Self.intFromAny(obj["anchor_call_balance_reward_on_low"])
                logger.info("[AppConfig] call_config parsed: callWaitTime=\(self.callWaitTime ?? -1) rewardOnLow=\(self.anchorCallBalanceRewardOnLow ?? -1)")
            } else {
                callWaitTime = nil
                anchorCallBalanceRewardOnLow = nil
                logger.info("[AppConfig] call_config missing or parse failed; will use CallStore local fallback (60/100)")
            }

            // 2. microsoft_translator_config: JSON string 二次 parse（H5 `app.js:421`）
            if let raw = dict["microsoft_translator_config"] as? String,
               let data = raw.data(using: .utf8),
               let cfg = try? JSONDecoder().decode(TranslatorConfig.self, from: data) {
                microsoftTranslatorKey = cfg.key
                microsoftTranslatorArea = cfg.area
                logger.info("[AppConfig] microsoft translator loaded from config")
            } else {
                microsoftTranslatorKey = Self.translatorKeyFallback
                microsoftTranslatorArea = Self.translatorAreaFallback
                logger.info("[AppConfig] microsoft translator using hardcoded fallback (config missing or parse failed)")
            }

            isLoaded = true
            logger.info("[AppConfig] activate success: achor_hide_button=\(self.achorHideButton ?? "nil", privacy: .public) payPoints=\(self.payMsgPoints ?? -1) freePoints=\(self.freeMsgPoints ?? -1) pkMatchDur=\(self.pkMatchDuration ?? -1) pkEffective=\(self.pkEffectiveValue ?? -1) pkGiftQueue=\(self.pkGiftQueue ?? -1)")
        } catch {
            // 网络失败 / 后端异常兜底：不阻塞 view，用 fallback + isLoaded=true
            microsoftTranslatorKey = Self.translatorKeyFallback
            microsoftTranslatorArea = Self.translatorAreaFallback
            isLoaded = true
            logger.warning("[AppConfig] activate failed, applied fallbacks: \(String(describing: error), privacy: .public)")
        }
    }

    /// logout 时清空。`isLoaded=false` 让下游 bridge 回落到"未就绪"态。
    func clear() {
        achorHideButton = nil
        payMsgPoints = nil
        freeMsgPoints = nil
        microsoftTranslatorKey = nil
        microsoftTranslatorArea = nil
        pkMatchDuration = nil
        pkEffectiveValue = nil
        pkGiftQueue = nil
        callWaitTime = nil
        anchorCallBalanceRewardOnLow = nil
        isLoaded = false
    }

    // MARK: - Codable helper

    /// 后端返 int/string/NSNumber 皆兼容（rule ios-decode-userid-compat 精神）。
    static func intFromAny(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let n = Int(s) { return n }
        return nil
    }
}

/// H5 `app.js:421-422` 内嵌 `{key, area}` JSON string 结构。
/// **字段名是 `area` 而非 `region`**（HTTP header `Ocp-Apim-Subscription-Region` 是标准名，
/// 但配置字段是 area）。
struct TranslatorConfig: Decodable, Equatable {
    let key: String
    let area: String
}
