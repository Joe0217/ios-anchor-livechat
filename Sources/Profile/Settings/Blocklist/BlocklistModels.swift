import Foundation

// MARK: - 业务模型

/// 黑名单条目（spec §4.2）。
///
/// **严格 String userId**（与 H5 `type.ts: BlackListData.userId: string` 对齐）；接口偷换为 Int
/// 时 decode 抛 `typeMismatch` 触发 fail-loud，暴露契约偏移（spec §1.3 表 #2 / R-9）。
///
/// `createTimeMs` 用 `Int64` 而非 `TimeInterval`，规避 Double 精度风险并显式标位毫秒
/// （review #18 落地）；接口字段名 `createTime` 用 CodingKey 别名。
struct BlocklistItem: Identifiable, Codable, Equatable {
    let userId: String
    let nickname: String
    let icon: String?
    let countryId: String?
    let age: Int?
    let yxAccid: String
    let gender: Int?
    let userType: Int?
    let createTimeMs: Int64?

    enum CodingKeys: String, CodingKey {
        case userId, nickname, icon, countryId, age, yxAccid, gender, userType
        case createTimeMs = "createTime"
    }

    var id: String { userId }
    /// `nil` 表示接口无 createTime 或为 0（spec R-13），UI 不显示日期
    var createdAt: Date? {
        guard let ms = createTimeMs, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}

/// 移除黑名单请求体（spec §4.3）。
///
/// `type` H5 硬编 1，语义待 step 0 后端/抓包确认（spec §10 Q8 升级，§7.2 风险项）。
struct BlockOptRequest: Encodable {
    let type: Int
    let userId: Int
    let yxAccid: String
}

// MARK: - 状态机

/// 列表加载态（spec §3.1 + §3.3 不变量 #1）。
///
/// 拆分 `loadingFirstPage` vs `loadingMore` 是 review #15 落地：UI 区分首次占满屏 spinner
/// vs footer 行内 spinner，避免下拉刷新时 footer 误转动。
enum BlocklistLoadState: Equatable {
    case idle
    case loadingFirstPage
    case loadingMore
    case loaded
    case error(String)

    var isLoading: Bool {
        switch self {
        case .loadingFirstPage, .loadingMore: return true
        default: return false
        }
    }
    var errorMessage: String? {
        if case .error(let m) = self { return m }
        return nil
    }
}

// MARK: - 数据层 protocol

/// 黑名单数据层（spec §4.1）。
///
/// instance protocol 而非 static：ViewModel 注入 protocol 让单测可换 Fake，
/// 真集成 step 1c 注入默认 `BlocklistService.shared`。
protocol BlocklistServiceProtocol {
    /// 拉取主播主动黑名单列表（V1 接口；V2 是被动黑名单不在本里程碑）。
    func fetchActive(page: Int, size: Int) async throws -> [BlocklistItem]
    /// 移除黑名单。请求体内 `type` 步 0 默认 1，待后端确认。
    func removeBlock(request: BlockOptRequest) async throws
}

// MARK: - NotificationCenter 钩子（spec §6.A，本期空实现）

extension Notification.Name {
    /// 黑名单变更通知（拉黑入口在 G/H 里程碑落地后会 fire 此通知）。
    /// 本期 ViewModel 留 observer 钩子但不消费；保持与 FollowList 的 `.followRelationChanged`
    /// 对称（review #10 落地）。
    static let blocklistChanged = Notification.Name("blocklistChanged")
}
