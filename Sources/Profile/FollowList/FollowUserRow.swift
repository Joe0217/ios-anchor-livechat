import SwiftUI

/// FollowList 行 cell：头像 + 昵称 + 副信息 + 关注/取关按钮。
///
/// `onToggleFollow` 由父 View 注入，触发 ViewModel.toggleFollow 完成乐观更新 + 失败回滚。
/// `isPending` 表示该 user 的关注操作进行中，按钮 disabled + 显示进度。
struct FollowUserRow: View {
    let user: FollowUser
    var isPending: Bool = false
    var onOpenProfile: (() -> Void)? = nil
    var onToggleFollow: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onOpenProfile?()
            } label: {
                HStack(spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.nickname ?? "—")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        metaLine
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpenProfile == nil)

            if onToggleFollow != nil {
                followButton
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        AvatarView(urlString: user.icon, size: 48, kind: .user,
                   userId: user.userId.map(String.init))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if let age = user.age, age > 0 {
                Text("\(age)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.65))
            }
            if let code = user.countryCode, !code.isEmpty {
                Text(ProfileViewModel.flagEmoji(from: code))
                    .font(.system(size: 11))
            }
            if let level = user.levelName, !level.isEmpty {
                Text(level)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.Palette.profileTier)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.Palette.profileTier.opacity(0.15), in: Capsule())
            }
        }
    }

    /// 关注按钮：followFlag=1 灰胶囊「Unfollow」/ 0 黄胶囊「Follow」；点击触发 onToggleFollow。
    /// 操作中（isPending）按钮 disabled + 替换为 ProgressView。
    private var followButton: some View {
        let isFollowing = user.isFollowing
        let title = isFollowing ? L10n.followActionUnfollow : L10n.followActionFollow

        return Button {
            onToggleFollow?()
        } label: {
            ZStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isFollowing ? Color.white.opacity(0.8) : Color.black)
                    .opacity(isPending ? 0 : 1)
                if isPending {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(isFollowing ? .white : .black)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isFollowing
                                ? Color.white.opacity(0.12)
                                : Theme.Palette.brandYellow)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .accessibilityLabel(title)
    }
}
