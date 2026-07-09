import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "BlocklistService")

/// 黑名单数据层（spec §4.1）。
///
/// step 1c：真接口实现。`fetchActive` 调 H5 路径 `/api/user/blackList`（V1 主动黑名单，
/// V2 被动黑名单本期不做）；`removeBlock` 调 `/api/user/removeBlockUser`。
/// 5 路 decode fallback 抽到 `decodeItems(from:)` static，单测直测。
final class BlocklistService: BlocklistServiceProtocol {

    static let shared = BlocklistService()

    private init() {}

    /// 拉取主播主动黑名单列表（V1）。
    /// 与 H5 `blackList({currentPage, pageSize})` 对齐；响应是 `result` 直接为数组。
    func fetchActive(page: Int, size: Int) async throws -> [BlocklistItem] {
        let body: [String: Any] = [
            "currentPage": page,
            "pageSize": size,
        ]
        let data = try await APIClient.shared.post("/api/user/blackList", body: body)
        let items = Self.decodeItems(from: data)
        logger.info("fetchActive page=\(page) size=\(size) got=\(items.count)")
        return items
    }

    /// 移除黑名单。`type` 默认 1（spec §10 Q8 step 0 决策：H5 硬编 1，真集成验证）。
    func removeBlock(request: BlockOptRequest) async throws {
        let body: [String: Any] = [
            "type": request.type,
            "userId": request.userId,
            "yxAccid": request.yxAccid,
        ]
        _ = try await APIClient.shared.post("/api/user/removeBlockUser", body: body)
        logger.info("removeBlock type=\(request.type) userId=\(request.userId) ok")
    }

    // MARK: - Decode 5 路 fallback（spec §4.1 / R-21）

    /// 解码 envelope `result` 字段为 `[BlocklistItem]`。
    ///
    /// 5 路 fallback（按优先级）：
    /// 1. `Data("null".utf8)`（APIClient 在 result=null 时返回）→ 空数组（spec R-21）
    /// 2. 顶层是数组 → 直接 decode
    /// 3. 顶层是字典且含 `list/rows/data/items` 数组键 → 取该键 decode
    /// 4. 顶层是字典但找不到合理位置 → 空数组 + warn 日志，让 step 3 反悔暴露
    /// 5. 完全无法 JSON 解析 → 空数组 + error 日志
    ///
    /// `BlocklistItem` 严格 String userId / Int64 createTimeMs：类型偏移 decode 抛错，
    /// 此处的 5 路尝试都 fail-loud 落到日志而非静默掩盖（spec R-9）。
    static func decodeItems(from data: Data) -> [BlocklistItem] {
        // 1. null 字面量先检测（避免 JSONDecoder.decode([T], from: "null") 抛 valueNotFound）
        if String(data: data, encoding: .utf8) == "null" {
            return []
        }

        let decoder = JSONDecoder()

        // 2. 顶层数组（H5 标准响应）
        if let arr = try? decoder.decode([BlocklistItem].self, from: data) {
            return arr
        }

        // 3. {list/rows/data/items: [...]} 包裹
        if let wrapped = try? decoder.decode([String: [BlocklistItem]].self, from: data) {
            for key in ["list", "rows", "data", "items"] {
                if let list = wrapped[key] {
                    logger.info("decodeItems matched wrapped key=\(key)")
                    return list
                }
            }
        }

        // 4. 顶层字典但找不到合理位置 → 空 + warn（让 step 3 反悔暴露）
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any] {
            logger.warning("decodeItems: top-level dict without list/rows/data/items, keys=\(dict.keys.sorted().joined(separator: ","))")
            return []
        }

        // 5. 完全无法解析
        // P2-17：响应明文含 nickname/icon/userId 等 PII，preview 走 .private 防 sysdiagnose 泄漏
        let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
        logger.error("decodeItems: cannot parse, bytes=\(data.count, privacy: .public) preview=\(preview, privacy: .private)")
        return []
    }
}
