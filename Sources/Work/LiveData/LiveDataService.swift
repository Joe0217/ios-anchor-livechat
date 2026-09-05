import Foundation
import os

private let logger = Logger(subsystem: "com.hilly.anchor", category: "LiveDataService")

/// Live Data 页数据层协议 — impl 生产走 [LiveDataService.shared]，单测/Preview 用 mock。
protocol LiveDataServiceProtocol {
    /// H5 `POST /api/anchor/live/authorLiveData` — 主数据（对齐 H5 `api/liveData/index.ts:7`）
    func fetchLiveData(dateType: LiveDataDateType) async throws -> LiveDataResponse

    /// H5 `POST /api/task/v2/get` — 浮标 sureGetAward（H5 `api/task/index.ts:6`）
    func fetchMoneyBag() async throws -> MoneyBagResponse
}

final class LiveDataService: LiveDataServiceProtocol {
    static let shared = LiveDataService()

    private init() {}

    func fetchLiveData(dateType: LiveDataDateType) async throws -> LiveDataResponse {
        // H5 实际调用点传入 queryType 数字；保持 JSON 参数类型一致。
        let data = try await APIClient.shared.post(
            "/api/anchor/live/authorLiveData",
            body: ["dateType": dateType.rawValue]
        )
        // 收益/时长属主播资金流水敏感数据 —— 对齐 APIClient 三层保护：#if DEBUG + .debug 级 + .private
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("fetchLiveData dateType=\(dateType.rawValue, privacy: .public) raw=\(raw, privacy: .private)")
        print("[LiveData] authorLiveData dateType=\(dateType.rawValue) response=\(raw)")
        #endif
        return try JSONDecoder().decode(LiveDataResponse.self, from: data)
    }

    func fetchMoneyBag() async throws -> MoneyBagResponse {
        let data = try await APIClient.shared.post("/api/task/v2/get", body: [:])
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("fetchMoneyBag raw=\(raw, privacy: .private)")
        #endif
        return try JSONDecoder().decode(MoneyBagResponse.self, from: data)
    }
}
