import Foundation

// MARK: - 业务模型

/// 他人主页资料（spec §2.2 + §1.2）。
///
/// **严格 String userId**（与 BlocklistItem 对齐 — 接口偷换为 Int 时 decode 抛 typeMismatch，fail-loud 暴露契约偏移）。
///
/// `followed: Bool` 严格按 H5 `type.ts: UserInfoData.followed: boolean` 契约；
/// **注意**：H5 模板 `userInfo.followFlag === 1` 是 H5 自身把 followType 错置进 followFlag 字段的 bug
/// (red team #1/#3 落地)，iOS 不参 H5 bug 行为。
struct UserDetail: Equatable {
    let userId: String
    let nickname: String
    let icon: String?
    let gender: Int?           // 1=男 / 2=女 / 其他 nil
    let age: Int?
    let countryId: String?     // H5 type.ts 只有 countryId，无 country（red team #2 落地）
    let connRate: String?      // H5 字段宽松收 String
    let yxAccid: String?       // 拉黑必需；nil 时拉黑按钮 disabled (R-12)
    var followed: Bool         // var：optimistic toggle + revert
    var isBlocked: Int?        // var：blockUser 成功后改 1
    let like: Int              // 解析 thumbs[0].num；缺失/非数组 → 0 (R-4)
    let favorite: Int          // 解析 thumbs[1].num
    let giftList: [Gift]       // 礼物墙（trial #3 step 3 反悔 #7 补，H5 type.ts 不完整）
}

/// 礼物墙单项（H5 `views/mine/components/gifts.vue` 用法对照）。
///
/// H5 type.ts:GiftListData 仅声明 `{giftId, num}`，但模板用 `giftImg || icon` / `giftName` / `giftCount || num`
/// —— 与 userId 类型同款"type.ts 不是真契约"的例子。本期兼容两套字段名。
struct Gift: Equatable, Hashable, Identifiable {
    let giftId: Int
    let iconUrl: String?       // 接口字段 giftImg 优先，fallback icon
    let name: String?          // 接口字段 giftName
    let count: Int             // 接口字段 giftCount 优先，fallback num

    var id: Int { giftId }
}

/// 关注/取关请求体（spec §2.1，trial #3 step 3 真机反悔 #2 修订）。
///
/// **字段名 `followUserId` + `followType`**（H5 真实契约 `api/user/type.ts:58-60 FollowUserOpt`）。
/// 不是 `userId` 也不是 `type` —— 接口报 "followTypemust not be null" 暴露真名。
struct FollowUserRequest: Encodable, Equatable {
    let followUserId: Int
    let followType: Int        // 1=关注 / 2=取关
}

/// 拉黑请求体（spec §1.5 / §2.1）。
///
/// **与 trial #2 `BlockOptRequest`（移除拉黑）独立**（red team #9 落地）：
/// blockUser 多 `isLive` 字段，两端点共享 type=1 但 body 形态不同。
struct BlockUserRequest: Encodable, Equatable {
    let userId: Int
    let type: Int              // 固定 1（spec §1.4）
    let yxAccid: String
    let isLive: Int            // 0|1，主播自己是否正在直播（来源 LiveStore.state == .living）
}

// MARK: - 路由（多入口共享）

/// 用户详情页跨入口共享路由值（spec §5.3）。
///
/// 任何 tab 需要推入详情页，都用 `NavigationLink(value: UserProfileRoute.userId(...))`，
/// 由各 tab 在 MainTabView 内 NavigationStack 根节点 `navigationDestination(for: UserProfileRoute.self)` 接管。
///
/// 本期 H-0 接 .home tab；未来 .profile / .messages 等扩展见 spec §5.3 样板。
enum UserProfileRoute: Hashable {
    case userId(String)
}

// MARK: - 状态机

/// 资料加载态（spec §3.1）。
enum UserProfileLoadState: Equatable {
    case idle
    case loading
    case loaded
    case error(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let m) = self { return m }
        return nil
    }
}

// MARK: - 数据层 protocol

/// 用户详情数据层（spec §2.1）。
///
/// instance protocol：VM 注入 protocol 让单测可换 Fake，真集成注入 `UserProfileService.shared`。
protocol UserProfileServiceProtocol {
    /// 拉取用户详情。响应 envelope `result` 是单对象（非数组）。
    func fetchDetail(userId: Int) async throws -> UserDetail

    /// 关注/取关。`type` 1=关注 / 2=取关。响应 result=null，code=0000 成功。
    func follow(request: FollowUserRequest) async throws

    /// 拉黑。响应同 follow。
    func block(request: BlockUserRequest) async throws
}

// MARK: - NotificationCenter 钩子

/// `.followRelationChanged` 已由 FollowListModels.swift 定义，本模块复用。
/// `.blocklistChanged` 已由 BlocklistModels.swift 定义，本模块在 blockUser 成功后 post（spec §3.3）。
///
/// **注意**：跨 VM userInfo 字段约定
/// - `.followRelationChanged`: `["userId": Int, "followFlag": Int(0|1)]`（FollowListVM 既有契约）
/// - `.blocklistChanged`: 无 userInfo（trial #2 既有，观察方自行 reload）
