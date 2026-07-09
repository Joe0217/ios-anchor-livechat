import Foundation

/// Roulette 数据源 protocol（H 里程碑接入真 API）
///
/// **真 API 契约**（对齐 H5 liveRoulettePopup 4 endpoints）：
/// - queryConfig: POST `/api/wheel/queryWheelConfigByAnchorId`  body: `{ searchValue: userId }`
/// - saveConfig:  POST `/api/wheel/addWheelConfig`  body: `{ addWheelSector, enabled, liveRoomId, price }`
/// - changeStatus: POST `/api/wheel/changeWheelStatus`  body: `{ enabled, ... }`
/// - presetTexts: POST `/api/wheel/queryPresetText`  body: `{ ... }`（按国家取预设文案）
/// - 加密: AES-128-CBC + Hex（走 APIClient 主链路自动处理）
protocol RouletteServiceProtocol {
    func queryConfig(anchorUserId: String) async throws -> RouletteConfig
    func saveConfig(_ config: RouletteConfig, liveRoomId: String) async throws
    func changeStatus(enabled: Bool, liveRoomId: String) async throws
    func presetTexts() async throws -> RoulettePresetTexts
}

/// Fakes 实现（Level B 视觉走通）
struct RouletteServiceFakes: RouletteServiceProtocol {
    func queryConfig(anchorUserId: String) async throws -> RouletteConfig {
        try await Task.sleep(nanoseconds: 200_000_000)
        // 模拟从未配置过的默认态
        return RouletteConfig(
            enabled: false,
            price: 100,
            sectors: ["Kiss", "Wink", "Dance", "Sing"]
        )
    }

    func saveConfig(_ config: RouletteConfig, liveRoomId: String) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        // no-op（Fakes 不持久化）
    }

    func changeStatus(enabled: Bool, liveRoomId: String) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func presetTexts() async throws -> RoulettePresetTexts {
        try await Task.sleep(nanoseconds: 150_000_000)
        return RoulettePresetTexts(texts: [
            "Kiss", "Wink", "Dance", "Sing",
            "Blow Kiss", "Wave", "Smile", "Say Hi"
        ])
    }
}

/// 真 API 实现（H 里程碑接入）
///
/// TODO H 里程碑：
/// ```
/// // queryConfig
/// let body: [String: Any] = ["searchValue": anchorUserId]
/// let resp: RouletteConfigResponse = try await APIClient.shared.post(
///     "/api/wheel/queryWheelConfigByAnchorId", body: body)
/// // saveConfig / changeStatus / presetTexts 同理
/// ```
struct RouletteServiceReal: RouletteServiceProtocol {
    func queryConfig(anchorUserId: String) async throws -> RouletteConfig {
        // TODO H 里程碑
        return try await RouletteServiceFakes().queryConfig(anchorUserId: anchorUserId)
    }

    func saveConfig(_ config: RouletteConfig, liveRoomId: String) async throws {
        // TODO H 里程碑
        try await RouletteServiceFakes().saveConfig(config, liveRoomId: liveRoomId)
    }

    func changeStatus(enabled: Bool, liveRoomId: String) async throws {
        // TODO H 里程碑
        try await RouletteServiceFakes().changeStatus(enabled: enabled, liveRoomId: liveRoomId)
    }

    func presetTexts() async throws -> RoulettePresetTexts {
        // TODO H 里程碑
        return try await RouletteServiceFakes().presetTexts()
    }
}
