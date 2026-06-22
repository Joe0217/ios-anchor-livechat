import SwiftUI

/// Profile 顶部紫色渐变区的 content：设置按钮 + 头像 + 名字 + ID + 性别 / 国旗 + SS 段位 + 关注/粉丝/朋友 stats。
///
/// 背景图由 ProfileView 的 `.background { }` 层独立负责（对齐 LiveTabView 模式），
/// 本视图只画 content；ScrollView content 顶在 safe area 下方，状态栏区已由背景图覆盖。
struct ProfileHeaderView: View {
    @ObservedObject var vm: ProfileViewModel

    var body: some View {
        content
            .frame(maxWidth: .infinity)
    }

    private var content: some View {
        // 各行间距全用固定 padding，不再用 Spacer 撑开 + frame(height:) 兜底；
        // 改间距时下面所有内容跟随上移，避免「上面缩小、中间变大」的撑开陷阱。
        VStack(spacing: 0) {
            topActionRow
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            identityRow
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

            statsRow
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
    }

    // 顶部仅放设置入口，名字行的编辑铅笔在 identityRow 内
    private var topActionRow: some View {
        HStack(spacing: 0) {
            Spacer()
            Button(action: { /* 进入设置：占位 */ }) {
                Image("profileSettingsIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.profileSettings)
        }
        .frame(height: 32)
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: 14) {
            avatar
            nameAndMeta
            Spacer(minLength: 0)
            tierBlock
        }
    }

    private var avatar: some View {
        // 外环 72，内图 64：外圈描边在 72pt 圆上，内图 64pt 圆居中显示，单边间距 4pt
        ZStack {
            // 内图：占位头像，接入头像 URL 后用 AsyncImage 替换
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFill()
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: Theme.Metric.profileAvatarInner, height: Theme.Metric.profileAvatarInner)
                .clipShape(Circle())
        }
        .frame(width: Theme.Metric.profileAvatarSize, height: Theme.Metric.profileAvatarSize)
        .overlay(
            Circle()
                .strokeBorder(Theme.Gradients.avatarRing, lineWidth: Theme.Metric.profileAvatarRing)
        )
        .accessibilityHidden(true)
    }

    private var nameAndMeta: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(vm.displayName)
                    .font(Theme.Typography.profileName)
                    .foregroundColor(Theme.Palette.profileName)
                Button(action: { /* 编辑昵称：占位 */ }) {
                    Image("profileEditIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.profileEditName)
            }

            Text(L10n.profileIdPrefix + vm.userId)
                .font(Theme.Typography.profileId)
                .foregroundColor(Theme.Palette.profileIdText)

            HStack(spacing: 6) {
                Image("profileGenderIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(vm.ageText)
                    .font(Theme.Typography.profileMeta)
                    .foregroundColor(Theme.Palette.profileMetaText)

                // 用 1pt 矩形作为视觉分隔条，避免 "|" 字符在 RTL/不同字体下错位
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 1, height: 10)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)

                Image("profileLocationIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(vm.countryFlag)
                    .font(Theme.Typography.profileMeta)
            }
        }
    }

    private var tierBlock: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 4) {
                Text(vm.tierLabel)
                    .font(Theme.Typography.profileTier)
                    .foregroundColor(Theme.Palette.profileTier)
                Image("profileChevronRight")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(vm.rateText)
                .font(Theme.Typography.profileRate)
                .foregroundColor(Theme.Palette.profileRate)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(value: vm.followingCount, caption: L10n.profileFollowing)
            statDivider
            statItem(value: vm.followersCount, caption: L10n.profileFollowers)
            statDivider
            statItem(value: vm.friendsCount,   caption: L10n.profileFriends)
        }
    }

    private func statItem(value: Int, caption: String) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(Theme.Typography.profileStatNum)
                .foregroundColor(Theme.Palette.profileName)
            Text(caption)
                .font(Theme.Typography.profileStatCap)
                .foregroundColor(Theme.Palette.profileStatCaption)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Theme.Palette.profileStatDivider)
            .frame(width: 1, height: 28)
    }
}
