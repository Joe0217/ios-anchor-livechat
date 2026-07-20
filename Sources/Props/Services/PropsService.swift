import Foundation

/// Props 数据层协议（M1 Step 1a · spec §3.1 / §3.3 / §3.4）。
///
/// **接口对齐 H5**（`sapi/marketing/index.ts`）：
/// - `fetchPage(itemType:pageIndex:pageSize:)` → `POST /sapi/marketing/v1/client/item/page`
/// - `equipOps(itemId:action:)` → `POST /sapi/marketing/v1/client/item/ops`
///
/// **fetchPage 参数用 `PropTabItemType`（无 Entrance · Tab-safe 收窄 · spec D12）**，
/// response 侧 `PropItem.itemType` 仍用 `PropItemType`（保 5 case decode 兼容）。
///
/// **真实现走 `PartyAPIClient` + `SapiTokenStore`**（spec §3.2）；单测/Preview 走 `PropsServiceFake`。
protocol PropsService: Sendable {
    /// 分页拉取 · pageIndex 从 1 开始（对齐 H5 请求前 ++）
    func fetchPage(
        itemType: PropTabItemType?,
        pageIndex: Int,
        pageSize: Int
    ) async throws -> PropPage

    /// 佩戴/卸下 · 无响应体消费
    func equipOps(itemId: Int64, action: PropEquipAction) async throws
}

/// Props 数据层错误（映射自 PartyAPIError · spec §3.2 错误映射表）。
enum PropsServiceError: Error, Equatable, Sendable {
    /// 网络错误（Store → state.error（首拉全屏 or 分页 top banner）or ops rollback + toast）
    case network(String)
    /// 业务码非 '200'（Store → 同上）
    case business(code: String, message: String)
    /// Token 换取失败（Store → 触发 forceLogout）
    case tokenExchangeFailed
    /// decode 失败
    case decodeFailed(String)

    /// 用户可读文案（缺省 iOS 本地化占位）
    var displayMessage: String {
        switch self {
        case .network(let msg): return msg.isEmpty ? "Network error, please retry" : msg
        case .business(_, let msg): return msg
        case .tokenExchangeFailed: return "Session expired"
        case .decodeFailed(let s): return "Data error: \(s)"
        }
    }
}
