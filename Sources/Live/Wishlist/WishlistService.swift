import Foundation

/// Wishlist 数据源协议。
///
/// H5 实际调用：
/// - POST `/api/agora/live/getAnchorWishlist` body `{ searchValue }`
/// - GET `/api/live/wish/gifter/top6?liveRecordId=&anchorId=`
protocol WishlistServiceProtocol {
    func fetchWishlist(anchorUserId: String) async throws -> [WishlistItem]
    func fetchTop6(liveRecordId: String, anchorId: String) async throws -> [WishlistTop6Item]
}

/// 真 API 实现。后端历史上会混发数字/字符串和不同外层容器，解析保持与 H5 的宽松行为一致。
struct WishlistServiceReal: WishlistServiceProtocol {
    func fetchWishlist(anchorUserId: String) async throws -> [WishlistItem] {
        let data = try await APIClient.shared.post(
            "/api/agora/live/getAnchorWishlist",
            body: ["searchValue": anchorUserId]
        )
        return try Self.parseWishlist(data)
    }

    func fetchTop6(liveRecordId: String, anchorId: String) async throws -> [WishlistTop6Item] {
        let data = try await APIClient.shared.get(
            "/api/live/wish/gifter/top6",
            query: ["liveRecordId": liveRecordId, "anchorId": anchorId]
        )
        return try Self.parseTop6(data)
    }

    static func parseWishlist(_ data: Data) throws -> [WishlistItem] {
        let raw = try JSONSerialization.jsonObject(with: data)
        return extractList(from: raw).compactMap { value in
            guard let item = value as? [String: Any],
                  let id = string(item["giftId"] ?? item["id"]), !id.isEmpty else {
                return nil
            }
            let target = max(0, int(item["giftNum"]) ?? 0)
            let completed = max(0, min(target, int(item["compelteGiftNum"] ?? item["completedGiftNum"]) ?? 0))
            return WishlistItem(
                id: id,
                giftName: string(item["giftName"] ?? item["name"]) ?? "",
                giftIconUrl: string(item["giftSmallImg"] ?? item["giftImg"] ?? item["giftIcon"]),
                giftPrice: max(0, int(item["giftPrice"]) ?? 0),
                targetCount: target,
                completedCount: completed,
                isMarkedCompleted: bool(item["completed"]) ?? false,
                promiseText: string(item["promiseText"])
            )
        }
    }

    static func parseTop6(_ data: Data) throws -> [WishlistTop6Item] {
        let raw = try JSONSerialization.jsonObject(with: data)
        let items = extractList(from: raw).enumerated().compactMap { offset, value -> WishlistTop6Item? in
            guard let item = value as? [String: Any],
                  let userId = string(item["userId"]), !userId.isEmpty else {
                return nil
            }
            return WishlistTop6Item(
                id: userId,
                userId: userId,
                nickname: string(item["nickname"] ?? item["nickName"]),
                avatarUrl: string(item["avatar"] ?? item["icon"]),
                totalDiamond: max(0, int64(item["totalDia"] ?? item["totalDiamond"]) ?? 0),
                // H5 直接按接口数组的索引填充 6 个槽位，不按 rank 字段重排。
                rank: offset + 1
            )
        }
        return Array(items.prefix(6))
    }

    private static func extractList(from raw: Any) -> [Any] {
        if let list = raw as? [Any] { return list }
        guard let object = raw as? [String: Any] else { return [] }
        for key in ["result", "wishlist", "records", "list", "data"] {
            if let value = object[key] {
                let list = extractList(from: value)
                if !list.isEmpty || value is [Any] { return list }
            }
        }
        return []
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = int64(value) { return String(number) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = int64(value) else { return nil }
        return Int(clamping: number)
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            guard type != "c", type != "B" else { return nil }
            return number.int64Value
        }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            guard type == "c" || type == "B" else { return value.intValue != 0 }
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
