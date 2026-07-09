import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "UserCardStore")

/// UserCard 状态机
@MainActor
final class UserCardStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(UserCardInfo)
        case error(String)
    }

    @Published private(set) var state: LoadState = .idle

    private let service: UserCardServiceProtocol
    private let userId: String

    init(service: UserCardServiceProtocol = UserCardServiceFakes(),
         userId: String) {
        self.service = service
        self.userId = userId
    }

    func loadIfNeeded() {
        guard state == .idle else { return }
        Task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            let info = try await service.fetch(userId: userId)
            state = .loaded(info)
        } catch {
            logger.warning("UserCard fetch failed: \(String(describing: error), privacy: .private)")
            state = .error(String(describing: error))
        }
    }

    /// 关注 / 取关（乐观更新）
    func toggleFollow() {
        guard case .loaded(var info) = state else { return }
        let wasFollowed = info.isFollowed
        info = UserCardInfo(userId: info.userId, nickname: info.nickname, avatarUrl: info.avatarUrl,
                             gender: info.gender, age: info.age, countryEmoji: info.countryEmoji,
                             level: info.level, levelName: info.levelName, isVip: info.isVip,
                             followerCount: info.followerCount + (wasFollowed ? -1 : 1),
                             followingCount: info.followingCount,
                             giftWalls: info.giftWalls,
                             isBlocked: info.isBlocked,
                             isFollowed: !wasFollowed)
        state = .loaded(info)
        Task {
            do {
                if wasFollowed {
                    try await service.unfollow(userId: userId)
                } else {
                    try await service.follow(userId: userId)
                }
            } catch {
                logger.warning("toggleFollow failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// 拉黑 / 取消拉黑（乐观更新）
    func toggleBlock() {
        guard case .loaded(var info) = state else { return }
        let wasBlocked = info.isBlocked
        info = UserCardInfo(userId: info.userId, nickname: info.nickname, avatarUrl: info.avatarUrl,
                             gender: info.gender, age: info.age, countryEmoji: info.countryEmoji,
                             level: info.level, levelName: info.levelName, isVip: info.isVip,
                             followerCount: info.followerCount, followingCount: info.followingCount,
                             giftWalls: info.giftWalls,
                             isBlocked: !wasBlocked,
                             isFollowed: info.isFollowed)
        state = .loaded(info)
        Task {
            do {
                if wasBlocked {
                    try await service.unblock(userId: userId)
                } else {
                    try await service.block(userId: userId)
                }
            } catch {
                logger.warning("toggleBlock failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    func retry() { Task { await load() } }
}
