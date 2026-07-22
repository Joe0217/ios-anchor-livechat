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
    ///
    /// **派对房场景不在此**：H5 派对房走独立 sapi 接口 `apiPartyGetRoomGift`（`PartyAPI.getPartyRoomGift`），
    /// 不走本 `/api/gift/v3/getGiftList`（主接口不识别 PARTY_ROOM/PARTY_GIFT scene → 后端返 1001 parameter.error）。
    enum Scene: String {
        case call = "CALL"
        case live = "LIVE"
        case im = "IM"
        case profile = "PROFILE"
        case wish = "WISH"      // 心愿单场景
    }

    /// 拉取指定场景的礼物列表（v3 endpoint）—— flatten 版。
    ///
    /// 请求：`POST /api/gift/v3/getGiftList` body `{"searchValue": "CALL"}`
    /// 响应结构：`result = { giftList: { <groupName>: [GiftListData], ... } }`
    /// 例如 `giftList.Popular / giftList.Luxury / giftList.Combo` 等分组
    /// —— 本方法 flatten 所有分组 + 按 id 去重后返回单一数组。
    ///
    /// **调用者约束**（H-4 spec §1.5）：仅剩 2 处非-picker 调用（`LiveSettingsStore.restorePrivateCallGift` id→gift 反查、
    /// `GiftMessageService.fetchGifts` IM item 转换）。其他 UI 场景请用 [getGroupedGiftList] + `CommonGiftPanel`。
    static func getGiftList(scene: Scene = .call) async throws -> [GiftListData] {
        let data = try await APIClient.shared.post("/api/gift/v3/getGiftList",
                                                    body: ["searchValue": scene.rawValue])
        return try parseGiftListResponse(data)
    }

    /// 拉取指定场景的礼物列表（v3 endpoint）—— 保留分组版。
    ///
    /// 返回 `[groupName: [GiftListData]]`（如 `["Popular": [...], "Exclusive": [...]]`），
    /// 供 `CommonGiftPanel` 按 tab 映射（`GiftPanelTab.fromGroupName` 硬编码表）。
    /// 未知 group name 由调用方决定 drop / merge（本 service 不做 tab 语义判断，只保留原名）。
    ///
    /// 响应形态：仅识别 v3 grouped `{giftList: {group: [gift]}}`；老形态数组 / 单 giftList 数组走 fallback 单 group "Popular"。
    static func getGroupedGiftList(scene: Scene = .call) async throws -> [String: [GiftListData]] {
        let data = try await APIClient.shared.post("/api/gift/v3/getGiftList",
                                                    body: ["searchValue": scene.rawValue])
        return try parseGroupedGiftListResponse(data)
    }

    /// 内部：解析保留 group name 的响应；三种形态兜底同 [parseGiftListResponse]，但**不 flatten**。
    /// - v3 grouped dict → 保留 group name 与顺序
    /// - 数组 / 数组内嵌 → 归到单 group "Popular"
    /// - 非法 shape → throw APIError
    static func parseGroupedGiftListResponse(_ data: Data) throws -> [String: [GiftListData]] {
        // 形态 1：直接数组 → 单 group Popular
        if let arr = try? JSONDecoder().decode([GiftListData].self, from: data), !arr.isEmpty {
            logger.info("getGroupedGiftList ok (array form → single Popular group) count=\(arr.count)")
            return ["Popular": arr]
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("getGroupedGiftList unparseable (not object)")
            throw APIError(code: "-1", message: "gift list unparseable")
        }
        // 形态 2：giftList 是数组 → 单 group Popular
        if let list = obj["giftList"] as? [[String: Any]] {
            let listData = try JSONSerialization.data(withJSONObject: list)
            let arr = try JSONDecoder().decode([GiftListData].self, from: listData)
            logger.info("getGroupedGiftList ok (object.giftList array → single Popular group) count=\(arr.count)")
            return ["Popular": arr]
        }
        // 形态 3：giftList 是 group dict —— v3 真实形态
        if let groups = obj["giftList"] as? [String: Any] {
            var result: [String: [GiftListData]] = [:]
            for (name, raw) in groups {
                // 单 group 内允许 [[String:Any]] 或空数组；非法 shape 静默 drop（R19：混合形态不炸）
                guard let list = raw as? [[String: Any]] else {
                    logger.info("getGroupedGiftList group \(name, privacy: .public) not [[String:Any]] shape; dropping")
                    continue
                }
                if list.isEmpty {
                    result[name] = []
                    continue
                }
                if let listData = try? JSONSerialization.data(withJSONObject: list),
                   let arr = try? JSONDecoder().decode([GiftListData].self, from: listData) {
                    result[name] = arr
                } else {
                    logger.info("getGroupedGiftList group \(name, privacy: .public) decode failed; dropping")
                }
            }
            logger.info("getGroupedGiftList ok (v3 grouped) groups=\(result.count)")
            return result
        }
        logger.error("getGroupedGiftList unparseable (unknown giftList shape)")
        throw APIError(code: "-1", message: "gift list unparseable")
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

    /// 1v1 通话内主播索要礼物（对齐 H5 `src/api/gift/index.ts:30` + `g-faceTime/index.vue:203-215` askFor）。
    ///
    /// 请求：`POST /api/gift/askFor` body `{beAskYxAccid: <对方 yxAccid>, giftId: <礼物 id>}`
    /// 响应：`{result: null}`——无实际业务数据，成功即完成（对齐 H5 `http.post<null>`）
    ///
    /// 调用侧（`CallFaceTimeView` gift 按钮）自行做 15s 冷却 + 本地 toast。
    static func askFor(beAskYxAccid: String, giftId: Int64) async throws {
        _ = try await APIClient.shared.post("/api/gift/askFor",
                                             body: ["beAskYxAccid": beAskYxAccid,
                                                    "giftId": giftId])
        logger.info("askFor OK peer=… giftId=\(giftId, privacy: .public)")
    }
}
