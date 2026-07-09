import Foundation

/// H-3 ChatType 解析（spec §1.5.13 / §2.7 / §S7 spike）。
///
/// **数据源未确认**（S7 spike）：
/// - H5 从 `route.query.t` 读；iOS 无 URL query 概念
/// - **候选来源**：NIMSession.ext（会话粒度） / 用户资料接口（peer 粒度） / 后台配置
/// - **默认兜底**：`.regular`（rule async-state-fallback）—— 正常主播↔用户会话，不误隐藏按钮
///
/// **占位实现**：若 sessionExt 内含 `chatType: "customer"` → 判 `.customer`，否则 `.regular`。
/// S7 spike 抓包后按实际约定字段扩分支（本 resolver 单一入口便于扩展）。
enum ChatTypeResolver {

    /// **约定字段名**（暂定 `chatType`）—— S7 spike 抓包后按实际字段更正。
    static let sessionExtKey = "chatType"

    /// 从 NIMSession extension 解析。
    /// - Parameter sessionExt: NIM session 的 ext 字段（可能是 dict / JSON string / nil）
    static func resolve(from sessionExt: [String: Any]?) -> ChatType {
        guard let ext = sessionExt else { return .regular }
        if let type = ext[sessionExtKey] as? String, type == "customer" {
            return .customer
        }
        return .regular
    }
}
