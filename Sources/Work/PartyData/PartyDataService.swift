import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PartyDataService")

protocol PartyDataServiceProtocol {
    /// 主看板：`POST /api/anchor/party/data/board`（安卓 `HttpHelper.kt`:669）
    func fetchBoard(dateType: PartyDataDateType) async throws -> PartyDataBoardResponse

    /// 麦时二级页：`POST /api/anchor/party/data/micTimeDetail`（安卓 `HttpHelper.kt`:676）
    /// - Parameters:
    ///   - dateType: 期间
    ///   - statDate: 可选。为 nil 时"周期维度查全部房间"；有值时"单日维度按房间聚合"（安卓 :55-59 两入口）
    func fetchMicTimeDetail(dateType: PartyDataDateType, statDate: String?) async throws -> [PartyMicTimeDetailItem]
}

final class PartyDataService: PartyDataServiceProtocol {
    static let shared = PartyDataService()
    private init() {}

    func fetchBoard(dateType: PartyDataDateType) async throws -> PartyDataBoardResponse {
        let data = try await APIClient.shared.post(
            "/api/anchor/party/data/board",
            body: ["dateType": dateType.rawValue]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("fetchBoard dateType=\(dateType.rawValue, privacy: .public) raw=\(raw, privacy: .private)")
        #endif
        return try JSONDecoder().decode(PartyDataBoardResponse.self, from: data)
    }

    func fetchMicTimeDetail(dateType: PartyDataDateType, statDate: String?) async throws -> [PartyMicTimeDetailItem] {
        var body: [String: Any] = ["dateType": dateType.rawValue]
        if let statDate, !statDate.isEmpty {
            body["statDate"] = statDate
        }
        let data = try await APIClient.shared.post(
            "/api/anchor/party/data/micTimeDetail",
            body: body
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("fetchMicTimeDetail dateType=\(dateType.rawValue) statDate=\(statDate ?? "-", privacy: .public) raw=\(raw, privacy: .private)")
        #endif
        // 后端返 `HttpResult<ArrayList<PartyMicTimeDetailEntity>>` → APIClient 已解 result，此处 data 直接是 [items] JSON
        return (try? JSONDecoder().decode([PartyMicTimeDetailItem].self, from: data)) ?? []
    }
}
