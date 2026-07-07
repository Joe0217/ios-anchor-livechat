import Foundation

/// Prime 等级批量过滤接口的请求/响应 Codable model（H-1 MVP，spec §1.3 v4 修订）。
///
/// **接口**（H5 `apiBatchQueryYxPrimeFilter` → `POST /api/anchor/messageLevelLimit`）：
/// - Request body: `{"yxAccId": ["uid1", "uid2", ...]}`
/// - Response body: **APIClient.post 剥完 envelope + 解密后**是 top-level `[String]` 数组
///   （已过滤 Prime yxAccId），**不是** `{"result": [...]}` 包装（spec v1 写错，v3 Step 3 真机反悔 #3 校正）
///
/// **容错**：非数组 / null → 空集（视为该批无 Prime，不抛 decode 错）
struct PrimeLevelResponse: Decodable {
    let result: [String]

    init(from decoder: Decoder) throws {
        // 顶层 array 用 singleValueContainer 解，容错 fallback 空数组
        let single = try decoder.singleValueContainer()
        self.result = (try? single.decode([String].self)) ?? []
    }

    /// 便利初始化（供 Fake / 单测直接构造）
    init(result: [String]) {
        self.result = result
    }
}
