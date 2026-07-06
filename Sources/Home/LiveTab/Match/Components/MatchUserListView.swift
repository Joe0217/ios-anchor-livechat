import SwiftUI

/// L 里程碑 Match tab：底部匹配用户列表（居中头像 row，点击弹出用户卡片 sheet）。
///
/// 对齐 H5 `home/match.vue` 底部 `matchUserList`：一排小头像，居中展示，点击弹用户卡片。
/// 头像使用工程公共 `AvatarView`（默认图 + 缓存 + 头像框）。
struct MatchUserListView: View {
    let users: [MatchUserItem]
    let onTapUser: (MatchUserItem) -> Void

    /// 屏幕可容纳头像上限（估算：屏宽 375 / (32+8) ≈ 9，保守 8）
    private let maxVisible: Int = 8

    var body: some View {
        Group {
            if users.isEmpty {
                emptyState
            } else {
                HStack(spacing: Theme.Metric.matchRecentAvatarGap) {
                    ForEach(visibleUsers) { user in
                        Button {
                            onTapUser(user)
                        } label: {
                            AvatarView(
                                urlString: user.icon,
                                size: Theme.Metric.matchRecentAvatarSize,
                                kind: .user
                            )
                            .overlay(
                                Circle()
                                    .stroke(Theme.Palette.matchMarqueeBorderStart, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        .accessibilityLabel(user.nickname)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, Theme.Metric.screenMargin)
            }
        }
    }

    private var visibleUsers: [MatchUserItem] {
        Array(users.prefix(maxVisible))
    }

    private var emptyState: some View {
        Text(L10n.matchUserListEmpty)
            .font(.system(size: 13))
            .foregroundColor(Theme.Palette.matchSubtitle)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

#Preview {
    VStack(spacing: 20) {
        // 6 头像居中
        MatchUserListView(
            users: (1...6).map { i in
                MatchUserItem.previewFixture(userId: "\(i)", nickname: "User \(i)")
            },
            onTapUser: { _ in }
        )
        // 3 头像居中
        MatchUserListView(
            users: (1...3).map { i in
                MatchUserItem.previewFixture(userId: "\(i)", nickname: "User \(i)")
            },
            onTapUser: { _ in }
        )
    }
    .background(Theme.Palette.screenBackground)
    .preferredColorScheme(.dark)
}
