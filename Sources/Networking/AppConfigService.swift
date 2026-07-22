import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "app-config")

/// 全局配置服务（对齐 H5 `/api/index/getConfigByKey`）。
///
/// 后端约定 body `{searchValue: "key1,key2,..."}`，返回 `{key1: value1, key2: value2}` dict。
/// 目前只用于拉取 `max_no_use_app_reminder_time`（长时间无操作自动离线阈值），
/// 未来需要 `anchor_private_reply` / `agora_config` 等可批量传 key 复用同一接口。
enum AppConfigService {

    /// 拉取多个配置 key。返回 dict（可能只含部分请求的 key —— 服务端仅返回已配置的）。
    /// - Parameter keys: 请求的 key 数组，将拼成 `searchValue: "k1,k2,..."`
    static func fetch(keys: [String]) async throws -> [String: Any] {
        let searchValue = keys.joined(separator: ",")
        let data = try await APIClient.shared.post(
            "/api/index/getConfigByKey",
            body: ["searchValue": searchValue]
        )
        // result 已由 APIClient 解密为明文 JSON
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("[AppConfig] response not dict for keys=\(keys.joined(separator: ","), privacy: .public)")
            return [:]
        }
        return dict
    }

    /// 2026-07-16 便利方法：拉取官方 WhatsApp 号(对齐 H5 `getConfigByKey({searchValue: 'WhatsApp'})`)。
    /// 服务端未配置 or 拉取失败均返回 nil,UI 层用硬编码 fallback。
    /// 受限首屏 mineRestricted/newsRestricted + Work 页 联系客服 3 处复用。
    static func fetchWhatsAppPhone() async -> String? {
        do {
            let dict = try await fetch(keys: ["WhatsApp"])
            if let s = dict["WhatsApp"] as? String, !s.isEmpty { return s }
            if let n = dict["WhatsApp"] as? NSNumber { return n.stringValue }
            return nil
        } catch {
            logger.error("[AppConfig] fetchWhatsAppPhone failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 便利方法：拉取"长时间无操作自动离线"阈值（分钟）。
    /// 服务端未配置 or 拉取失败均返回 0（AutoOfflineMonitor 内 0 = 不启用）。
    static func fetchAutoOfflineReminderMinutes() async -> Int {
        do {
            let dict = try await fetch(keys: ["max_no_use_app_reminder_time"])
            // 后端可能返 String / Int / NSNumber，兼容
            if let n = dict["max_no_use_app_reminder_time"] as? Int { return n }
            if let s = dict["max_no_use_app_reminder_time"] as? String, let n = Int(s) { return n }
            if let n = dict["max_no_use_app_reminder_time"] as? NSNumber { return n.intValue }
            return 0
        } catch {
            logger.error("[AppConfig] fetchAutoOfflineReminderMinutes failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }
}
