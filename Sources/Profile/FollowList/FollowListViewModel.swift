import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "FollowListVM")

/// FollowList 列表数据源（segment 切换 + 分页 + loading/error 状态）。
///
/// 每个 segment 独立分页状态（页码 / users / hasMore），切换 tab 不丢已加载内容。
@MainActor
final class FollowListViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle, loading, loaded, error(String)

        var isLoading: Bool { if case .loading = self { return true } else { return false } }
        var errorMessage: String? { if case .error(let m) = self { return m } else { return nil } }
    }

    /// 单 segment 的分页状态
    struct SegmentState {
        var users: [FollowUser] = []
        var currentPage: Int = 0
        var hasMore: Bool = true
        var loadState: LoadState = .idle
    }

    @Published var selectedSegment: FollowSegment
    @Published private(set) var states: [FollowSegment: SegmentState] = [:]
    /// 单次操作 toast 文案（关注失败回滚时用），UI 在 banner 区显示
    @Published var transientError: String?
    /// 正在切换关注态的 userId 集合（按钮 disabled + 防止并发同 user 操作）
    @Published private(set) var pendingFollowUserIds: Set<Int> = []

    private let pageSize: Int
    private var notificationObserver: NSObjectProtocol?

    init(initial: FollowSegment = .following, pageSize: Int = 20) {
        self.selectedSegment = initial
        self.pageSize = pageSize
        for s in FollowSegment.allCases {
            states[s] = SegmentState()
        }
        // 监听跨页关注变更：其他 VM 实例改了同 userId 的关注态，本实例同步更新
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .followRelationChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard
                let info = note.userInfo,
                let uid = info["userId"] as? Int,
                let flag = info["followFlag"] as? Int
            else { return }
            Task { @MainActor in
                self?.syncFollowFlagFromExternal(userId: uid, newFlag: flag)
            }
        }
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 便利访问当前 segment 状态（用于 View 直接读取）
    var currentState: SegmentState {
        states[selectedSegment] ?? SegmentState()
    }

    /// 加载首页（覆盖既有数据）。切 segment 第一次显示时调用。
    func loadFirstPage() async {
        await load(reset: true)
    }

    /// 加载下一页（追加）。滚到底部时调用。
    func loadNextPage() async {
        guard currentState.hasMore else { return }
        await load(reset: false)
    }

    /// 错误后重试当前页
    func retry() async {
        // 失败时不知道是首页还是下一页失败的，按"恢复到上次成功的下一页"处理：
        // 若 users 为空 → 拉首页；否则 → 拉下一页
        if currentState.users.isEmpty {
            await load(reset: true)
        } else {
            await load(reset: false)
        }
    }

    // MARK: - 关注 / 取关
    /// 切换关注态：1↔0。乐观更新 UI，失败回滚 + 广播 `followRelationChanged`。
    /// 同一 userId 操作期间禁止并发（按钮 disabled 由 pendingFollowUserIds 控制）。
    func toggleFollow(user: FollowUser, sourceSegment: FollowSegment) async {
        guard SelfPermissionBridge.shared.gate(
            .relationshipActions,
            action: "relationshipListToggleFollow"
        ) else { return }
        guard let uid = user.userId else { return }
        if pendingFollowUserIds.contains(uid) { return }

        // 按该条数据的实际关注态决定操作，不用所在 segment 覆盖。
        let wasFollowing = user.isFollowing
        let newFlag = wasFollowing ? 0 : 1
        let followType = wasFollowing ? 2 : 1   // 1=关注 2=取关

        // 乐观更新本 VM 状态
        pendingFollowUserIds.insert(uid)
        updateFollowFlag(userId: uid, to: newFlag)

        do {
            try await FollowListService.followUser(followUserId: uid, followType: followType)
            // 广播：其他 VM 实例（包括 ProfileViewModel）同步该 userId 的 followFlag
            NotificationCenter.default.post(
                name: .followRelationChanged,
                object: self,    // object=self 便于自身忽略自己发的通知
                userInfo: ["userId": uid, "followFlag": newFlag]
            )
            if wasFollowing, sourceSegment == .following {
                removeUser(userId: uid, from: .following)
            }
            logger.info("toggleFollow uid=\(uid) newFlag=\(newFlag) ok")
        } catch let e as APIError {
            // 失败回滚
            updateFollowFlag(userId: uid, to: wasFollowing ? 1 : 0)
            transientError = e.message
            logger.error("toggleFollow uid=\(uid) APIError code=\(e.code): \(e.message)")
        } catch {
            updateFollowFlag(userId: uid, to: wasFollowing ? 1 : 0)
            transientError = error.localizedDescription
            logger.error("toggleFollow uid=\(uid) error: \(String(describing: error))")
        }
        pendingFollowUserIds.remove(uid)
    }

    /// 跨页同步：其他 VM 发出 .followRelationChanged 时，更新本 VM 内同 userId 的 followFlag。
    /// 自己发的通知（object === self）忽略。
    private func syncFollowFlagFromExternal(userId: Int, newFlag: Int) {
        updateFollowFlag(userId: userId, to: newFlag)
    }

    /// 把本 VM 所有 segment 内匹配 userId 的 user 的 followFlag 替换为 newFlag。
    /// 不区分 segment：Following / Followers / Friends 都可能含同一个 userId。
    private func updateFollowFlag(userId: Int, to newFlag: Int) {
        for segment in FollowSegment.allCases {
            guard var state = states[segment] else { continue }
            var changed = false
            for i in state.users.indices where state.users[i].userId == userId {
                state.users[i] = state.users[i].withFollowFlag(newFlag)
                changed = true
            }
            if changed { states[segment] = state }
        }
    }

    private func removeUser(userId: Int, from segment: FollowSegment) {
        guard var state = states[segment] else { return }
        state.users.removeAll { $0.userId == userId }
        states[segment] = state
    }

    private func load(reset: Bool) async {
        let segment = selectedSegment
        var state = states[segment] ?? SegmentState()
        if state.loadState.isLoading { return }

        let nextPage = reset ? 1 : state.currentPage + 1
        state.loadState = .loading
        states[segment] = state

        do {
            let page = try await FollowListService.getUserFriend(
                type: segment.apiType,
                pageSize: pageSize,
                currentPage: nextPage
            )
            // 每个 segment 有独立状态；切页后仍写回原 segment 缓存，避免它永久停在 loading。
            // 保留服务端每条数据的显式 followFlag，让 Following / Followers / Friends
            // 都按实际关注态展示。Following 仅在字段缺失时按列表语义兜底为已关注。
            let users = segment == .following
                ? page.users.map { $0.followFlag == nil && $0.followed == nil ? $0.withFollowFlag(1) : $0 }
                : page.users
            if reset {
                state.users = users
            } else {
                state.users.append(contentsOf: users)
            }
            state.currentPage = nextPage
            state.hasMore = page.hasMore
            state.loadState = .loaded
            states[segment] = state
        } catch let e as APIError {
            state.loadState = .error(e.message)
            states[segment] = state
            logger.error("load segment=\(segment.rawValue) APIError code=\(e.code) message=\(e.message)")
        } catch {
            let msg = String(format: L10n.profileLoadFailedFormat, error.localizedDescription)
            state.loadState = .error(msg)
            states[segment] = state
            logger.error("load segment=\(segment.rawValue) error: \(String(describing: error))")
        }
    }
}
