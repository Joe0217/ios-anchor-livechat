import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveListService")

/// 用户列表数据层。
///
/// 对齐 H5 `views/home/online/online.vue`：调 `/api/user/anchorGetUserList`，
/// 参数 `userType=1, keyword, currentPage, pageSize=20`；H5 prime 子页同一接口，
/// 仅 `keyword` 由 1 改 2（见 `prime/prime.vue`）。
///
/// 响应是 envelope `result` 字段直为数组（H5 用 `res.push({isEnd:true})` 直接处理 array）。
/// 这里走与 BlocklistService 一致的 5 路 decode fallback，让契约偏移 fail-loud。
final class LiveListService: LiveListServiceProtocol {

    static let shared = LiveListService()

    private init() {}

    func fetchUsers(keyword: Int, currentPage: Int, pageSize: Int) async throws -> [LiveListAnchor] {
        let body: [String: Any] = [
            "userType": 1,
            "keyword": keyword,
            "currentPage": currentPage,
            "pageSize": pageSize,
        ]
        let data = try await APIClient.shared.post("/api/user/anchorGetUserList", body: body)
        let items = Self.decodeItems(from: data)
        logger.info("fetchUsers keyword=\(keyword) page=\(currentPage) got=\(items.count)")
        return items
    }

    /// 5 路 fallback decode（与 BlocklistService 同款）。
    static func decodeItems(from data: Data) -> [LiveListAnchor] {
        if String(data: data, encoding: .utf8) == "null" {
            return []
        }
        let decoder = JSONDecoder()
        if let arr = try? decoder.decode([LiveListAnchor].self, from: data) {
            return arr
        }
        if let wrapped = try? decoder.decode([String: [LiveListAnchor]].self, from: data) {
            for key in ["list", "rows", "data", "items"] {
                if let list = wrapped[key] {
                    logger.info("decodeItems matched wrapped key=\(key, privacy: .public)")
                    return list
                }
            }
        }
        // 顶层 dict 但找不到合理 key：keys 当前契约下只是字段名，但若后端改为 userId-keyed map
        // 会泄漏用户 ID → 显式标 .private 让 release 自动脱敏。
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any] {
            let keys = dict.keys.sorted().joined(separator: ",")
            logger.warning("decodeItems: top-level dict without list/rows/data/items, keys=\(keys, privacy: .private)")
            return []
        }
        // 完全无法解析：data 是解密后的响应明文，几乎必然含 nickname/icon/yxAccid 等 PII，
        // 必须 .private 让 release 落盘时 redact 为 <private>，仅 bytes 长度走 .public 用于排查。
        let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
        logger.error("decodeItems: cannot parse, bytes=\(data.count, privacy: .public) preview=\(preview, privacy: .private)")
        return []
    }
}
