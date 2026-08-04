import SwiftUI

/// Profile 顶部紫色渐变区的 content：设置按钮 + 头像 + 名字 + ID + 性别 / 国旗 + SS 段位 + 关注/粉丝/朋友 stats。
///
/// 背景图由 ProfileView 的 `.background { }` 层独立负责（对齐 LiveTabView 模式），
/// 本视图只画 content；ScrollView content 顶在 safe area 下方，状态栏区已由背景图覆盖。
struct ProfileHeaderView: View {
    @ObservedObject var vm: ProfileViewModel
    /// 107 保留账户设置与基础资料，移除关注关系等非 Party 社交内容。
    var showsSocial: Bool = true
    @ObservedObject private var permission = SelfPermissionBridge.shared

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

            if showsSocial {
                statsRow
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
            }

            profileCompletionHint
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
        }
    }

    // 顶部仅放设置入口，名字行的编辑铅笔在 identityRow 内
    private var topActionRow: some View {
        HStack(spacing: 0) {
            Spacer()
            NavigationLink(value: ProfileRoute.settings) {
                CDNAssetImage("profileSettingsIcon")
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
        // 本人头像走 persistent=true，NSCache 命中后切 tab 回来无闪烁
        AvatarView(url: vm.iconURL, size: Theme.Metric.profileAvatarInner, kind: .anchor, persistent: true)
            .frame(width: Theme.Metric.profileAvatarSize, height: Theme.Metric.profileAvatarSize)
            .overlay(
                Circle()
                    .strokeBorder(Theme.Gradients.avatarRing, lineWidth: Theme.Metric.profileAvatarRing)
            )
            .accessibilityHidden(true)
    }

    private var nameAndMeta: some View {
        // 字段空时整段不渲染，避免显示空白行
        VStack(alignment: .leading, spacing: 4) {
            if !vm.displayName.isEmpty {
                HStack(spacing: 6) {
                    Text(vm.displayName)
                        .font(Theme.Typography.profileName)
                        .foregroundColor(Theme.Palette.profileName)
                    NavigationLink(value: ProfileRoute.editProfile) {
                        CDNAssetImage("profileEditIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.profileEditName)
                }
            }

            if !vm.userId.isEmpty {
                Text(L10n.profileIdPrefix + vm.userId)
                    .font(Theme.Typography.profileId)
                    .foregroundColor(Theme.Palette.profileIdText)
            }

            // 年龄 / 国家任一为空时整行收缩，全空时整行不渲染
            if !vm.ageText.isEmpty || !vm.countryText.isEmpty {
                HStack(spacing: 6) {
                    if !vm.ageText.isEmpty {
                        CDNAssetImage("profileGenderIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                        Text(vm.ageText)
                            .font(Theme.Typography.profileMeta)
                            .foregroundColor(Theme.Palette.profileMetaText)
                    }

                    if !vm.ageText.isEmpty, !vm.countryText.isEmpty {
                        // 仅在两侧都有内容时画分隔条
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 1, height: 10)
                            .padding(.horizontal, 4)
                            .accessibilityHidden(true)
                    }

                    if !vm.countryText.isEmpty {
                        CDNAssetImage("profileLocationIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                        Text(vm.countryText)
                            .font(Theme.Typography.profileMeta)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tierBlock: some View {
        // tierLabel 与 ratePerMin 全空时整块不渲染（避免空白胶囊）
        if permission.canWorkDashboard && (!vm.tierLabel.isEmpty || vm.ratePerMin > 0) {
            NavigationLink(value: ProfileRoute.dataStatistics) {
                VStack(alignment: .trailing, spacing: 0) {
                    if !vm.tierLabel.isEmpty {
                        HStack(spacing: 4) {
                            Text(vm.tierLabel)
                                .font(Theme.Typography.profileTier)
                                .foregroundColor(Theme.Palette.profileTier)
                            CDNAssetImage("profileChevronRight")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(String(format: L10n.profileRatePerMinFormat, vm.ratePerMin))
                        .font(Theme.Typography.profileRate)
                        .foregroundColor(Theme.Palette.profileRate)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.dataStatisticsNavTitle)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(value: vm.followingCount, caption: L10n.profileFollowing, segment: .following)
            statDivider
            statItem(value: vm.followersCount, caption: L10n.profileFollowers, segment: .followers)
            statDivider
            statItem(value: vm.friendsCount,   caption: L10n.profileFriends,   segment: .friends)
        }
    }

    @ViewBuilder
    private var profileCompletionHint: some View {
        if vm.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(L10n.profileCompletionHint)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color(hex: 0x6BFF85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 单个 stat 项：点击推入 FollowListView 对应 segment。
    /// NavigationLink(value:) + NavigationStack.navigationDestination(for:) 解耦了
    /// 跳转目标的具体类型，View 只负责声明意图，落地路由由 ProfileView 集中配置。
    private func statItem(value: Int, caption: String, segment: FollowSegment) -> some View {
        NavigationLink(value: segment) {
            VStack(spacing: 4) {
                Text("\(value)")
                    .font(Theme.Typography.profileStatNum)
                    .foregroundColor(Theme.Palette.profileName)
                Text(caption)
                    .font(Theme.Typography.profileStatCap)
                    .foregroundColor(Theme.Palette.profileStatCaption)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption) \(value)")
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Theme.Palette.profileStatDivider)
            .frame(width: 1, height: 28)
    }
}
