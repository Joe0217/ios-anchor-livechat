import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveDataService")

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
        // 保守传 String —— H5 `api/liveData/index.ts` interface 声明 `dateType: string`
        // （agent-recon-field-names-unverified rule:H5 TS 声明与实际调用点 queryType 数字不一致，
        //  后端严格性未知，String 兼容面更广，首次真机再核对）
        let data = try await APIClient.shared.post(
            "/api/anchor/live/authorLiveData",
            body: ["dateType": String(dateType.rawValue)]
        )
        // 收益/时长属主播资金流水敏感数据 —— 对齐 APIClient 三层保护：#if DEBUG + .debug 级 + .private
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("fetchLiveData dateType=\(dateType.rawValue, privacy: .public) raw=\(raw, privacy: .private)")
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
