import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftMarqueeService")

/// 首页跑马灯数据层。
///
/// 对齐 H5 `views/home/liveList.vue` 的 `getLiveMarqueeListData()`，接口 path
/// `POST /api/anchor/getReceiveGiftRollScreen`（H5 `src/api/home/index.ts:126`）。
/// H5 调用无参：`getLiveMarqueeList()` 空 body。
///
/// 响应 envelope 解密后 result 是 array（H5 `res => marqueeList.value = res`）。
final class GiftMarqueeService: GiftMarqueeServiceProtocol {

    static let shared = GiftMarqueeService()

    private init() {}

    func fetchMarquee() async throws -> [GiftMarqueeItem] {
        let data = try await APIClient.shared.post("/api/anchor/getReceiveGiftRollScreen", body: nil)
        let items = Self.decodeItems(from: data)
        logger.info("fetchMarquee got=\(items.count)")
        return items
    }

    /// result 是 array（H5 主路径）；同款 5 路 fallback 保护契约偏移。
    static func decodeItems(from data: Data) -> [GiftMarqueeItem] {
        if String(data: data, encoding: .utf8) == "null" {
            return []
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            logger.error("decodeItems: cannot parse, bytes=\(data.count, privacy: .public) preview=\(preview, privacy: .private)")
            return []
        }
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap(GiftMarqueeItem.init(from:))
        }
        if let dict = raw as? [String: Any] {
            for key in ["list", "rows", "data", "items"] {
                if let list = dict[key] as? [[String: Any]] {
                    logger.info("decodeItems matched wrapped key=\(key, privacy: .public)")
                    return list.compactMap(GiftMarqueeItem.init(from:))
                }
            }
        }
        return []
    }
}
