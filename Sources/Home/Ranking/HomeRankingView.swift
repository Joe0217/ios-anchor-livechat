import SwiftUI

private let homeRankingScrollCoordinateSpace = "HomeRankingScroll"

private struct HomeRankingScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HomeRankingScrollOffsetMarker: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: HomeRankingScrollOffsetPreferenceKey.self,
                value: proxy.frame(in: .named(homeRankingScrollCoordinateSpace)).minY
            )
        }
        .frame(height: 0)
    }
}

/// 首页右上角全站榜。对齐 H5 `/rank?path=list`：
/// - Charm / Wealth：日、周、月榜 + Top3 + 我的排名
/// - Couple：日、周 CP 榜 + 主播/用户双侧名片入口 + 我的排名
struct HomeRankingView: View {
    @StateObject private var store = HomeRankingStore()
    @State private var category: HomeRankingCategory = .charm
    @State private var period: HomeRankingPeriod = .day
    @State private var showRules = false
    @State private var userCard: UserCardPresentation?
    @State private var coupleReward: HomeCoupleRewardPresentation?
    @State private var enteredAt = Date()
    @State private var isNavigationBarScrolled = false
    @Environment(\.dismiss) private var dismiss

    private var availablePeriods: [HomeRankingPeriod] {
        category == .couple ? [.day, .week] : HomeRankingPeriod.allCases
    }

    private var normalPayload: HomeRankingPayload? {
        store.payload(category: category, period: period)
    }
    private var couplePayload: HomeCoupleRankingPayload? {
        store.couplePayload(period: period)
    }

    var body: some View {
        Group {
            if category == .couple {
                coupleContent
            } else {
                normalContent
            }
        }
        .background(background.ignoresSafeArea())
        .navigationTitle(L10n.homeRankTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .swipeToPopEnabled()
        .scrollingNavigationBarBlur(isVisible: isNavigationBarScrolled)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.commonBack)
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    ForEach(HomeRankingCategory.allCases) { item in
                        Button { category = item } label: {
                            Text(item.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(category == item ? .white : .white.opacity(0.55))
                                .frame(minWidth: 54, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showRules = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(L10n.homeRankRules)
            }
        }
        .task(id: requestKey) {
            HomeRankingAnalytics.report(
                category == .couple ? "h_cprank_view" : "h_rank_view",
                properties: ["tab": period.rawValue, "page": category.rawValue, "path": "list"]
            )
            store.load(category: category, period: period)
        }
        .onChange(of: category) { newCategory in
            if newCategory == .couple, period == .month {
                period = .day
            }
        }
        .onPreferenceChange(HomeRankingScrollOffsetPreferenceKey.self, perform: updateNavigationBar)
        .userCardSheet(item: $userCard)
        .overlay {
            if showRules {
                HomeRankingRulesPopup(
                    text: category == .couple ? L10n.homeRankCoupleRulesText : L10n.homeRankCharmRulesText,
                    onDismiss: { showRules = false }
                )
            }
            if let coupleReward {
                ZStack {
                    Color.black.opacity(0.58)
                        .ignoresSafeArea()
                        .onTapGesture { self.coupleReward = nil }
                    HomeCoupleRewardSheet(presentation: coupleReward)
                        .padding(.horizontal, 18)
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            let duration = Int(Date().timeIntervalSince(enteredAt) * 1_000)
            HomeRankingAnalytics.report("h_rank_leave", properties: ["type": "diamond", "duration": "\(duration)"])
            store.clearCache()
        }
    }

    private var requestKey: String { "\(category.rawValue)-\(period.rawValue)" }

    private var background: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color(hex: category == .wealth ? 0xD761A9 : category == .charm ? 0x957654 : 0xA6107A)
                if category == .wealth {
                    Image("homeRankWealthBackground")
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: backgroundHeight(topSafeArea: proxy.safeAreaInsets.top), alignment: .top)
                        .clipped()
                } else if category == .charm {
                    Image("homeRankCharmBackground")
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: backgroundHeight(topSafeArea: proxy.safeAreaInsets.top), alignment: .top)
                        .clipped()
                } else {
                    Image("homeCpBackground")
                        .resizable()
                        .frame(maxWidth: .infinity)
                        .frame(height: 400, alignment: .top)
                        .clipped()
                }
            }
        }
    }

    private func backgroundHeight(topSafeArea: CGFloat) -> CGFloat {
        // 背景从物理屏幕顶部开始，结束在列表起点以下 20pt，避免底色在列表前露出。
        let topChrome = max(topSafeArea, 44) + 44
        let listTop: CGFloat = 46 + 250 - 12
        return topChrome + listTop + 20
    }

    private var normalPeriodTabs: some View {
        HStack(spacing: 0) {
            ForEach(availablePeriods) { item in
                Button { period = item } label: {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if period == item {
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(period == item ? .isSelected : [])
            }
        }
        .padding(2)
        .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1))
        .padding(.horizontal, 20)
    }

    private var normalContent: some View {
        GeometryReader { geometry in
            ScrollView {
                HomeRankingScrollOffsetMarker()
                VStack(spacing: 0) {
                    normalPeriodTabs
                        .padding(.top, 0)
                        .padding(.bottom, 4)

                    HomeRankingTopThree(
                        members: normalPayload?.members ?? [],
                        category: category,
                        onTap: openUserCard
                    )

                    HomeRankingList(
                        members: normalPayload?.members ?? [],
                        category: category,
                        onTap: openUserCard,
                        minimumHeight: max(124, geometry.size.height - 296),
                        bottomContentInset: 50,
                        hasMore: store.hasMore(category: category, period: period),
                        isLoadingMore: store.isLoadingMore(category: category, period: period),
                        pageError: store.pageError(category: category, period: period),
                        onLoadMore: { store.loadMore(category: category, period: period) }
                    )
                    .padding(.top, -12)
                }
                .padding(.bottom, 12)
            }
            .coordinateSpace(name: homeRankingScrollCoordinateSpace)
            .scrollIndicators(.hidden)
            .refreshable {
                await store.refresh(category: category, period: period)
            }
        }
        .overlay(alignment: .bottom) {
            HomeRankingMineRow(member: normalPayload?.mine, category: category, onTap: openUserCard)
                .padding(.bottom, -20)
        }
        .overlay {
            if store.isLoading(category: category, period: period) {
                HomeRankingLoadingOverlay()
            }
        }
    }

    private var coupleContent: some View {
        H5CoupleRankingBody(
            members: couplePayload?.members ?? [],
            mine: couplePayload?.mine,
            period: $period,
            onTap: openUserCard,
            onRewards: { member in
                coupleReward = HomeCoupleRewardPresentation(member: member)
            },
            hasMore: store.hasMore(category: category, period: period),
            isLoadingMore: store.isLoadingMore(category: category, period: period),
            pageError: store.pageError(category: category, period: period),
            onLoadMore: { store.loadMore(category: category, period: period) }
        )
        .refreshable {
            await store.refresh(category: category, period: period)
        }
        .overlay {
            if store.isLoading(category: category, period: period) {
                HomeRankingLoadingOverlay()
            }
        }
    }

    private func openUserCard(_ member: HomeRankingMember?) {
        guard let member, !member.userId.isEmpty else { return }
        userCard = UserCardPresentation(preview: member.userCardPreview)
    }

    private func openUserCard(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        userCard = UserCardPresentation(userId: id)
    }

    private func updateNavigationBar(_ offset: CGFloat) {
        let shouldShowBackground = offset < -8
        guard shouldShowBackground != isNavigationBarScrolled else { return }
        isNavigationBarScrolled = shouldShowBackground
    }
}

struct HomeRankingLoadingOverlay: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(L10n.profileLoading)
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
        .allowsHitTesting(false)
    }
}

struct HomeRankingTopThree: View {
    let members: [HomeRankingMember]
    let category: HomeRankingCategory
    let onTap: (HomeRankingMember?) -> Void

    private var podiumMembers: [(member: HomeRankingMember?, rank: Int)] {
        [
            (members.count > 1 ? members[1] : nil, 2),
            (members.first, 1),
            (members.count > 2 ? members[2] : nil, 3)
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(podiumMembers.enumerated()), id: \.offset) { _, entry in
                HomeRankingPodiumCell(member: entry.member, rank: entry.rank, category: category, onTap: onTap)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .frame(height: 250, alignment: .top)
    }
}

private struct HomeRankingPodiumCell: View {
    let member: HomeRankingMember?
    let rank: Int
    let category: HomeRankingCategory
    let onTap: (HomeRankingMember?) -> Void

    private var assetName: String {
        switch rank {
        case 1: return "homeRankTop1"
        case 2: return "homeRankTop2"
        default: return "homeRankTop3"
        }
    }

    private var height: CGFloat { rank == 1 ? 223 : rank == 2 ? 190 : 180 }
    private var avatarSize: CGFloat { rank == 1 ? 60 : rank == 2 ? 55 : 50 }
    private var topOffset: CGFloat { rank == 1 ? 20 : rank == 2 ? 40 : 60 }
    private var avatarY: CGFloat { rank == 1 ? 0 : rank == 2 ? -5 : -12 }
    private var textY: CGFloat { rank == 1 ? 112 : rank == 2 ? 92 : 77 }
    private var infoY: CGFloat { textY - (category == .charm ? 10 : 0) }

    var body: some View {
        ZStack(alignment: .top) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: rank == 2 ? 192 : height)
                .offset(y: -20)

            Button { onTap(member) } label: {
                AvatarView(urlString: member?.icon, size: avatarSize, kind: .user, disablesTap: true)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .offset(y: avatarY)

            VStack(spacing: 4) {
                Text(member?.nickname ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 96)

                memberMeta

                HomeRankingValue(value: member?.value ?? "0", fontSize: 12, imageName: "homeRankDiamondPurple")

                if let reward = member?.reward, !reward.isEmpty {
                    HStack(spacing: 3) {
                        Image("homeRankRewardDiamond")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                        Text("+ \(reward)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.38), in: Capsule())
                }
            }
            .offset(y: infoY)
        }
        .frame(width: 112, height: height)
        .padding(.top, topOffset)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var memberMeta: some View {
        if category == .charm {
            if let country = member?.countryId, !country.isEmpty {
                HStack(spacing: 2) {
                    Image("liveListLocation")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 10, height: 10)
                    Text(country)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.9))
            }
        } else {
            HStack(spacing: 3) {
                UserLevelBadge(levelName: member?.levelName, size: .small)
                if member?.isVip == true { VIPBadge(size: .small) }
            }
            .frame(height: 14)
        }
    }
}

struct HomeRankingList: View {
    let members: [HomeRankingMember]
    let category: HomeRankingCategory
    let onTap: (HomeRankingMember?) -> Void
    var minimumHeight: CGFloat = 0
    /// 固定“我的排名”栏覆盖列表时，预留末行可滚动到栏位上沿的空间。
    var bottomContentInset: CGFloat = 0
    let hasMore: Bool
    let isLoadingMore: Bool
    let pageError: String?
    let onLoadMore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if members.count > 3 {
                LazyVStack(spacing: 0) {
                    ForEach(Array(members.dropFirst(3).enumerated()), id: \.element.id) { index, member in
                        HomeRankingMemberRow(member: member, rank: index + 4, category: category, onTap: onTap)
                        if index < members.count - 4 {
                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 68)
                        }
                    }
                }
                .padding(.bottom, bottomContentInset)
                .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
            } else if members.isEmpty {
                EmptyStateView(
                    style: .compact,
                    text: L10n.homeRankNoData,
                    textColor: .white.opacity(0.75)
                )
                .frame(maxWidth: .infinity, minHeight: max(124, minimumHeight))
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: minimumHeight)
            }

            if hasMore {
                HomeRankingLoadMoreFooter(
                    isLoading: isLoadingMore,
                    errorMessage: pageError,
                    onLoadMore: onLoadMore
                )
            }
        }
        .background(Color(hex: 0x2B213E))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct HomeRankingLoadMoreFooter: View {
    let isLoading: Bool
    let errorMessage: String?
    let onLoadMore: () -> Void

    var body: some View {
        Group {
            if isLoading {
                HomeRankingLoadingOverlay()
            } else if let errorMessage {
                HStack(spacing: 8) {
                    Text(errorMessage)
                        .lineLimit(1)
                    Button(action: onLoadMore) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.Wallet.retry)
                }
                .foregroundStyle(.white.opacity(0.75))
            } else {
                Color.clear
                    .onAppear(perform: onLoadMore)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, minHeight: isLoading ? 76 : 36)
        .padding(.bottom, 8)
    }
}

private struct HomeRankingMemberRow: View {
    let member: HomeRankingMember
    let rank: Int
    let category: HomeRankingCategory
    let onTap: (HomeRankingMember?) -> Void

    var body: some View {
        Button { onTap(member) } label: {
            HStack(spacing: 12) {
                rankBadge

                AvatarView(urlString: member.icon, size: 44, kind: .user, disablesTap: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(member.nickname)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if category == .charm {
                        HStack(spacing: 3) {
                            if let age = member.age {
                                Text("\(age)")
                            }
                            if let country = member.countryId, !country.isEmpty {
                                Image("liveListLocation")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 12, height: 12)
                                Text(country)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    } else {
                        HStack(spacing: 4) {
                            UserLevelBadge(levelName: member.levelName, size: .small)
                            if member.isVip { VIPBadge(size: .small) }
                        }
                        .frame(height: 14)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 4) {
                    HomeRankingValue(value: member.value, fontSize: 15, imageName: "homeRankDiamondPurple")
                    if let reward = member.reward, !reward.isEmpty {
                        HStack(spacing: 3) {
                            if category == .charm {
                                Image("coins")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 12, height: 12)
                            }
                            Text("+ \(reward)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            LinearGradient(colors: [Color(hex: 0x8515FF).opacity(0.4), Color(hex: 0xE40132).opacity(0.4)], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rank). \(member.nickname)")
    }

    @ViewBuilder
    private var rankBadge: some View {
        switch rank {
        case 1: Image("pkBattleMVP").resizable().scaledToFit().frame(width: 26, height: 26)
        case 2: Image("pkBattleRank2").resizable().scaledToFit().frame(width: 26, height: 26)
        case 3: Image("pkBattleRank3").resizable().scaledToFit().frame(width: 26, height: 26)
        default:
            Text("\(rank)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 30)
        }
    }
}

struct HomeRankingMineRow: View {
    let member: HomeRankingMember?
    let category: HomeRankingCategory
    let onTap: (HomeRankingMember?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(member?.isRanked == true ? "\(member?.rank ?? 0)" : L10n.homeRankNotRanked)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42)
            Button { onTap(member) } label: {
                AvatarView(urlString: member?.icon, size: 42, kind: .anchor, disablesTap: true)
            }
            .buttonStyle(.plain)
            Text(member?.nickname ?? L10n.anonymous)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            HomeRankingValue(value: member?.value ?? "0", fontSize: 15, imageName: "homeRankDiamondPurple")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 70)
        .background(Color(hex: category == .wealth ? 0xD761A9 : 0x957654).opacity(0.96))
    }
}

private struct HomeRankingValue: View {
    let value: String
    let fontSize: CGFloat
    var compact: Bool = false
    var imageName: String = "diamondYellow"

    private var displayValue: String {
        guard compact, let number = Double(value), number.isFinite else { return value }
        let sign = number < 0 ? "-" : ""
        let absolute = abs(number)
        if absolute >= 1_000_000 {
            return String(format: "%@%.2fM", sign, absolute / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%@%.2fK", sign, absolute / 1_000)
        }
        return value
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: fontSize, height: fontSize)
            Text(displayValue)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

private struct HomeCoupleRewardPresentation: Identifiable {
    let member: HomeCoupleRankingMember
    var id: String { member.id }
}

private struct HomeCoupleRewardSheet: View {
    let presentation: HomeCoupleRewardPresentation

    private var groupedRewards: [H5CoupleRewardGroup] {
        let merged = presentation.member.anchorRewards.map { H5CoupleRewardItem(reward: $0, isAnchor: true) }
            + presentation.member.userRewards.map { H5CoupleRewardItem(reward: $0, isAnchor: false) }
        return Dictionary(grouping: merged, by: { $0.reward.itemType })
            .map { H5CoupleRewardGroup(type: $0.key, items: $0.value) }
            .sorted { $0.type < $1.type }
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: -1) {
                Image("homeCpRewardTop")
                    .resizable()
                    .scaledToFill()
                    .frame(height: 94)
                Group {
                    if groupedRewards.isEmpty {
                        Text(L10n.homeRankNoData)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(groupedRewards) { group in
                                    HStack(spacing: 20) {
                                        ForEach(group.items) { item in
                                            VStack(spacing: 4) {
                                                ZStack(alignment: item.isAnchor ? .topLeading : .topTrailing) {
                                                    HomeCoupleRewardIcon(reward: item.reward, size: 60)
                                                    Image(item.isAnchor ? "homeCpRewardHost" : "homeCpRewardUser")
                                                        .resizable()
                                                        .scaledToFit()
                                                        .frame(width: 45, height: 18)
                                                        .offset(x: item.isAnchor ? -20 : 20, y: -10)
                                                }
                                                Text(rewardLabel(item.reward))
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                    .frame(width: 110)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 16)
                                    .padding(.horizontal, 26)
                                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                            .padding(18)
                        }
                        .frame(maxHeight: 350)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(
                    Image("homeCpRewardCenter")
                        .resizable()
                        .scaledToFill()
                )
                Image("homeCpRewardBottom")
                    .resizable()
                    .scaledToFill()
                    .frame(height: 65)
            }

            Text(L10n.homeRankCpWeeklyRewardFormat(presentation.member.rank ?? 1))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 52)
        }
        .frame(maxWidth: .infinity)
        .background(Color.clear)
        .preferredColorScheme(.dark)
    }

    private func rewardLabel(_ reward: HomeCoupleRankingReward) -> String {
        let days = reward.durationDays > 0 ? " \u{00D7} \(reward.durationDays)d" : ""
        return "\(reward.itemName ?? "")\(days)"
    }
}

private struct H5CoupleRewardItem: Identifiable {
    let reward: HomeCoupleRankingReward
    let isAnchor: Bool
    var id: String { "\(isAnchor ? "anchor" : "user")-\(reward.id)" }
}

private struct H5CoupleRewardGroup: Identifiable {
    let type: Int
    let items: [H5CoupleRewardItem]
    var id: Int { type }
}

private struct HomeCoupleRewardIcon: View {
    let reward: HomeCoupleRankingReward
    let size: CGFloat

    var body: some View {
        Group {
            if let rawURL = reward.itemIcon, let url = URL(string: rawURL) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "gift.fill")
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.2)
                            .foregroundStyle(Color(hex: 0xFFD3EE))
                    }
                }
            } else {
                Image(systemName: "gift.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundStyle(Color(hex: 0xFFD3EE))
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - H5 CP ranking composition

private struct H5CoupleRankingBody: View {
    let members: [HomeCoupleRankingMember]
    let mine: HomeCoupleRankingMember?
    @Binding var period: HomeRankingPeriod
    let onTap: (String?) -> Void
    let onRewards: (HomeCoupleRankingMember) -> Void
    let hasMore: Bool
    let isLoadingMore: Bool
    let pageError: String?
    let onLoadMore: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                HomeRankingScrollOffsetMarker()
                Color.clear.frame(height: 147)
                Section {
                    H5CoupleTopCard(members: members, onTap: onTap, onRewards: onRewards)
                    H5CoupleList(
                        members: members,
                        onTap: onTap,
                        hasMore: hasMore,
                        isLoadingMore: isLoadingMore,
                        pageError: pageError,
                        onLoadMore: onLoadMore
                    )
                        .padding(.top, 6)
                } header: {
                    H5CouplePeriodTabs(period: $period)
                        .padding(.bottom, 10)
                }
            }
            .padding(.bottom, 8)
        }
        .coordinateSpace(name: homeRankingScrollCoordinateSpace)
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            H5CoupleMineRow(member: mine, onTap: onTap)
        }
    }
}

private struct H5CouplePeriodTabs: View {
    @Binding var period: HomeRankingPeriod

    var body: some View {
        HStack(spacing: 6) {
            tab(.day, active: "homeCpDayActive", inactive: "homeCpDayDefault")
            tab(.week, active: "homeCpWeekActive", inactive: "homeCpWeekDefault")
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    private func tab(_ value: HomeRankingPeriod, active: String, inactive: String) -> some View {
        Button { period = value } label: {
            Image(period == value ? active : inactive)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 63.5, maxHeight: 63.5)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(period == value ? .isSelected : [])
    }
}

private struct H5CoupleTopCard: View {
    let members: [HomeCoupleRankingMember]
    let onTap: (String?) -> Void
    let onRewards: (HomeCoupleRankingMember) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Image("homeCpTopCard")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: 476, maxHeight: 476)
                .clipped()

            Image("homeCpCardTopOrnament")
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 30)
                .offset(y: -14)

            VStack(spacing: 0) {
                H5CoupleTopOne(member: members.first, onTap: onTap, onRewards: onRewards)
                HStack(spacing: 4) {
                    H5CoupleMiniCard(member: member(at: 1), rank: 2, onTap: onTap, onRewards: onRewards)
                    H5CoupleMiniCard(member: member(at: 2), rank: 3, onTap: onTap, onRewards: onRewards)
                }
                .padding(.horizontal, 6)
                Image("homeCpCardBottomOrnament")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 20)
                    .padding(.top, 2)
            }
            .padding(.top, 18)
        }
        .frame(height: 476)
        .padding(.horizontal, 6)
    }

    private func member(at index: Int) -> HomeCoupleRankingMember? {
        members.indices.contains(index) ? members[index] : nil
    }
}

private struct H5CoupleTopOne: View {
    let member: HomeCoupleRankingMember?
    let onTap: (String?) -> Void
    let onRewards: (HomeCoupleRankingMember) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Image("homeCpTop1Badge")
                .resizable()
                .scaledToFit()
                .frame(width: 141, height: 78)
                .offset(y: 4)

            H5CoupleAvatarPair(
                member: member,
                large: true,
                onTap: onTap
            )
            .offset(y: 48)

            Image("homeCpRoseLarge")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .offset(y: 117)

            H5CoupleDiamondPill(value: member?.value ?? "0", fontSize: 14)
                .offset(y: 158)

            H5CoupleNamePair(member: member, compact: false)
                .frame(width: 220, height: 26)
                .offset(y: 191)

            if let member, !member.anchorRewards.isEmpty || !member.userRewards.isEmpty {
                H5CoupleRewardStrip(rewards: member.anchorRewards, onTap: { onRewards(member) })
                    .offset(y: 220)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 257)
    }
}

private struct H5CoupleMiniCard: View {
    let member: HomeCoupleRankingMember?
    let rank: Int
    let onTap: (String?) -> Void
    let onRewards: (HomeCoupleRankingMember) -> Void

    private var badge: String { rank == 2 ? "homeCpTop2Badge" : "homeCpTop3Badge" }

    var body: some View {
        ZStack(alignment: .top) {
            Image(badge)
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 55)

            H5CoupleAvatarPair(member: member, large: false, onTap: onTap)
                .offset(y: 28)

            Image("homeCpRoseSmall")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .offset(y: 72)

            H5CoupleDiamondPill(value: member?.value ?? "0", fontSize: 12)
                .offset(y: 95)

            H5CoupleNamePair(member: member, compact: true)
                .frame(width: 160, height: 20)
                .offset(y: 121)

            if let member, !member.anchorRewards.isEmpty || !member.userRewards.isEmpty {
                H5CoupleRewardStrip(rewards: member.anchorRewards, onTap: { onRewards(member) })
                    .scaleEffect(0.82)
                    .offset(y: 143)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
    }
}

private struct H5CoupleAvatarPair: View {
    let member: HomeCoupleRankingMember?
    let large: Bool
    let onTap: (String?) -> Void

    private var frameSize: CGFloat { large ? 104 : 72 }
    private var avatarSize: CGFloat { large ? 76 : 50 }

    var body: some View {
        ZStack {
            Image("homeCpWingLeft")
                .resizable()
                .scaledToFit()
                .frame(width: large ? 105 : 44, height: large ? 150 : 63)
                .offset(x: large ? -94 : -54, y: large ? -15 : 4)
            Image("homeCpWingRight")
                .resizable()
                .scaledToFit()
                .frame(width: large ? 105 : 44, height: large ? 150 : 63)
                .offset(x: large ? 94 : 54, y: large ? -15 : 4)

            avatar(icon: member?.anchorIcon, id: member?.anchorId, pink: true)
                .offset(x: large ? -52 : -36)
            avatar(icon: member?.isMysteryUser == true ? nil : member?.userIcon, id: member?.userId, pink: false)
                .offset(x: large ? 52 : 36)
        }
        .frame(width: large ? 210 : 144, height: large ? 110 : 75)
    }

    private func avatar(icon: String?, id: String?, pink: Bool) -> some View {
        Button { onTap(id) } label: {
            ZStack {
                if icon == nil {
                    Image("homeCpDefaultUser")
                        .resizable()
                        .scaledToFill()
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                } else {
                    AvatarView(urlString: icon, size: avatarSize, kind: .user, disablesTap: true)
                }
                Image(large ? (pink ? "homeCpTop1FramePink" : "homeCpTop1FrameBlue") : (pink ? "homeCpWreathPink" : "homeCpWreathBlue"))
                    .resizable()
                    .scaledToFit()
                    .frame(width: frameSize, height: frameSize)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct H5CoupleNamePair: View {
    let member: HomeCoupleRankingMember?
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 3 : 6) {
            Text(member?.anchorNickname ?? L10n.homeRankHostPlaceholder)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Image("homeCpHeartGlow")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
            Text(member?.displayUserNickname ?? L10n.homeRankUserPlaceholder)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .font(.system(size: compact ? 12 : 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 8 : 16)
        .background {
            Image("homeCpNameDivider")
                .resizable()
                .scaledToFill()
        }
    }
}

private struct H5CoupleRewardStrip: View {
    let rewards: [HomeCoupleRankingReward]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                ForEach(rewards) { reward in
                    ZStack {
                        Image("homeCpRewardDot")
                            .resizable()
                            .scaledToFit()
                        HomeCoupleRewardIcon(reward: reward, size: 20)
                    }
                    .frame(width: 22, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct H5CoupleList: View {
    let members: [HomeCoupleRankingMember]
    let onTap: (String?) -> Void
    let hasMore: Bool
    let isLoadingMore: Bool
    let pageError: String?
    let onLoadMore: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if members.count > 3 {
                ForEach(Array(members.dropFirst(3).enumerated()), id: \.element.id) { index, member in
                    H5CoupleListRow(member: member, rank: index + 4, onTap: onTap)
                }
            } else if members.isEmpty {
                VStack(spacing: 8) {
                    Image("homeCpDefaultUser")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                    Text(L10n.homeRankNoData)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }

            if hasMore {
                HomeRankingLoadMoreFooter(
                    isLoading: isLoadingMore,
                    errorMessage: pageError,
                    onLoadMore: onLoadMore
                )
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct H5CoupleListRow: View {
    let member: HomeCoupleRankingMember
    let rank: Int
    let onTap: (String?) -> Void
    var isMine: Bool = false

    private var textColor: Color { isMine ? .white : Color(hex: 0x6D0F52) }

    var body: some View {
        ZStack {
            Image(isMine ? "homeCpSelfRank" : "homeCpListItem")
                .resizable()
                .scaledToFill()

            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(textColor)
                    .frame(width: 22)
                H5CoupleSmallPair(member: member, onTap: onTap)
                VStack(alignment: .leading, spacing: -8) {
                    Text(member.anchorNickname)
                    Image("homeCpHeartDivider")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 37, height: 37)
                    Text(member.displayUserNickname)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                H5CoupleDiamondPill(value: member.value, fontSize: 12)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 64)
    }
}

private struct H5CoupleSmallPair: View {
    let member: HomeCoupleRankingMember
    let onTap: (String?) -> Void

    var body: some View {
        ZStack {
            pairAvatar(icon: member.anchorIcon, id: member.anchorId)
                .offset(x: -27)
            pairAvatar(icon: member.isMysteryUser ? nil : member.userIcon, id: member.userId)
                .offset(x: 27)
            Image("homeCpRoseSmall")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 39)
                .offset(y: -3)
        }
        .frame(width: 100, height: 45)
    }

    private func pairAvatar(icon: String?, id: String?) -> some View {
        Button { onTap(id) } label: {
            ZStack {
                if icon == nil {
                    Image("homeCpDefaultUser")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 45, height: 45)
                        .clipShape(Circle())
                } else {
                    AvatarView(urlString: icon, size: 45, kind: .user, disablesTap: true)
                }
                Image("homeCpAvatarFrame")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 45, height: 45)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct H5CoupleMineRow: View {
    let member: HomeCoupleRankingMember?
    let onTap: (String?) -> Void

    var body: some View {
        Group {
            if let member {
                H5CoupleListRow(member: member, rank: member.rank ?? 0, onTap: onTap, isMine: true)
            } else {
                ZStack {
                    Image("homeCpSelfRank")
                        .resizable()
                        .scaledToFill()
                HStack(spacing: 12) {
                    Text("-").font(.system(size: 15, weight: .bold)).frame(width: 22)
                    Image("homeCpDefaultUser")
                        .resizable().scaledToFit().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.homeRankNotOnListYet).font(.system(size: 13, weight: .bold))
                        Text(L10n.homeRankKeepSendingGifts).font(.system(size: 12))
                    }
                    .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                }
            }
        }
        .frame(height: 64)
    }
}

private struct H5CoupleDiamondPill: View {
    let value: String
    let fontSize: CGFloat

    var body: some View {
        HomeRankingValue(value: value, fontSize: fontSize, compact: true)
            .padding(.horizontal, fontSize == 14 ? 10 : 7)
            .padding(.vertical, fontSize == 14 ? 5 : 3)
            .background(
                LinearGradient(colors: [Color(hex: 0xB5056F), Color(hex: 0xF57CC5), Color(hex: 0xB5056F)], startPoint: .leading, endPoint: .trailing),
                in: Capsule()
            )
            .overlay(Capsule().stroke(.white, lineWidth: 1))
    }
}
