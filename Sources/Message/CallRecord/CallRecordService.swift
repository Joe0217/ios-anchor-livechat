import Foundation
import os

/// 通话历史记录 service —— 对齐 H5 `apiGetRecordList`。
///
/// **接口契约**：
/// - path 字面：`POST /api/chat/v4/getCallRecord`（[src/api/news/index.ts:5](anchor-livechat-h5/src/api/news/index.ts)）
/// - body：`{ pageSize, currentPage, keyword: 1 }`（[views/communication/index.vue:131-135](anchor-livechat-h5/src/views/communication/index.vue)）
/// - response：数组 `[CallRecord]`；空数组 = 无更多数据
///
/// 后端 method 与 path 严格校验，见 [api-http-method-strict.md](../../.claude/rules/api-http-method-strict.md)。
enum CallRecordService {

    /// 拉取通话记录分页。
    ///
    /// - Parameters:
    ///   - currentPage: 页码从 1 开始（对齐 H5）
    ///   - pageSize: 每页条数；H5 固定 20
    /// - Returns: 该页 records（空数组表示"无更多"）
    static func fetch(currentPage: Int, pageSize: Int = 20) async throws -> [CallRecord] {
        let body: [String: Any] = [
            "pageSize": pageSize,
            "currentPage": currentPage,
            "keyword": 1,   // H5 固定传 1（含义未知，保持字面对齐）
        ]
        let data = try await APIClient.shared.post("/api/chat/v4/getCallRecord", body: body)
        do {
            return try JSONDecoder().decode([CallRecord].self, from: data)
        } catch {
            AppLogger.net.notice("⚠️ [CallRecordService] decode failed page=\(currentPage, privacy: .public) error=\(String(describing: error), privacy: .public)")
            let raw = String(data: data, encoding: .utf8) ?? "<not-utf8>"
            AppLogger.net.info("[CallRecordService] raw=\(raw.prefix(500), privacy: .public)")
            throw error
        }
    }
}
