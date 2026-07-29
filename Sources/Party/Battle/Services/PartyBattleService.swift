import Foundation

/// PartyBattle 服务层协议 —— 支撑 store 层 DI 测试注入
///
/// 对齐 spec 附录 C 10 个 REST 端点 + 全局开关拉取。
/// 生产实现 `PartyBattleService`，测试注入 `FakeBattleService`。
protocol PartyBattleServiceProtocol: AnyObject {
    func fetchTemplates() async throws -> [PartyBattleTemplate]
    func start(_ req: PartyBattleStartRequest) async throws -> PartyBattleStartResponse?
    func fetchState(_ roomId: String) async throws -> PartyBattleState?
    func switchTeam(_ req: PartyBattleSwitchTeamRequest) async throws
    func applyMic(_ req: PartyBattleApplyMicRequest) async throws -> PartyBattleApplyMicResponse?
    func startNow(_ pkId: String) async throws
    func forceEnd(_ pkId: String) async throws
    func fetchSettlement(_ pkId: String) async throws -> PartyBattleSettlementResponse
    func fetchApplications(_ roomId: String) async throws -> PartyBattleApplicationsResponse
    func approveApply(_ req: PartyBattleApproveApplyRequest) async throws
    func fetchGlobalConfig() async throws -> PartyBattleGlobalConfig?
}

/// PartyBattle 生产 service —— sapi 域 REST 端点封装
///
/// **HTTP method 说明**（api-http-method-strict rule）：
/// - spec 附录 C 声明 `templates` / `applications` 走 GET，其他走 POST
/// - iOS 本工程 `PartyAPIClient` 只支持 POST，F-1a 首版**统一走 POST**
/// - A5 待 F-1a milestone 真机 log 抓 templates/applications 是否兼容 POST；
///   若后端返 405 / 1111 "method not allowed"，再补 GET 支持基建（超 F-1a 范围）
///
/// **AES 加解密 + 401 auto-retry + BAGSHOP_TOKEN 24h** 均由 `PartyAPIClient` 内部处理。
@MainActor
final class PartyBattleService: PartyBattleServiceProtocol {
    static let shared = PartyBattleService()

    private let base = "/sapi/weidou/v1/client/party/battle"
    private let apiClient: PartyAPIClient

    init(apiClient: PartyAPIClient = .shared) {
        self.apiClient = apiClient
    }

    // MARK: - Templates（sapi 域强制 GET；POST 会返 HTTP 405）
    func fetchTemplates() async throws -> [PartyBattleTemplate] {
        let data = try await apiClient.get("\(base)/templates")
        return try Self.decodeArrayOrEmpty(data, key: "list")
    }

    // MARK: - Start / State
    func start(_ req: PartyBattleStartRequest) async throws -> PartyBattleStartResponse? {
        let data = try await apiClient.post("\(base)/start", body: Self.dict(from: req))
        return try? JSONDecoder().decode(PartyBattleStartResponse.self, from: data)
    }

    func fetchState(_ roomId: String) async throws -> PartyBattleState? {
        let data = try await apiClient.post(
            "\(base)/state", body: Self.dict(from: PartyBattleStateRequest(roomId: roomId)))
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return nil
        }
        return try JSONDecoder().decode(PartyBattleState.self, from: data)
    }

    // MARK: - Switch / ApplyMic / StartNow / ForceEnd
    func switchTeam(_ req: PartyBattleSwitchTeamRequest) async throws {
        _ = try await apiClient.post("\(base)/switchTeam", body: Self.dict(from: req))
    }

    func applyMic(_ req: PartyBattleApplyMicRequest) async throws -> PartyBattleApplyMicResponse? {
        let data = try await apiClient.post("\(base)/applyMic", body: Self.dict(from: req))
        return try? JSONDecoder().decode(PartyBattleApplyMicResponse.self, from: data)
    }

    func startNow(_ pkId: String) async throws {
        _ = try await apiClient.post(
            "\(base)/startNow", body: Self.dict(from: PartyBattleStartNowRequest(pkId: pkId)))
    }

    func forceEnd(_ pkId: String) async throws {
        _ = try await apiClient.post(
            "\(base)/forceEnd", body: Self.dict(from: PartyBattleForceEndRequest(pkId: pkId)))
    }

    // MARK: - Settlement / Applications / Approve
    func fetchSettlement(_ pkId: String) async throws -> PartyBattleSettlementResponse {
        let data = try await apiClient.post(
            "\(base)/settlement", body: Self.dict(from: PartyBattleSettlementRequest(pkId: pkId)))
        return try JSONDecoder().decode(PartyBattleSettlementResponse.self, from: data)
    }

    func fetchApplications(_ roomId: String) async throws -> PartyBattleApplicationsResponse {
        // sapi 域强制 GET（同 templates），roomId 走 URL query 参数
        let data = try await apiClient.get("\(base)/applications", query: ["roomId": roomId])
        return try JSONDecoder().decode(PartyBattleApplicationsResponse.self, from: data)
    }

    func approveApply(_ req: PartyBattleApproveApplyRequest) async throws {
        _ = try await apiClient.post("\(base)/approveApply", body: Self.dict(from: req))
    }

    // MARK: - Global config
    func fetchGlobalConfig() async throws -> PartyBattleGlobalConfig? {
        let dict = try await AppConfigService.fetch(keys: ["party_room_battle_config"])
        guard let rawStr = dict["party_room_battle_config"] as? String else { return nil }
        return PartyBattleGlobalConfigParser.parse(rawStr)
    }

    // MARK: - Helpers

    /// Encodable → [String: Any] dict（PartyAPIClient body 要求 dict 形态方便加密前 log 与 JSONSerialization）
    private static func dict<T: Encodable>(from value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// templates/applications 类"数组或 { list: [] }"包装的 decode 兜底
    private static func decodeArrayOrEmpty<T: Decodable>(_ data: Data, key: String) throws -> [T] {
        if let arr = try? JSONDecoder().decode([T].self, from: data) { return arr }
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let listAny = dict[key],
           let listData = try? JSONSerialization.data(withJSONObject: listAny),
           let arr = try? JSONDecoder().decode([T].self, from: listData) {
            return arr
        }
        return []
    }
}
