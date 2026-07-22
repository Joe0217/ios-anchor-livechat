import SwiftUI

/// v16 UserWeeklyRankSheet 对齐 H5 **userWeeklyRank.vue** 语义：观众列表 + 送礼榜
///
/// **入口**：顶部观众数字 icon tap → 打开本 sheet
///
/// **UI 结构完整对齐 H5**：
/// - **无 banner**（区别于 RankSheetView 的主播周榜 banner）
/// - **顶层双 Tab**：Viewers / Top Gifter
///   - **Viewers Tab**（apiViewers）：观众列表，row = avatar + nickname + [BIG R badge] + [Level badge] + [VIP badge] + 位置
///   - **Top Gifter Tab**（apiSendRank）：3 内层子 Tab **Now / Today / Week**
///     - Now/Today：普通列表（rank badge + avatar + nickname + costNum）
///     - Week：**头部前 3 名大卡片区**（h160 渐变金/银/铜，第 2 名向上偏移 -20），4+ 普通行
/// - **无主播悬浮**（主播不参与 Top Gifter 排名，H5 userWeeklyRank 无 anchor bar）
///
/// **v16 行为**：`.interactiveDismissDisabled(true)` + 列表 `.refreshable`
struct UserWeeklyRankSheetView: View {
    @Binding var isPresented: Bool
    let anchorUserId: Int
    let dbId: Int
    let onUserTap: (String) -> Void

    @State private var topTab: RankSheetTopTab
    @State private var subTab: SendRankType = .now
    @State private var viewersList: [ViewerEntry] = []
    @State private var viewersLoading = true
    @State private var rankLists: [SendRankType: [SendRankEntry]] = [:]
    @State private var loadingRankTabs: Set<SendRankType> = []

    private let viewersService: ViewersServiceProtocol
    private let rankService: SendRankServiceProtocol

    init(isPresented: Binding<Bool>, anchorUserId: Int, dbId: Int,
         initialTopTab: RankSheetTopTab = .viewers,
         onUserTap: @escaping (String) -> Void = { _ in },
         viewersService: ViewersServiceProtocol = ViewersServiceReal(),
         rankService: SendRankServiceProtocol = SendRankServiceReal()) {
        self._isPresented = isPresented
        self.anchorUserId = anchorUserId
        self.dbId = dbId
        self.onUserTap = onUserTap
        self._topTab = State(initialValue: initialTopTab)
        self.viewersService = viewersService
        self.rankService = rankService
    }

    var body: some View {
        // v20: 移除 closeBar（关闭走系统下拉手势）
        VStack(spacing: 0) {
            topLevelTabBar
            if topTab == .viewers {
                viewersContent
            } else {
                subTabBar
                topGifterContent
            }
        }
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
        .onAppear {
            Task { await loadViewers() }
            Task {
                await loadRank(.now)
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await loadRank(.today)
                await loadRank(.week)
            }
        }
    }

    // MARK: - Top level Tab bar (Viewers / Top Gifter)

    private var topLevelTabBar: some View {
        HStack(spacing: 0) {
            topTabButton(tab: .viewers,   label: L10n.liveRoomRankTabViewers)
            topTabButton(tab: .topGifter, label: L10n.liveRoomRankTabTopGifter)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func topTabButton(tab: RankSheetTopTab, label: String) -> some View {
        Button { topTab = tab } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 16, weight: topTab == tab ? .bold : .medium))
                    .foregroundColor(topTab == tab ? .white : .white.opacity(0.5))
                Rectangle()
                    .fill(topTab == tab ? Color(hex: 0xFE00DE) : .clear)
                    .frame(width: 24, height: 3)
                    .cornerRadius(1.5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sub Tab bar (Now / Today / Week for Top Gifter)

    private var subTabBar: some View {
        HStack(spacing: 0) {
            subTabButton(.now,   label: L10n.liveRoomRankTabNow)
            subTabButton(.today, label: L10n.liveRoomRankTabToday)
            subTabButton(.week,  label: L10n.liveRoomRankTabWeek)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func subTabButton(_ tab: SendRankType, label: String) -> some View {
        Button {
            subTab = tab
            if rankLists[tab] == nil, !loadingRankTabs.contains(tab) {
                Task { await loadRank(tab) }
            }
        } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 14, weight: subTab == tab ? .bold : .regular))
                    .foregroundColor(subTab == tab ? .white : .white.opacity(0.55))
                Rectangle()
                    .fill(subTab == tab ? Color(hex: 0xFFBB02) : .clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Viewers Tab content

    private var viewersContent: some View {
        Group {
            if viewersLoading && viewersList.isEmpty {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewersList.isEmpty {
                emptyView(text: L10n.liveRoomRankViewersEmpty, icon: "person.3.fill")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewersList) { viewer in
                            ViewerRow(viewer: viewer, onUserTap: onUserTap)
                            Divider().background(Color.white.opacity(0.06))
                        }
                    }
                    .padding(.top, 4)
                }
                .refreshable {
                    await loadViewers()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Gifter Tab content (含 Week 前 3 大卡)

    private var topGifterContent: some View {
        Group {
            let list = rankLists[subTab] ?? []
            if loadingRankTabs.contains(subTab) && list.isEmpty {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if list.isEmpty {
                emptyView(text: L10n.liveRoomRankEmpty, icon: "trophy")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if subTab == .week {
                            // Week Tab 头部前 3 名大卡片（对齐 H5 userWeeklyRank L372-439）
                            WeekTopThreeCards(top3: Array(list.prefix(3)), onUserTap: onUserTap)
                                .padding(.vertical, 8)
                            ForEach(Array(list.dropFirst(3))) { entry in
                                sendRankRow(entry)
                                Divider().background(Color.white.opacity(0.06))
                            }
                        } else {
                            // Now / Today 普通列表
                            ForEach(list) { entry in
                                sendRankRow(entry)
                                Divider().background(Color.white.opacity(0.06))
                            }
                        }
                    }
                }
                .refreshable {
                    await loadRank(subTab)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendRankRow(_ entry: SendRankEntry) -> some View {
        HStack(spacing: 12) {
            rankBadge(entry.rank)
            Button { onUserTap(entry.userId) } label: {
                AvatarView(urlString: entry.avatarUrl,
                           size: 40,
                           kind: .user,
                           userId: entry.userId,
                           disablesTap: true)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.nickname)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if entry.isActiveTycoon { ActiveTycoonBadge(style: .bigRText, size: .small) }
                    if entry.level > 0 { levelBadge(entry.level) }
                    if entry.isVip { VIPBadge(size: .medium) }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image("coins")
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(formatDiamond(entry.costNum))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private func rankBadge(_ rank: Int) -> some View {
        Group {
            switch rank {
            case 1: Image(systemName: "crown.fill").foregroundColor(Color(hex: 0xFFBB02)).font(.system(size: 20))
            case 2: Image(systemName: "crown.fill").foregroundColor(Color(hex: 0xC0C0C0)).font(.system(size: 18))
            case 3: Image(systemName: "crown.fill").foregroundColor(Color(hex: 0xCD7F32)).font(.system(size: 16))
            default:
                Text("\(rank)")
                    .foregroundColor(Color(hex: 0xA56FF8))
                    .font(.system(size: 16, weight: .heavy))
            }
        }
        .frame(width: 24, alignment: .center)
    }

    // MARK: - Badges

    // v24（B1 · prefer-shared-component-over-adhoc）：私有 bigRBadge 迁移到公共组件
    // [ActiveTycoonBadge](../../Badges/ActiveTycoonBadge.swift)，同 badge 被 6+ 处调用点复用

    /// 2026-07-10 迁移到公共组件 UserLevelBadge (11 tier gradient 对齐 H5)
    private func levelBadge(_ level: Int) -> some View {
        UserLevelBadge(level: level, size: .small)
    }

    // v25：VIP 徽章统一走公共组件 VIPBadge（[Sources/DesignSystem/Badges/VIPBadge.swift]），
    // 原自定义 Text("VIP") + 黄色 rounded 版本已废弃。

    private func formatDiamond(_ n: Int64) -> String {
        if n >= 1000 {
            let k = Double(n / 100) / 10.0
            return String(format: "%.1fk", k)
        }
        return "\(n)"
    }

    // MARK: - Empty state

    private func emptyView(text: String, icon: String) -> some View {
        // 保留 text/icon 形参签名以兼容既有 call site；统一空态里 text/icon 被 EmptyStateView 忽略
        EmptyStateView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data loading

    private func loadViewers() async {
        viewersLoading = true
        do {
            let list = try await viewersService.fetchViewers(anchorUserId: anchorUserId)
            // v18 Q2: 过滤当前主播自己（对齐 H5：apiViewers 后端返回列表可能含主播，前端不展示自己）
            let anchorId = String(anchorUserId)
            viewersList = list.filter { $0.userId != anchorId }
        } catch {
            // 保持现有列表，避免闪空
        }
        viewersLoading = false
    }

    private func loadRank(_ tab: SendRankType) async {
        guard !loadingRankTabs.contains(tab) else { return }
        loadingRankTabs.insert(tab)
        defer { loadingRankTabs.remove(tab) }
        do {
            let list = try await rankService.fetchSendRank(rankType: tab, dbId: dbId)
            rankLists[tab] = Array(list.prefix(100))
        } catch {
            // 保持现有
        }
    }
}

/// v16 Week Tab 前 3 名大卡片（对齐 H5 userWeeklyRank L372-439：h160 渐变 + 第 2 名向上偏移 -20）
private struct WeekTopThreeCards: View {
    let top3: [SendRankEntry]
    let onUserTap: (String) -> Void

    var body: some View {
        // H5 顺序：[1 (top1 居中), 0 (top2 左), 2 (top3 右)]，第 2 名向上偏移 -20
        HStack(alignment: .top, spacing: 8) {
            if top3.count > 1 {
                topCard(entry: top3[1], rank: 2, offsetY: -20)
            } else {
                Spacer().frame(width: 100)
            }
            if !top3.isEmpty {
                topCard(entry: top3[0], rank: 1, offsetY: 0)
            } else {
                Spacer().frame(width: 100)
            }
            if top3.count > 2 {
                topCard(entry: top3[2], rank: 3, offsetY: -20)
            } else {
                Spacer().frame(width: 100)
            }
        }
        .frame(height: 180)   // v18 Q4: 155 内容 + 20 二三名向上偏移 + 5 padding = 180
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private func topCard(entry: SendRankEntry, rank: Int, offsetY: CGFloat) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "crown.fill")
                .font(.system(size: 20))
                .foregroundColor(crownColor(rank))
            ZStack(alignment: .bottom) {
                Button { onUserTap(entry.userId) } label: {
                    AvatarView(urlString: entry.avatarUrl,
                               size: 48,
                               kind: .user,
                               userId: entry.userId,
                               disablesTap: true)
                        .overlay(Circle().stroke(crownColor(rank), lineWidth: 2))
                }
                .buttonStyle(.plain)
                // v18 Q4: Week 前 3 名等级徽章（对齐 H5 userWeeklyRank Week Tab Top3 level badge h18 z-3）
                // 2026-07-10 迁移到公共组件 UserLevelBadge
                if entry.level > 0 {
                    UserLevelBadge(level: entry.level, size: .small)
                        .offset(y: 6)   // 半覆盖 avatar 底沿
                }
            }
            .frame(height: 54)   // avatar 48 + level badge overflow 6
            Text(entry.nickname)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            // v18 Q4:直播间 weekly gift ranking + 观众排行榜统一 coins
            HStack(spacing: 3) {
                Image("coins")
                    .resizable()
                    .frame(width: 12, height: 12)
                Text(formatDiamondCard(entry.costNum))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 100, height: 155)
        .background(
            LinearGradient(colors: [crownColor(rank).opacity(0.6), crownColor(rank).opacity(0)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .offset(y: offsetY)
    }

    private func crownColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(hex: 0xF3DF68)  // 金
        case 2: return Color(hex: 0xEAD9D9)  // 银
        default: return Color(hex: 0xDFA159) // 铜
        }
    }

    private func formatDiamondCard(_ n: Int64) -> String {
        if n >= 1000 {
            let k = Double(n / 100) / 10.0
            return String(format: "%.1fk", k)
        }
        return "\(n)"
    }
}

/// v16 观众列表 row（对齐 H5 userWeeklyRank L358-411 Viewers Tab）
private struct ViewerRow: View {
    let viewer: ViewerEntry
    let onUserTap: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { onUserTap(viewer.userId) } label: {
                AvatarView(urlString: viewer.avatarUrl,
                           size: 40,
                           kind: .user,
                           userId: viewer.userId,
                           disablesTap: true)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewer.nickname)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if viewer.isActiveTycoon { ActiveTycoonBadge(style: .bigRText, size: .small) }
                    if viewer.level > 0 {
                        // 2026-07-10 迁移到公共组件 UserLevelBadge
                        UserLevelBadge(level: viewer.level, size: .small)
                    }
                    if viewer.isVip {
                        VIPBadge(size: .medium)
                    }
                    if let country = viewer.countryId, !country.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "location.fill").font(.system(size: 9))
                            Text(country).font(.system(size: 11))
                        }
                        .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
