import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftService")

/// 礼物相关接口（对齐 H5 `src/api/gift/index.ts:10` + `stores/modules/gift.js:157-160`）。
///
/// **本次范围**：仅 `getGiftList(scene:)`（v3，主播开播设置页私 call 礼物选择用）。
/// v1/v2 endpoint 后端已下线（真机验证 `/api/gift/getGiftList` → 404）。
/// `sendGift` / `giftDelivery` 等归 H 里程碑（礼物系统整体接入）。
enum GiftService {
    /// 场景枚举（对齐 H5 `giftStore.getGiftListData('CALL')`）。私 call 礼物场景用 CALL；心愿单用 WISH。
    enum Scene: String {
        case call = "CALL"
        case live = "LIVE"
        case im = "IM"
        case profile = "PROFILE"
        case wish = "WISH"      // 心愿单场景
    }

    /// 拉取指定场景的礼物列表（v3 endpoint）。
    ///
    /// 请求：`POST /api/gift/v3/getGiftList` body `{"searchValue": "CALL"}`
    /// 响应结构：`result = { giftList: { <groupName>: [GiftListData], ... } }`
    /// 例如 `giftList.Popular / giftList.Luxury / giftList.Combo` 等分组
    /// —— 本方法 flatten 所有分组 + 按 id 去重后返回单一数组供 GiftPickerSheet 单选。
    static func getGiftList(scene: Scene = .call) async throws -> [GiftListData] {
        let data = try await APIClient.shared.post("/api/gift/v3/getGiftList",
                                                    body: ["searchValue": scene.rawValue])
        return try parseGiftListResponse(data)
    }

    /// 内部：兼容三种形态（后端历史多样）：
    /// - 直接数组 `[gift1, gift2, ...]`（v1 老形态，兜底保留）
    /// - `{giftList: [gift1, gift2, ...]}`（v2 老形态，兜底保留）
    /// - `{giftList: {group: [gift1, gift2, ...], ...}}`（**v3 真实形态**，H5 gift.js:159 用法）
    static func parseGiftListResponse(_ data: Data) throws -> [GiftListData] {
        // 形态 1：直接数组
        if let arr = try? JSONDecoder().decode([GiftListData].self, from: data), !arr.isEmpty {
            logger.info("getGiftList ok (array form) count=\(arr.count)")
            return arr
        }
        // 形态 2/3：对象内嵌 giftList
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("getGiftList unparseable (not object)")
            throw APIError(code: "-1", message: "gift list unparseable")
        }
        // 形态 2：giftList 是数组
        if let list = obj["giftList"] as? [[String: Any]] {
            let listData = try JSONSerialization.data(withJSONObject: list)
            let arr = try JSONDecoder().decode([GiftListData].self, from: listData)
            logger.info("getGiftList ok (object.giftList array) count=\(arr.count)")
            return arr
        }
        // 形态 3：giftList 是 group 字典 —— v3 真实形态
        if let groups = obj["giftList"] as? [String: [[String: Any]]] {
            var seen = Set<Int64>()
            var merged: [GiftListData] = []
            for (_, list) in groups {
                let listData = try JSONSerialization.data(withJSONObject: list)
                let arr = try JSONDecoder().decode([GiftListData].self, from: listData)
                for g in arr where !seen.contains(g.id) {
                    seen.insert(g.id)
                    merged.append(g)
                }
            }
            logger.info("getGiftList ok (v3 grouped) groups=\(groups.count) merged=\(merged.count)")
            return merged
        }
        logger.error("getGiftList unparseable (unknown giftList shape)")
        throw APIError(code: "-1", message: "gift list unparseable")
    }
}
