import Foundation

/// Props 数据层真实现（M1 Step 1c · spec §3.2）· 走 `PartyAPIClient` + `SapiTokenStore`。
///
/// **端点**（对齐 H5 `sapi/marketing/index.ts`）：
/// - `POST /sapi/marketing/v1/client/item/page` · body `{ type, pageIndex, pageSize, needTotalCount }`
/// - `POST /sapi/marketing/v1/client/item/ops`  · body `{ type: 0|1, id }`
///
/// **鉴权/加密**：PartyAPIClient 已内置 —— body base64(AES) / result hex→decode /
/// Keychain `sapi.auth_token.v1` 挂 header / 401 自动 ensureValid(forceRefresh:) + retry once /
/// 非 '200' 抛 `PartyAPIError.business` / 网络错抛 `.networkError`。
///
/// **错误映射到 `PropsServiceError`**（供 Store 状态迁移分档）：
/// - `.business(code, msg)`         → `.business(code, msg)`
/// - `.networkError`                → `.network(msg)`
/// - `.tokenExchangeFailed`         → `.tokenExchangeFailed`
/// - `.invalidURL / .encryptFailed / .envelopeParseFailed / .httpStatus` → `.decodeFailed(...)`
///
/// **suppressCodes 策略**（spec §3.2）：
/// - fetchPage 空 set → 让 GlobalErrorBannerNotify 兜底 top banner
/// - equipOps 用 `["*"]` 抑制所有业务码全局 banner，改本地 toast（toast-vs-banner-consistency rule）
final class LivePropsService: PropsService, @unchecked Sendable {

    static let shared = LivePropsService()

    private init() {}

    // MARK: - Endpoints（对齐 H5 sapi/marketing/index.ts）

    private static let pageEndpoint = "/sapi/marketing/v1/client/item/page"
    private static let opsEndpoint = "/sapi/marketing/v1/client/item/ops"

    // MARK: - PropsService

    func fetchPage(
        itemType: PropTabItemType?,
        pageIndex: Int,
        pageSize: Int
    ) async throws -> PropPage {
        // H5 请求前 ++ → 首次收到 pageIndex=1（spec §3.1）
        var body: [String: Any] = [
            "pageIndex": pageIndex,
            "pageSize": pageSize,
            "needTotalCount": true
        ]
        // itemType=nil 时（All Tab）H5 不带 type 字段
        if let t = itemType {
            body["type"] = t.rawValue
        }

        do {
            let data = try await PartyAPIClient.shared.post(
                Self.pageEndpoint,
                body: body,
                suppressCodes: []
            )
            do {
                return try JSONDecoder().decode(PropPage.self, from: data)
            } catch {
                AppLogger.party.error(
                    "[Props] decode PropPage failed: \(String(describing: error), privacy: .public) · raw=\(String(data: data, encoding: .utf8) ?? "<nil>", privacy: .public)"
                )
                throw PropsServiceError.decodeFailed(error.localizedDescription)
            }
        } catch let error as PartyAPIError {
            throw Self.map(error)
        }
    }

    func equipOps(itemId: Int64, action: PropEquipAction) async throws {
        let body: [String: Any] = [
            "type": action.rawValue,
            "id": itemId
        ]
        do {
            _ = try await PartyAPIClient.shared.post(
                Self.opsEndpoint,
                body: body,
                // 抑制业务码全局 banner · Store 层走本地 toast
                suppressCodes: ["*"]
            )
        } catch let error as PartyAPIError {
            throw Self.map(error)
        }
    }

    // MARK: - Error mapping（spec §3.2 表）

    private static func map(_ error: PartyAPIError) -> PropsServiceError {
        switch error {
        case .business(let code, let message):
            return .business(code: code, message: message)
        case .networkError:
            return .network("Network error, please retry")
        case .tokenExchangeFailed:
            return .tokenExchangeFailed
        case .invalidURL, .encryptFailed, .envelopeParseFailed:
            return .decodeFailed(error.errorDescription ?? "sapi decode failed")
        case .httpStatus(let code):
            return .network("HTTP \(code)")
        }
    }
}
