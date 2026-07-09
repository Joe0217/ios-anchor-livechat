import Foundation

/// H-3 checkPrivateInfo 服务（spec §1.1.6 / §4.2 / Critical-1）。
///
/// **端点**（H5 `chat/index.vue:180-206`）：`POST /api/payPrivateMsg/checkPrivateInfo`
/// **入参**：`{userId: 主播 userId, privateIds: [String]}` —— privateId 来自 `ext.data.privateId`
/// **响应**（S3 spike 未确认）：双兼容 —— 可能是 `[{privateId, lockStatus}]` list **或** `{[privateId]: lockStatus}` dict
///
/// 返回**统一 dict** `[privateId: PrivateLockStatus]` 便于 Store 直接 merge（避免调用方每次 array → dict 转换）。
protocol CheckPrivateInfoServiceProtocol: Sendable {
    func checkPrivateInfo(userId: String, privateIds: [String]) async throws -> [String: PrivateLockStatus]
}

struct CheckPrivateInfoHTTPService: CheckPrivateInfoServiceProtocol, Sendable {
    static let shared = CheckPrivateInfoHTTPService()

    func checkPrivateInfo(userId: String, privateIds: [String]) async throws -> [String: PrivateLockStatus] {
        let data = try await APIClient.shared.post(
            "/api/payPrivateMsg/checkPrivateInfo",
            body: ["userId": userId, "privateIds": privateIds]
        )
        return try Self.parseResponse(data)
    }

    /// **响应解析纯函数**（单测覆盖点；S3 spike 双兼容）。
    ///
    /// - 分支 1（list）：`[{privateId: String|Int, lockStatus: Int}]`
    /// - 分支 2（dict）：`{[privateId]: lockStatus}`
    ///
    /// **rule ios-decode-userid-compat**：privateId 双兼容 String/Int/NSNumber。
    static func parseResponse(_ data: Data) throws -> [String: PrivateLockStatus] {
        let json = try JSONSerialization.jsonObject(with: data)

        var result: [String: PrivateLockStatus] = [:]

        // 分支 1: list
        if let arr = json as? [[String: Any]] {
            for item in arr {
                guard let pid = Self.extractPrivateId(item["privateId"]) else { continue }
                result[pid] = PrivateLockStatus(rawInt: item["lockStatus"] as? Int)
            }
            return result
        }

        // 分支 2: dict
        if let dict = json as? [String: Any] {
            for (key, value) in dict {
                let lockStatus: Int? = {
                    if let n = value as? Int { return n }
                    if let n = value as? NSNumber { return n.intValue }
                    if let s = value as? String, let n = Int(s) { return n }
                    return nil
                }()
                result[key] = PrivateLockStatus(rawInt: lockStatus)
            }
            return result
        }

        throw CheckPrivateInfoError.invalidResponse
    }

    /// privateId String/Int/NSNumber 三路兜底（rule ios-decode-userid-compat）
    private static func extractPrivateId(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber {
            let cType = String(cString: n.objCType)
            if cType != "c" && cType != "B" { return n.stringValue }
        }
        return nil
    }
}

enum CheckPrivateInfoError: Error, Equatable {
    case invalidResponse
}
