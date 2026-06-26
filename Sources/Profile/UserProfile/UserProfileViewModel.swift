import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "UserProfileVM")

/// 用户详情页 ViewModel（spec §3 全部 7 条不变量）。
///
/// 三个独立状态机：
/// - LoadState（拉资料，单一态，§3.1）
/// - FollowState（**optimistic** toggle，§3.2，参 FollowListVM.toggleFollow）
/// - BlockState（**非 optimistic** confirm-then-API，§3.3，**与 follow 形态不同**，red team #8 落地）
@MainActor
final class UserProfileViewModel: ObservableObject {
    @Published private(set) var detail: UserDetail?
    @Published private(set) var loadState: UserProfileLoadState = .idle
    @Published var transientError: String?
    /// 进行中的关注/取关 userId 集合（按钮 disabled，防双击重复 - 不变量 #2）
    @Published private(set) var pendingFollowIds: Set<String> = []
    /// 进行中的拉黑 userId 集合（防双击 - 不变量 #3）
    @Published private(set) var pendingBlockIds: Set<String> = []
    /// 拉黑二次确认 popup 显示态（spec §3.3；scenePhase!=.active 自动关由 View 侧守 R-8）
    @Published var showingBlockConfirm: Bool = false

    private let service: UserProfileServiceProtocol
    let userId: String
    /// 代际 token：每次 loadDetail 递增；follow revert / load 回包前比对，过期则弃
    private var loadGeneration: Int = 0
    /// 主播自己直播态注入（spec §6 Q2：LiveStore.state == .living 派生）
    private let isLiveProvider: () -> Int
    private let networkErrorFallback: String
    private let badUserIdFallback: String

    init(userId: String,
         service: UserProfileServiceProtocol,
         isLiveProvider: @escaping () -> Int = { 0 },
         networkErrorFallback: String = "Network error, please try again.",
         badUserIdFallback: String = "Invalid user ID") {
        self.userId = userId
        self.service = service
        self.isLiveProvider = isLiveProvider
        self.networkErrorFallback = networkErrorFallback
        self.badUserIdFallback = badUserIdFallback
    }

    // MARK: - Load detail

    /// 拉资料（onAppear / retry 调用）。
    func loadDetail() async {
        // 不变量 #1：loading 中再触发 noop
        guard !loadState.isLoading else { return }
        guard let uidInt = Int(userId) else {
            loadState = .error(badUserIdFallback)
            logger.warning("loadDetail: bad userId=\(self.userId, privacy: .private)")
            return
        }
        loadGeneration += 1
        loadState = .loading
        let snapshot = loadGeneration

        do {
            let d = try await service.fetchDetail(userId: uidInt)
            // 代际过期 → 丢弃
            guard snapshot == loadGeneration else { return }
            detail = d
            loadState = .loaded
        } catch let e as APIError {
            guard snapshot == loadGeneration else { return }
            loadState = .error(e.message)
            logger.error("loadDetail uid=\(self.userId, privacy: .private) APIError code=\(e.code): \(e.message)")
        } catch {
            guard snapshot == loadGeneration else { return }
            loadState = .error(error.localizedDescription)
            logger.error("loadDetail uid=\(self.userId, privacy: .private) error: \(String(describing: error), privacy: .private)")
        }
    }

    func retry() async {
        await loadDetail()
    }

    // MARK: - Follow / Unfollow (optimistic)

    /// 切换关注态（optimistic）。
    /// 失败 revert + 代际守卫；成功 post `.followRelationChanged` 跨页同步（参 FollowListVM）。
    func toggleFollow() async {
        // 1. 守卫（外层不 mutation - 不变量 #4 持稳）
        guard let d = detail else { return }
        guard let uidInt = Int(userId) else {
            transientError = badUserIdFallback
            return
        }
        // 不变量 #2：同 userId 并发守
        guard !pendingFollowIds.contains(userId) else { return }

        let wasFollowed = d.followed
        let followType = wasFollowed ? 2 : 1   // 2=取关 / 1=关注
        let newFollowed = !wasFollowed

        // 2. pending 标记 + 记代际 token
        pendingFollowIds.insert(userId)
        defer { pendingFollowIds.remove(userId) }
        let myGen = loadGeneration

        // 3. optimistic toggle
        var updated = d
        updated.followed = newFollowed
        detail = updated

        do {
            try await service.follow(
                request: FollowUserRequest(followUserId: uidInt, followType: followType)
            )
            // 跨页同步（与 FollowListVM `.followRelationChanged` 契约对称）
            NotificationCenter.default.post(
                name: .followRelationChanged,
                object: self,
                userInfo: ["userId": uidInt, "followFlag": newFollowed ? 1 : 0]
            )
            logger.info("toggleFollow uid=\(self.userId, privacy: .private) newFollowed=\(newFollowed) ok")
        } catch {
            // 代际漂移 → 弃 revert（detail 已被外部 reload 重置）
            guard myGen == loadGeneration else {
                logger.warning("toggleFollow uid=\(self.userId, privacy: .private) failed but generation drifted, drop revert")
                return
            }
            // revert：detail 可能在 await 期间被其他动作改了，基于"当前 detail clone + 还原 followed"，
            // 不直接用初始 d（避免覆盖其他字段如 isBlocked）。
            guard var current = detail else { return }
            current.followed = wasFollowed
            detail = current

            if let e = error as? APIError {
                transientError = e.message
            } else {
                transientError = networkErrorFallback
            }
            logger.error("toggleFollow uid=\(self.userId, privacy: .private) error: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - Block (非 optimistic)

    /// 打开拉黑二次确认 popup。
    /// 守卫：detail 已加载 / userId 合法 / yxAccid 非 nil / 未拉黑 / 无 pending。
    /// 任一失败 noop（View 侧据 `canShowBlockMenuItem` 隐藏菜单项，本方法是兜底防 race）。
    func openBlockConfirm() {
        guard let d = detail else { return }
        guard Int(userId) != nil else { return }
        guard d.yxAccid != nil else { return }
        guard d.isBlocked != 1 else { return }
        guard !pendingBlockIds.contains(userId) else { return }
        showingBlockConfirm = true
    }

    func cancelBlockConfirm() {
        showingBlockConfirm = false
    }

    /// 确认拉黑（popup Confirm 调用）。
    /// 非 optimistic：API 成功才改 isBlocked + post 通知（不变量 #5）。
    func confirmBlock() async {
        // popup 关由 defer 保证（无论成功失败都关）
        guard let d = detail,
              let uidInt = Int(userId),
              let yx = d.yxAccid else {
            showingBlockConfirm = false
            return
        }
        guard !pendingBlockIds.contains(userId) else {
            showingBlockConfirm = false
            return
        }
        pendingBlockIds.insert(userId)
        defer {
            pendingBlockIds.remove(userId)
            showingBlockConfirm = false
        }

        let isLive = isLiveProvider()

        do {
            try await service.block(
                request: BlockUserRequest(userId: uidInt, type: 1, yxAccid: yx, isLive: isLive)
            )
            // 非 optimistic：API 成功才改本地 + post 通知
            var updated = d
            updated.isBlocked = 1
            detail = updated
            // 不变量 #6：post `.blocklistChanged`（trial #2 留的钩子本期真 post）
            NotificationCenter.default.post(name: .blocklistChanged, object: self)
            logger.info("confirmBlock uid=\(self.userId, privacy: .private) ok")
        } catch {
            if let e = error as? APIError {
                transientError = e.message
            } else {
                transientError = networkErrorFallback
            }
            logger.error("confirmBlock uid=\(self.userId, privacy: .private) error: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - Transient error 生命周期

    /// View 在 `.task(id: transientError)` 内 sleep 2s 后调本方法清掉 toast。
    func clearTransientError() {
        transientError = nil
    }

    // MARK: - View 派生（View 层 menu/button disabled 据此判断）

    /// 菜单是否显示 Block 项（spec §1.4：isBlocked != 1 才显示）。
    /// `isBlocked` 三态：nil / 0 / 1。前两态等价（R-22）。
    var canShowBlockMenuItem: Bool {
        guard let d = detail, d.yxAccid != nil, Int(userId) != nil else { return false }
        return d.isBlocked != 1
    }

    /// 关注按钮是否 disabled（spec R-9 + 并发守）。
    var isFollowButtonDisabled: Bool {
        Int(userId) == nil || pendingFollowIds.contains(userId)
    }
}
