import Foundation

/// 派对房房币服务。
///
/// - `exchangeDiamond` 的 `{ gemNum }` 请求契约来自 H5 `src/api/gems/index.ts`。
/// - `exchangeCoin` 为安卓主播端同组接口，沿用相同的宝石数量参数；金币兑换比例由服务端结算。
struct DefaultPartyCurrencyService: PartyCurrencyService {
    private let pathPrefix = "/sapi/weidou/v1/client"

    func fetchBalance() async throws -> PartyCurrencyBalance {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/gem/getBalance",
            body: [:]
        )
        return try PartyCurrencyBalance.decode(from: data)
    }

    func exchange(gems: Int64, target: PartyCurrencyTarget) async throws {
        let endpoint: String
        switch target {
        case .diamond:
            endpoint = "gem/exchangeDiamond"
        case .coin:
            endpoint = "gem/exchangeCoin"
        }

        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/\(endpoint)",
            body: ["gemNum": gems]
        )
    }
}
