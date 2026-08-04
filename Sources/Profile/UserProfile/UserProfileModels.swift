import Foundation
import SwiftUI

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
    /// H5 `getUserDetail.guardianList` 的主播前 3；空时资料页不展示守护卡。
    let guardianList: [UserGuardianAnchor]
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
    /// 从私聊页 push 出来的详情页，携带该私聊 peer 的 yxAccid。
    /// 详情页据此判断「发消息」按钮的目标是否就是"上一层"—— 是则 pop 而非 push，避免栈无限嵌套。
    case userIdFromChat(userId: String, peerYxAccId: String)
}

/// 从详情页 push 出来的私聊页专用 route（区别于其他入口的裸 `String` push）。
///
/// 携带来源详情页的 userId：私聊页据此判断 tap 对方头像的目标是否就是"上一层"—— 是则 pop 而非 push。
///
/// 其他入口（MessageList row / LiveResult Message 按钮 / openChatAction）仍走裸 String，行为不变。
struct ChatFromProfileRoute: Hashable {
    let peerYxAccId: String
    let sourceUserId: String
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

// MARK: - Destination Helper（详情 ↔ 私聊互跳）

// UI extension 依赖 UserProfileView / ChatDetailContainer / SessionStore（均不在 HilyTests 白名单）
// #if !HILY_TESTS 屏蔽 test target 编译（pre-existing 遗漏；本轮 H-5 顺手修阻塞点）
#if !HILY_TESTS
extension View {
    /// 集中注册详情页 (`UserProfileRoute`) + 从详情页 push 出来的私聊页 (`ChatFromProfileRoute`)
    /// 两个 destination 到当前 NavigationStack。
    ///
    /// **动机**：这两个 route 用于「详情 ↔ 私聊」pop-vs-push 循环去重，任何承载互跳的 stack
    /// 都必须完整挂两个 destination；分散到多处极易漏挂（历史事故：LiveResultView sheet 内嵌 stack
    /// 漏挂导致 SwiftUI 抛「no matching navigationDestination」）。集中一处后，未来加 route case
    /// 只改本 helper —— 编译器强制所有调用方同步生效。
    ///
    /// **不包含**：裸 `String`（peerYxAccId → 聊天页）destination —— 各 stack 语义差异较大
    /// （Messages tab 有 sentinel `__station_list__` 分支），单独维护。
    ///
    /// - Parameter hidesSystemNavigationBar: **仅作用于 ChatFromProfileRoute** 挂出来的聊天页 ——
    ///   ChatDetailContainer 用自定义 nav bar，sheet 内嵌 stack 会额外挂 system bar 造成叠加，
    ///   sheet 场景传 `true` 隐藏之。**UserProfileRoute 不受此参数影响**：UserProfileView 用
    ///   `.toolbar { toolbarContent }` 把 back/FOLLOW/menu 挂到 system nav bar，必须保持可见；
    ///   若在这里挂 `.toolbar(.hidden)` 会让详情页失去 back 按钮，用户被困（历史事故 P0-1）。
    @ViewBuilder
    func userProfileAndChatDestinations(hidesSystemNavigationBar: Bool = false) -> some View {
        self
            .navigationDestination(for: UserProfileRoute.self) { route in
                // 不套 .toolbar(.hidden) —— UserProfileView 依赖 system nav bar 承载 back/FOLLOW/menu
                if SelfPermissionBridge.shared.canProfileViewingSnapshot {
                    switch route {
                    case .userId(let uid):
                        if !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            UserProfileView(userId: uid)
                        } else {
                            EmptyView()
                        }
                    case .userIdFromChat(let uid, let peer):
                        if !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            UserProfileView(userId: uid, originPeerYxAccId: peer)
                        } else {
                            EmptyView()
                        }
                    }
                } else {
                    EmptyView()
                }
            }
            .navigationDestination(for: ChatFromProfileRoute.self) { route in
                if SelfPermissionBridge.shared.canDirectMessagesSnapshot {
                    let selfYxAccId = SessionStore.shared.user?.yxAccid ?? ""
                    ChatDetailContainer(
                        peerYxAccId: route.peerYxAccId,
                        selfYxAccId: selfYxAccId,
                        originProfileUserId: route.sourceUserId
                    )
                    .toolbar(hidesSystemNavigationBar ? .hidden : .automatic, for: .navigationBar)
                } else {
                    EmptyView()
                }
            }
    }
}
#endif
