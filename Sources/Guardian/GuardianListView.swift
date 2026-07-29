import SwiftUI

/// 工作台和直播详情共用的守护者列表。数据只来自当前主播自身的守护榜，不包含用户侧购买入口。
struct GuardianListView: View {
    let anchorId: Int64
    let title: String
    let onUserTap: (String) -> Void

    @StateObject private var store: GuardianListStore
    @State private var showsRules = false

    init(anchorId: Int64,
         title: String = L10n.guardianTitle,
         onUserTap: @escaping (String) -> Void) {
        self.anchorId = anchorId
        self.title = title
        self.onUserTap = onUserTap
        _store = StateObject(wrappedValue: GuardianListStore(anchorId: anchorId))
    }

    var body: some View {
        ZStack {
            Color(hex: 0xEFE6FB).ignoresSafeArea()

            Image(GuardianArtwork.topGlow)
                .resizable()
                .scaledToFill()
                .opacity(0.55)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            content
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(hex: 0xEFE6FB), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsRules = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                }
                .accessibilityLabel(L10n.guardianRulesTitle)
            }
        }
        .task { store.loadInitialIfNeeded() }
        .sheet(isPresented: $showsRules) {
            GuardianRulesView()
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isInitialLoading && store.items.isEmpty {
            ProgressView()
                .tint(Color(hex: 0x8F5ED8))
        } else if store.items.isEmpty {
            // H5 的 pull-refresh 包裹空态；守护者在页面打开后新增时无需退出重进。
            ScrollView(showsIndicators: false) {
                GuardianListEmptyState(retry: store.reload, errorMessage: store.errorMessage)
                    .frame(minHeight: 420)
            }
            .refreshable { store.reload() }
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    GuardianTopRankHero(item: store.items[0], onTap: onUserTap)
                        .padding(.top, 12)

                    ForEach(Array(store.items.indices.dropFirst()), id: \.self) { index in
                        let item = store.items[index]
                        GuardianListRow(
                            rank: index + 1,
                            item: item,
                            onTap: { onUserTap(item.id) }
                        )
                        .onAppear { store.loadMoreIfNeeded(currentItem: item) }
                    }

                    listFooter
                }
                .padding(.bottom, 24)
            }
            .refreshable { store.reload() }
        }
    }

    @ViewBuilder
    private var listFooter: some View {
        if store.isLoadingMore {
            ProgressView()
                .tint(Color(hex: 0x8F5ED8))
                .padding(.vertical, 18)
        } else if !store.hasMore {
            Text(L10n.guardianNoMore)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0x80658F))
                .padding(.vertical, 20)
        } else if let errorMessage = store.errorMessage {
            HStack(spacing: 8) {
                Text(errorMessage)
                    .lineLimit(1)
                Button(L10n.commonRetry, action: store.reload)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color(hex: 0x8C4CC1))
            .padding(.vertical, 18)
        } else {
            Color.clear
                .frame(height: 1)
                .onAppear { store.loadMoreIfNeeded(currentItem: store.items.last) }
        }
    }
}

/// 详情页榜单与 H5 一样作为 75% 二级底部面板；工作台入口则直接走全屏导航。
struct GuardianListSheetView: View {
    let anchorId: Int64

    @Environment(\.dismiss) private var dismiss
    @State private var userCardPresentation: UserCardPresentation?

    var body: some View {
        NavigationStack {
            GuardianListView(anchorId: anchorId) { userId in
                userCardPresentation = UserCardPresentation(userId: userId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel(L10n.commonClose)
                }
            }
        }
        .userCardSheet(item: $userCardPresentation)
    }
}

private struct GuardianTopRankHero: View {
    let item: GuardianListItem
    let onTap: (String) -> Void

    var body: some View {
        Button { onTap(item.id) } label: {
            VStack(spacing: 0) {
                ZStack {
                    GuardianAvatar(urlString: item.avatarURL, size: 48, level: nil, framed: false)
                        .offset(y: -1)
                    Image(GuardianArtwork.topFrame(for: .gold))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 94, height: 94)
                        .allowsHitTesting(false)
                }
                .frame(width: 94, height: 94)

                Text(item.nickname.isEmpty ? L10n.guardianTopGuardian : item.nickname)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: 0x222222))
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                    .padding(.top, 4)

                GuardianUserMetaRow(item: item, isTopRank: true)
                    .padding(.top, 6)

                HStack(spacing: 4) {
                    Image(GuardianArtwork.tabIcon(for: item.level))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                    Text(String(format: L10n.guardianDaysLeftFormat, item.remainingDays))
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(Color(hex: 0xFF9438))
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.nickname)
    }
}

private struct GuardianListRow: View {
    let rank: Int
    let item: GuardianListItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 11) {
                Text("\(rank)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(rankColor)
                    .frame(width: 28)
                    .monospacedDigit()

                GuardianAvatar(urlString: item.avatarURL, size: 40, level: nil, framed: false)

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.nickname.isEmpty ? "--" : item.nickname)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    GuardianUserMetaRow(item: item, isTopRank: false)
                        .padding(.top, 4)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(GuardianArtwork.tabIcon(for: item.level))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text(String(format: L10n.guardianDaysLeftFormat, item.remainingDays))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0xFF9438))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.nickname)
    }

    private var rankColor: Color {
        switch item.level {
        case .gold: return Color(hex: 0xFFD24D)
        case .silver: return Color(hex: 0xC9D2DA)
        case .bronze: return Color(hex: 0xE07A4D)
        }
    }
}

/// H5 榜单第二行：性别年龄、用户等级和 VIP 是彼此独立的标识，不能合并成一个守护等级胶囊。
private struct GuardianUserMetaRow: View {
    let item: GuardianListItem
    let isTopRank: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let age = item.age {
                HStack(spacing: 2) {
                    Image(systemName: item.gender == 1 ? "male" : "female")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(age)")
                        .monospacedDigit()
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(hex: 0xFD79C1), in: Capsule())
            }

            if let userLevel = item.userLevel {
                GuardianUserLevelPill(level: userLevel)
            } else if isTopRank {
                GuardianUserLevelPill(level: 0)
            }

            if item.isVIP {
                VIPBadge(size: .small)
            }
        }
    }
}

private struct GuardianUserLevelPill: View {
    let level: Int

    var body: some View {
        HStack(spacing: 2) {
            Image("guardianShield")
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
            Text("Lv.\(level)")
                .monospacedDigit()
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.white)
        .padding(.leading, 4)
        .padding(.trailing, 5)
        .padding(.vertical, 2)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x6B49A8), Color(hex: 0xB16B72)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: Capsule()
        )
    }
}

private struct GuardianListEmptyState: View {
    let retry: () -> Void
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.guardianBeFirst)
                .font(.system(size: 16, weight: .bold))
                .italic()
                .foregroundStyle(.white)
                .frame(width: 260, height: 78)
                .background(
                    Image("guardianEmpty")
                        .resizable()
                        .scaledToFill()
                )
                .clipped()
            VStack(spacing: 8) {
                GuardianEmptyPlaceholderRow(rank: 2)
                GuardianEmptyPlaceholderRow(rank: 3)
            }
            .padding(.top, 32)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xA44848))
                    .multilineTextAlignment(.center)
                Button(L10n.commonRetry, action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0x8F5ED8))
            }
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GuardianEmptyPlaceholderRow: View {
    let rank: Int

    var body: some View {
        HStack(spacing: 11) {
            Text("\(rank)")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(hex: 0xC4B5D2))
                .frame(width: 28)
            Image("defaultUserAvatar")
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            Text(L10n.guardianWaitForYour)
                .font(.system(size: 14))
                .foregroundStyle(.black.opacity(0.4))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// H5 用户资料页的 “His Guardians” 卡。数据来自 getUserDetail 的 guardianList，不能另发 guardian/list。
struct UserGuardianCard: View {
    let guardians: [UserGuardianAnchor]

    private var displayedGuardians: [UserGuardianAnchor] {
        Array(guardians.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Image("guardianShield")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .padding(5)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(Color(hex: 0xCEBEFF), lineWidth: 1))
                Text(String(format: L10n.guardianHisGuardiansFormat, displayedGuardians.count))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(displayedGuardians.indices), id: \.self) { index in
                    let item = displayedGuardians[index]
                    if (Int64(item.anchorId.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 {
                        NavigationLink(value: UserProfileRoute.userId(item.anchorId)) {
                            GuardianProfileAnchorCell(item: item, rank: index)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    } else {
                        GuardianProfileAnchorCell(item: item, rank: index)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.Palette.userProfileStatsCardFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct GuardianProfileAnchorCell: View {
    let item: UserGuardianAnchor
    let rank: Int

    private var rankLevel: GuardianLevel {
        switch rank {
        case 0: return .gold
        case 1: return .silver
        default: return .bronze
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            GuardianAvatar(urlString: item.iconURL, size: 57, level: rankLevel, framed: true)
                .frame(height: 70)
            Text(item.nickname)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            HStack(spacing: 3) {
                Image(GuardianArtwork.tabIcon(for: rankLevel))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                Text(GuardianArtwork.levelName(rankLevel))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}
