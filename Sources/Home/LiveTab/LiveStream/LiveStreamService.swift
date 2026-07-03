import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveStreamService")

/// Live 广场数据层。
///
/// 对齐 H5 `views/home/liveList.vue`：调 `POST /api/agora/live/anchorQueryLiveList`，
/// 参数 `{ pageSize, currentPage }`；H5 pageSize=20。
///
/// 响应 envelope 解密后 `result` 直接是 array（对齐 H5 `res => listData.value = res`）。
/// 走与 LiveListService 一致的 5 路 decode fallback，让契约偏移 fail-loud。
final class LiveStreamService: LiveStreamServiceProtocol {

    static let shared = LiveStreamService()

    private init() {}

    func fetchLiveList(currentPage: Int, pageSize: Int) async throws -> [LiveStreamAnchor] {
        let body: [String: Any] = [
            "currentPage": currentPage,
            "pageSize": pageSize,
        ]
        let data = try await APIClient.shared.post("/api/agora/live/anchorQueryLiveList", body: body)
        let items = Self.decodeItems(from: data)
        logger.info("fetchLiveList page=\(currentPage) got=\(items.count)")
        return items
    }

    /// result 可能是 array / wrapped dict / null。array 是 H5 主路径。
    static func decodeItems(from data: Data) -> [LiveStreamAnchor] {
        if String(data: data, encoding: .utf8) == "null" {
            return []
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            logger.error("decodeItems: cannot parse, bytes=\(data.count, privacy: .public) preview=\(preview, privacy: .private)")
            return []
        }
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap(LiveStreamAnchor.init(from:))
        }
        if let dict = raw as? [String: Any] {
            for key in ["list", "rows", "data", "items"] {
                if let list = dict[key] as? [[String: Any]] {
                    logger.info("decodeItems matched wrapped key=\(key, privacy: .public)")
                    return list.compactMap(LiveStreamAnchor.init(from:))
                }
            }
            let keys = dict.keys.sorted().joined(separator: ",")
            logger.warning("decodeItems: top-level dict without list/rows/data/items, keys=\(keys, privacy: .private)")
        }
        return []
    }
}
