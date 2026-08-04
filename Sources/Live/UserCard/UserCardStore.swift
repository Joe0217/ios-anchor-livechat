import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "UserCardStore")

/// UserCard 状态机。
///
/// **职责分层**:
/// - fetch / follow / unfollow → 走 `UserCardServiceProtocol`(Real 内部委托 UserProfileService,自带 AppToast)
/// - block / unblock → 直接调 `UserProfileService.shared.block` / `BlocklistService.shared.removeBlock`
///   (需 yxAccid + isLive,不进 protocol 签名)
///
/// **isLive 派生**: 默认从 `LiveStore.shared.state == .living` 派生;Preview / 单测可注入 stub。
///
/// **并发保护**(review P0-3):
/// - `pendingFollow` guard 阻断快速连点 Follow 双写 race
/// - `pendingBlock` guard 阻断 block+unblock 并行(两 API 并行会让后端 state 与 UI 不一致)
@MainActor
final class UserCardStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading(UserCardPreview?)
        case loaded(UserCardInfo)
        case error(String)
    }

    @Published private(set) var state: LoadState = .idle
    /// 已拉黑 tap 触发的二次确认 dialog 显示态(View 挂 `.confirmationDialog`)
    @Published var showingUnblockConfirm: Bool = false

    /// Follow API in-flight,阻止连点 race(P0-3)
    @Published private(set) var pendingFollow: Bool = false
    /// Block/Unblock API in-flight,阻止 block+unblock 并行(P0-3)
    @Published private(set) var pendingBlock: Bool = false

    private let service: UserCardServiceProtocol
    private let userId: String
    private let preview: UserCardPreview?
    /// 主播自身是否正在直播中,派生 int 传给 blockUser API(H5 `appStore.isLiving ? 1 : 0`)
    private let isLiveProvider: @MainActor () -> Int

    init(userId: String,
         preview: UserCardPreview? = nil,
         service: UserCardServiceProtocol = UserCardServiceReal(),
         isLiveProvider: @MainActor @escaping () -> Int = {
             LiveStore.shared.state == .living ? 1 : 0
         }) {
        self.userId = userId
        self.preview = preview
        self.service = service
        self.isLiveProvider = isLiveProvider
    }

    // MARK: - Load

    /// 首次加载:idle → load
    func loadIfNeeded() {
        guard state == .idle else { return }
        Task { await load() }
    }

    /// 每次 sheet 打开都刷新,对齐 H5 `watch isShow immediate` 行为(P0-4)。
    /// 状态无条件转 loading + 发起新 fetch,与旧 in-flight Task 并存时"最后完成的赢"。
    func refresh() {
        Task { await load() }
    }

    func retry() { Task { await load() } }

    private func load() async {
        state = .loading(preview)
        do {
            let info = try await service.fetch(userId: userId)
            state = .loaded(info)
        } catch {
            logger.warning("fetch uid=\(self.userId, privacy: .private) failed: \(String(describing: error), privacy: .private)")
            state = .error(String(describing: error))
        }
    }

    // MARK: - Follow / Unfollow(optimistic + revert + pending guard)

    func toggleFollow() {
        guard SelfPermissionBridge.shared.gate(.profileSocial, action: "userCardToggleFollow") else {
            return
        }
        guard case .loaded(var info) = state else { return }
        guard !pendingFollow else {
            logger.info("toggleFollow uid=\(self.userId, privacy: .private) skip: pendingFollow=true")
            return
        }
        let wasFollowed = info.isFollowed
        // optimistic
        info.isFollowed = !wasFollowed
        info = withFollowerCount(info, delta: wasFollowed ? -1 : 1)
        state = .loaded(info)
        pendingFollow = true

        Task { [userId, service] in
            defer { self.pendingFollow = false }
            do {
                if wasFollowed {
                    try await service.unfollow(userId: userId)
                } else {
                    try await service.follow(userId: userId)
                }
                // 名片卡自己的 service 不广播关系变更；成功后按跨页同步契约主动广播。
                // 这会让当前 Party 房间在名片目标为房主时立即更新顶部关注按钮。
                if let followedUserId = Int(userId) {
                    NotificationCenter.default.post(
                        name: .followRelationChanged,
                        object: self,
                        userInfo: ["userId": followedUserId, "followFlag": wasFollowed ? 0 : 1]
                    )
                }
                logger.info("toggleFollow uid=\(userId, privacy: .private) wasFollowed=\(wasFollowed) ok")
            } catch {
                logger.warning("toggleFollow uid=\(userId, privacy: .private) failed: \(String(describing: error), privacy: .private)")
                // Task 继承外层 @MainActor 隔离(Swift 5.9+),revertFollow 是同 actor 同步调用无需 await
                self.revertFollow(wasFollowed: wasFollowed)
            }
        }
    }

    private func revertFollow(wasFollowed: Bool) {
        guard case .loaded(var info) = state else { return }
        info.isFollowed = wasFollowed
        info = withFollowerCount(info, delta: wasFollowed ? 1 : -1)  // 反向补回
        state = .loaded(info)
    }

    private func withFollowerCount(_ info: UserCardInfo, delta: Int) -> UserCardInfo {
        UserCardInfo(
            userId: info.userId, userType: info.userType,
            nickname: info.nickname, avatarUrl: info.avatarUrl,
            headwearUrl: info.headwearUrl, cardFrameUrl: info.cardFrameUrl,
            yxAccid: info.yxAccid,
            gender: info.gender, age: info.age, countryEmoji: info.countryEmoji,
            level: info.level, levelName: info.levelName, isVip: info.isVip,
            followerCount: max(0, info.followerCount + delta),
            followingCount: info.followingCount,
            liveWelcome: info.liveWelcome, medals: info.medals,
            giftWalls: info.giftWalls,
            isBlocked: info.isBlocked,
            isFollowed: info.isFollowed,
            isActiveTycoon: info.isActiveTycoon,
            roomRoleType: info.roomRoleType
        )
    }

    // MARK: - Block(未拉黑直接调;已拉黑走 unblock 二次确认)

    /// Block pill tap 入口(View 层)。未拉黑直接调 API + optimistic;已拉黑弹 confirm dialog。
    ///
    /// pendingBlock guard(P0-3):block+unblock 共享 flag,避免 optimistic 翻转期间连点导致
    /// block/unblock 并行(后端 state 与 UI 会漂移)。
    func handleBlockTap() {
        guard case .loaded(let info) = state else { return }
        guard !pendingBlock else {
            logger.info("handleBlockTap uid=\(self.userId, privacy: .private) skip: pendingBlock=true")
            return
        }
        if info.isBlocked {
            showingUnblockConfirm = true
        } else {
            performBlock(info: info)
        }
    }

    /// confirmDialog Confirm 调用(unblock)
    func confirmUnblock() {
        guard case .loaded(let info) = state else { return }
        guard !pendingBlock else {
            showingUnblockConfirm = false
            return
        }
        showingUnblockConfirm = false
        performUnblock(info: info)
    }

    func cancelUnblockConfirm() {
        showingUnblockConfirm = false
    }

    private func performBlock(info: UserCardInfo) {
        guard let uidInt = Int(info.userId),
              let yx = info.yxAccid, !yx.isEmpty else {
            logger.warning("block skip: invalid uid/yxAccid uid=\(info.userId, privacy: .private)")
            return
        }
        // optimistic
        setBlockState(true)
        pendingBlock = true
        let isLive = isLiveProvider()

        Task {
            defer { self.pendingBlock = false }
            do {
                try await UserProfileService.shared.block(
                    request: BlockUserRequest(userId: uidInt, type: 1, yxAccid: yx, isLive: isLive)
                )
                NotificationCenter.default.post(name: .blocklistChanged, object: nil)
                AppToastCenter.shared.show(L10n.userCardBlockSuccess)
                logger.info("block uid=\(info.userId, privacy: .private) isLive=\(isLive) ok")
            } catch {
                logger.warning("block uid=\(info.userId, privacy: .private) failed: \(String(describing: error), privacy: .private)")
                self.setBlockState(false)
                AppToastCenter.shared.show(L10n.userCardBlockFail)
            }
        }
    }

    private func performUnblock(info: UserCardInfo) {
        guard let uidInt = Int(info.userId),
              let yx = info.yxAccid, !yx.isEmpty else {
            logger.warning("unblock skip: invalid uid/yxAccid uid=\(info.userId, privacy: .private)")
            return
        }
        // optimistic
        setBlockState(false)
        pendingBlock = true

        Task {
            defer { self.pendingBlock = false }
            do {
                try await BlocklistService.shared.removeBlock(
                    request: BlockOptRequest(type: 1, userId: uidInt, yxAccid: yx)
                )
                NotificationCenter.default.post(name: .blocklistChanged, object: nil)
                AppToastCenter.shared.show(L10n.userCardUnblockSuccess)
                logger.info("unblock uid=\(info.userId, privacy: .private) ok")
            } catch {
                logger.warning("unblock uid=\(info.userId, privacy: .private) failed: \(String(describing: error), privacy: .private)")
                self.setBlockState(true)
                AppToastCenter.shared.show(L10n.userCardUnblockFail)
            }
        }
    }

    private func setBlockState(_ blocked: Bool) {
        guard case .loaded(var info) = state else { return }
        info.isBlocked = blocked
        state = .loaded(info)
    }
}
