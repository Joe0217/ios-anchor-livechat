import Foundation
import os

private let guardianLogger = Logger(subsystem: "com.anchor.livechat", category: "GuardianService")

/// 主播守护只读数据源。购买、续费和升级是用户端能力，不能通过本协议暴露。
protocol GuardianServiceProtocol: Sendable {
    func fetchPanel(anchorId: Int64) async throws -> GuardianPanel
    func fetchList(anchorId: Int64, page: Int, pageSize: Int) async throws -> GuardianListPage
}

struct GuardianService: GuardianServiceProtocol {
    /// H5 `src/api/guardian/index.ts`：POST `/api/guardian/panel` body `{ anchorId }`。
    func fetchPanel(anchorId: Int64) async throws -> GuardianPanel {
        let data = try await APIClient.shared.post(
            "/api/guardian/panel",
            body: ["anchorId": anchorId]
        )
        #if DEBUG
        guardianLogger.debug("Guardian panel raw=\(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .private)")
        #endif
        return try GuardianResponseAdapter.panel(from: data, requestedAnchorId: anchorId)
    }

    /// H5 `src/api/guardian/index.ts`：POST `/api/guardian/list`，pageNum 从 1 开始。
    func fetchList(anchorId: Int64, page: Int, pageSize: Int) async throws -> GuardianListPage {
        let data = try await APIClient.shared.post(
            "/api/guardian/list",
            body: [
                "anchorId": anchorId,
                "pageNum": page,
                "pageSize": pageSize
            ]
        )
        #if DEBUG
        guardianLogger.debug("Guardian list page=\(page, privacy: .public) raw=\(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .private)")
        #endif
        return try GuardianResponseAdapter.list(from: data, page: page, pageSize: pageSize)
    }
}
