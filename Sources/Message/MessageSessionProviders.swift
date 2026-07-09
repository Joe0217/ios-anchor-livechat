import Combine
import Foundation

/// H-1 MVP 数据层依赖倒置协议（Step 1a 定契约；Step 1c 落 NIMSessionAdapter + PrimeLevelService）。
///
/// **拆分理由**：
/// - Store 通过 protocol 注入，可用 Fakes 走通所有反向路径（spec §3.3 R-1~R-4）
/// - protocol 层无 NIMSDK / HTTP 依赖，可入 HilyTests 单测 Store 行为
/// - 真实 SDK / 网络实现在 Step 1c 单独文件（Adapter 模式）

// MARK: - 会话列表 / 置顶 / 删除

@MainActor
protocol MessageSessionProviderProtocol: AnyObject {
    /// 拉取全部会话（首次 + 重试均调）。
    /// 内部策略（Step 1c 落）：evaluate `asyncLoadRecentSessionEnabled` 或 hop background queue 避免卡主线程
    func fetchAll() async throws -> [MessageSession]

    /// 置顶 / 取消置顶（SDK 官方 `addStickTopSession` / `removeStickTopSession` 跨端漫游）
    func setStickTop(sessionId: String, isTop: Bool) async throws

    /// 删除会话（SDK `deleteRecentSession` + 本地列表移除）
    func delete(sessionId: String) async throws

    /// 订阅 delegate 增量事件（`didAddRecentSession` / `didUpdateRecentSession` / `didRemoveRecentSession`）
    /// 回调**保证在 @MainActor**（Adapter 内部 hop）
    func subscribe(_ handler: @MainActor @escaping (MessageSessionEvent) -> Void)

    func unsubscribe()

    /// IM 长连接是否 connected。Store 用来延迟 fetch 到 IM 登录后触发（Step 3 反悔 #1）。
    /// 真轨（`NIMSessionAdapter`）映射 `NIMService.$connectionState == .connected`；
    /// Fakes 用 `CurrentValueSubject<Bool, Never>(true)` 或 test-controlled 覆盖。
    var isConnectedPublisher: AnyPublisher<Bool, Never> { get }
}

// MARK: - Prime 拉取

@MainActor
protocol PrimeLevelProviderProtocol: AnyObject {
    /// 批量查 Prime uid（`apiBatchQueryYxPrimeFilter` body `{yxAccId: [String]}`）。
    ///
    /// **分批合约**（spec §3.2 R-2）：
    /// - 输入 yxAccIds 超过 50 时内部分批
    /// - 任一批失败仅该批不进结果集，其他批照常返回
    /// - 全部批失败 → 返回空 Set（对齐 H5 增量拉取失败保留旧值语义）
    func fetchPrime(yxAccIds: [String]) async -> Set<String>
}

// MARK: - 关注列表拉取（Flame 通道 B，对齐 H5 `use/useFollowUserList.js`）

@MainActor
protocol FollowUserListProviderProtocol: AnyObject {
    /// 拉取主播关注的用户 yxAccid 集合（`POST /api/user/userFriend` body `{type: 3}`）。
    ///
    /// **缓存合约**（对齐 H5 `FOLLOW_LIST_CACHE_TIME` = 24h）：
    /// - 24h 内命中缓存直接返回
    /// - 首次请求 or 缓存过期时打网 `getFriends({type:3})`
    /// - 请求失败保留旧缓存（H5 `useFollowUserList.js:53-57` 同款降级）
    func fetch() async -> Set<String>

    /// 登出/切账号时清缓存（`SessionStore.logout` 调）
    func clear()
}
