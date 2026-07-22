import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "WishSettingService")

/// Wishlist 后端接口（对齐 H5 `src/api/live/wishlist.ts`）。
///
/// **stage 3 反悔（真机 code=1111）**：后端严格 method 校验，POST → GET/DELETE endpoint 会返
/// `{"code":"1111","message":"Please check your method type, Maybe it's GET"}`。
/// stage 3 加了 APIClient.get / .delete 支持，本 Service 3 处按 H5 严格 method 对齐。
enum WishSettingService {
    // MARK: - 模板 & 承诺池

    /// GET `/api/live/wish/template/list` → Common template 数据源
    static func getTemplateList() async throws -> [WishTemplate] {
        let data = try await APIClient.shared.get("/api/live/wish/template/list")
        return parseTemplateList(data)
    }

    /// GET `/api/live/wish/promise/pool?pageNo=1&pageSize=20` → 我的私人承诺池
    static func getPromisePool(pageNo: Int = 1, pageSize: Int = 20) async throws -> [WishTemplate] {
        let data = try await APIClient.shared.get("/api/live/wish/promise/pool",
                                                   query: ["pageNo": pageNo, "pageSize": pageSize])
        return parseTemplateList(data)
    }

    /// DELETE `/api/live/wish/promise/pool/{id}` —— stage 3 接入真接口
    static func deletePromisePoolItem(id: Int64) async throws {
        _ = try await APIClient.shared.delete("/api/live/wish/promise/pool/\(id)")
    }

    /// POST `/api/live/wish/promise/free/submit` body `{"content": string}`
    /// 错误码 `20004` = "承诺审核中"（View 层特殊 toast，不走 error banner）
    static func submitFreePromise(content: String) async throws {
        _ = try await APIClient.shared.post("/api/live/wish/promise/free/submit",
                                             body: ["content": content])
    }

    /// GET `/api/live/wish/promise/audit/list?status=&pageNo=&pageSize=`。
    static func getPromiseAuditList(status: Int?, pageNo: Int = 1, pageSize: Int = 20) async throws -> [WishPromiseAuditItem] {
        var query: [String: Any] = ["pageNo": pageNo, "pageSize": pageSize]
        if let status { query["status"] = status }
        let data = try await APIClient.shared.get("/api/live/wish/promise/audit/list", query: query)
        return parseAuditList(data)
    }

    // MARK: - wishGiftMaxNum

    /// POST `/api/agora/live/getNum` → 心愿池礼物种类上限（默认 3；后端可下发）
    static func getWishGiftMaxNum() async throws -> Int {
        let data = try await APIClient.shared.post("/api/agora/live/getNum", body: [:])
        // H5 兜底逻辑：`res?.result?.wishGiftMaxNum ?? res?.wishGiftMaxNum ?? res?.result ?? res`
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return 3 }
        if let obj = raw as? [String: Any] {
            if let n = positiveInt(obj["wishGiftMaxNum"]) { return n }
            if let result = obj["result"] as? [String: Any],
               let n = positiveInt(result["wishGiftMaxNum"]) {
                return n
            }
            if let n = positiveInt(obj["result"]) { return n }
        }
        return positiveInt(raw) ?? 3
    }

    /// JSON 数字可能位于 root/result，也可能以数字字符串返回；排除 Bool 桥接并拒绝非正值。
    private static func positiveInt(_ value: Any?) -> Int? {
        if let value = value as? Int, value > 0 { return value }
        if let value = value as? String, let number = Int(value), number > 0 { return number }
        guard let n = value as? NSNumber else { return nil }
        let cType = String(cString: n.objCType)
        guard cType != "c" && cType != "B" else { return nil }
        let number = n.intValue
        return number > 0 ? number : nil
    }

    // MARK: - Parse helpers

    /// 兼容多形态（对齐 H5 `unwrapList`）：数组 / `{result:[]}` / `{result:{records:[]}}` / `{records:[]}` / `{list:[]}` / `{data:[]}`
    /// P2-4：所有静默返 [] 路径加 log（后端字段命名升级时能观测到，避免"用户看不到任何模板"无警报）
    private static func parseTemplateList(_ data: Data) -> [WishTemplate] {
        if let arr = try? JSONDecoder().decode([WishTemplate].self, from: data) {
            return arr.filter { !$0.content.isEmpty }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("parseTemplateList: not a JSON object; returning []")
            return []
        }
        let candidates: [Any?] = [
            obj["result"],
            (obj["result"] as? [String: Any])?["records"],
            obj["records"],
            obj["list"],
            obj["data"],
        ]
        for cand in candidates {
            if let arr = cand as? [[String: Any]] {
                if let bytes = try? JSONSerialization.data(withJSONObject: arr),
                   let list = try? JSONDecoder().decode([WishTemplate].self, from: bytes) {
                    return list.filter { !$0.content.isEmpty }
                }
            }
        }
        // 未匹配任何 candidate → 后端可能升级了字段命名；log top-level keys 供排查（不 log value 避免敏感数据）
        let topKeys = Array(obj.keys).sorted().joined(separator: ",")
        logger.warning("parseTemplateList: no known list field matched, topKeys=[\(topKeys, privacy: .public)]; returning []")
        return []
    }

    private static func parseAuditList(_ data: Data) -> [WishPromiseAuditItem] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let candidates: [Any?] = [
            object,
            (object as? [String: Any])?["result"],
            ((object as? [String: Any])?["result"] as? [String: Any])?["records"],
            (object as? [String: Any])?["records"],
            (object as? [String: Any])?["list"],
        ]
        for candidate in candidates {
            guard let raw = candidate as? [[String: Any]],
                  let bytes = try? JSONSerialization.data(withJSONObject: raw),
                  let list = try? JSONDecoder().decode([WishPromiseAuditItem].self, from: bytes) else {
                continue
            }
            return list
        }
        return []
    }
}
