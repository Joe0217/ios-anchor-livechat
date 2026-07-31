import SwiftUI

private let partyLobbyRankingScrollCoordinateSpace = "PartyLobbyRankingScroll"

private struct PartyLobbyRankingScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PartyLobbyRankingScrollOffsetMarker: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PartyLobbyRankingScrollOffsetPreferenceKey.self,
                value: proxy.frame(in: .named(partyLobbyRankingScrollCoordinateSpace)).minY
            )
        }
        .frame(height: 0)
    }
}

/// 派对房大厅新顶层 view（E 增强，2026-07-10）。
///
/// 对齐 H5 用户端 `livechat-h5/src/views/party/index.vue`：
/// - 顶部 3 tab（Party / Follow / Recent）+ 🔍 搜索 + `liveRankBadge` 榜单入口
/// - 语言 pill 横滑（仅 Party tab 显示）
/// - Party 首页 banner（仅 Party tab 显示；接口与 H5 `homeBanner.vue` 对齐）
/// - 内容区 3-tab TabView(.page) 横滑手势切换
/// - 右上角 My Room / Create Room 图标（与 H5 互斥展示）
///
/// **架构**：view 只订阅 Store。副作用（拉数据/切语言/dispatch 榜单入口）全走 Store 方法。
struct PartyListMainView: View {
    @ObservedObject var listStore: PartyListStore
    @ObservedObject private var permission = SelfPermissionBridge.shared
    /// NavigationStack push 后大厅仍保活；仅根页真实可见时可以触发奖励引导。
    let isLobbyVisible: Bool
    /// Follow tab store（v2：跟 listStore 同类型，kind=.followed）
    @StateObject private var followStore = PartyListStore(
        service: PartyListServiceLive(),
        kind: .followed
    )
    /// Recent tab store（v2：跟 listStore 同类型，kind=.recent）
    @StateObject private var recentStore = PartyListStore(
        service: PartyListServiceLive(),
        kind: .recent
    )

    let onTapCreate: () -> Void
    /// 已有 myRoom 时点击浮动按钮的路径（v2：跳到自己的房间）
    let onTapMyRoom: (String, PartyRoomEntryPath) -> Void
    /// v4：传完整对象让 PartyTabRootView 判密码房/其他前置逻辑
    let onTapRoom: (PartyRoomInfo, PartyRoomEntryPath) -> Void
    let onTapSearch: () -> Void
    /// 右上角入口与 H5 `/party/rank?type=0` 一致。
    let onTapRanking: () -> Void
    /// H5 Party 首页 banner 的 clickType=3：进入指定 Party 房。
    let onTapBannerRoom: (String, PartyRoomEntryPath) -> Void
    /// 热门房奖励引导确认后，以 `top_room_guide` 来源进入目标房。
    let onEnterTopRoomGuide: (String) -> Void

    @State private var activeTab: Int = 0
    @StateObject private var homeBannerStore = PartyHomeBannerStore()
    @StateObject private var topRoomGuideStore = PartyTopRoomGuideStore()
    @State private var activeBannerPage: H5Page?
    @State private var exposedBannerIDs: Set<String> = []
    /// 每次切换大厅 Tab 或重新激活 Party 页都开启一次新的曝光会话。
    @State private var lobbyExposureSessionID = UUID()
    @State private var reportedLobbyExposureSessionID: UUID?
    @Environment(\.isPartyTabActive) private var isPartyTabActive

    private struct TopRoomGuideTaskKey: Hashable {
        let isPartyTabActive: Bool
        let isLobbyVisible: Bool
        let activeTab: Int
        let canPartyActivities: Bool
    }

    private var canShowValueRankings: Bool {
        permission.canVirtualItems && permission.canGiftSending
    }

    /// Follow 房间依赖账号关注关系；107 只保留 Party 大厅和自身最近访问的 Party 房。
    private var visibleTabIndices: [Int] {
        permission.canProfileSocial ? [0, 1, 2] : [0, 2]
    }

    /// `TabView(.page)` 在动态移除 tag=1 时不能保留一个失效 selection。
    /// binding 在 SwiftUI 回写旧页索引的瞬间也会回退到 Party，onChange 再同步真实状态。
    private var activeTabSelection: Binding<Int> {
        Binding(
            get: { normalizedTabIndex(activeTab) },
            set: { activeTab = normalizedTabIndex($0) }
        )
    }

    private func normalizedTabIndex(_ tabIndex: Int) -> Int {
        visibleTabIndices.contains(tabIndex) ? tabIndex : 0
    }

    var body: some View {
        ZStack {
            Theme.Palette.partyListBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                if activeTab == 0 {
                    languagePillBar
                    if permission.canPartyActivities {
                        partyHomeBanner
                    }
                }
                tabContent
            }

            // 等待 My Room 请求完成，避免先显示 Create Room 再切换为 My Room。
            if listStore.didLoadMyRoom {
                anchorMyRoomButton
                    .transition(.opacity)
            }
        }
        .task(id: isPartyTabActive) {
            guard isPartyTabActive else {
                // 重新回到 Party 页时应产生一个新的大厅曝光，但同一次可见期间只报一次。
                lobbyExposureSessionID = UUID()
                reportedLobbyExposureSessionID = nil
                return
            }
            // 首屏独立资源没有依赖，保持与列表并发；仅 Tab 曝光必须等待列表完成以判断 PK 标识。
            async let loadLanguages: Void = listStore.loadLanguagesIfNeeded()
            async let loadMyRoom: Void = listStore.loadMyRoomIfNeeded()
            async let loadBanners: Void = loadPartyHomeBannersIfAllowed()
            // v7（2026-07-14）：.idle **和** .error 都触发拉取 —— 首次失败后 tab 切走再回可自愈
            switch listStore.state {
            case .idle, .loading, .error:
                await listStore.refreshAsync()
            default:
                break
            }
            reportLobbyTabExposure(for: activeTab, sessionID: lobbyExposureSessionID)
            _ = await (loadLanguages, loadMyRoom, loadBanners)
            reportFirstBannerExposureIfNeeded()
        }
        .task(id: TopRoomGuideTaskKey(
            isPartyTabActive: isPartyTabActive,
            isLobbyVisible: isLobbyVisible,
            activeTab: activeTab,
            canPartyActivities: permission.canPartyActivities
        )) {
            guard permission.canPartyActivities else {
                topRoomGuideStore.clearForDisabledActivities()
                return
            }
            guard isPartyTabActive, isLobbyVisible, activeTab == 0 else { return }
            await topRoomGuideStore.loadIfEligible()
        }
        .navigationBarHidden(true)
        // iOS 16 已知：`.navigationBarHidden(true)` 会截断外层 `.safeAreaInset(edge:.bottom)` 传播。
        // 参 PartyRoomListView v3 注释，补一层本地 safeAreaInset 兜底。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: Theme.Metric.tabBarHeight)
        }
        .sheet(item: $activeBannerPage) { page in
            H5WebSheetView(page: page) { action in
                guard H5NativeActionRouter.shared.dispatch(action) else { return }
                activeBannerPage = nil
            }
        }
        .onChange(of: permission.canPartyActivities) { allowed in
            if !allowed {
                activeBannerPage = nil
                homeBannerStore.clearForDisabledActivities()
                topRoomGuideStore.clearForDisabledActivities()
            } else if isPartyTabActive, activeTab == 0 {
                // 权限 Bridge 首次完成绑定后再加载，避免启动期 deny-by-default 把正常账号
                // 永久停在空 banner；107 始终不会走到此分支。
                Task { await loadPartyHomeBannersIfAllowed() }
            }
        }
        .onChange(of: permission.canProfileSocial, perform: handleProfileSocialPermissionChange)
        .overlay {
            if permission.canPartyActivities, isLobbyVisible, let guide = topRoomGuideStore.guide {
                PartyTopRoomBonusDialog(
                    kind: .enterTopRoom,
                    guide: guide,
                    topRankLimit: topRoomGuideStore.topRankLimit,
                    onDismiss: topRoomGuideStore.dismiss,
                    onConfirm: {
                        topRoomGuideStore.confirmEnter(guide)
                        onEnterTopRoomGuide(guide.roomId)
                    }
                )
            }
        }
    }

    // MARK: - 顶部 3 tab + 图标区

    private var topBar: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 20) {
                ForEach(visibleTabIndices, id: \.self) { i in
                    tabButton(index: i, label: tabLabel(i))
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                searchIcon
                rankBadge
                roomShortcut
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 44)
    }

    private func tabLabel(_ i: Int) -> String {
        switch i {
        case 0: return L10n.Party.tabParty
        case 1: return L10n.Party.tabFollow
        default: return L10n.Party.tabRecent
        }
    }

    private func tabButton(index: Int, label: String) -> some View {
        Button {
            activeTab = index
        } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(activeTab == index ? .white : .white.opacity(0.5))
                // 选中态渐变 indicator；未选中态占位保持高度稳定
                if activeTab == index {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Theme.Palette.brandYellow, Theme.Palette.brandOrange, Theme.Palette.brandPinkA],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: 12, height: 3)
                } else {
                    Color.clear.frame(width: 12, height: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchIcon: some View {
        Button(action: onTapSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Party.searchPlaceholder)
    }

    @ViewBuilder
    private var rankBadge: some View {
        if canShowValueRankings {
            Button {
                guard SelfPermissionBridge.shared.gate(.virtualItems, action: "partyLobbyRanking"),
                      SelfPermissionBridge.shared.gate(.giftSending, action: "partyLobbyRanking") else {
                    return
                }
                onTapRanking()
            } label: {
                Image("liveRankBadge")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Party.rankPartyRich)
        }
    }

    /// H5 用户端右上角互斥入口：已有房间显示 My Room，否则显示 Create Room。
    /// 首次请求未成功前不渲染，不能把网络错误错误地呈现为创建入口。
    @ViewBuilder
    private var roomShortcut: some View {
        if listStore.didLoadMyRoom {
            if let roomId = listStore.myRoom?.id, !roomId.isEmpty {
                Button {
                    onTapMyRoom(roomId, .myRoom)
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Party.myRoom)
            } else if SelfPermissionBridge.shared.canParty {
                Button(action: onTapCreate) {
                    Image("partyCreatePlus")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Party.listCreateRoom)
            }
        }
    }

    /// 主播端大厅底部常驻入口。房间信息未准备好时点击重拉，避免用未知状态直接进创房页。
    private var anchorMyRoomButton: some View {
        VStack {
            Spacer()
            Button(action: openAnchorMyRoom) {
                HStack(spacing: 6) {
                    if listStore.myRoom != nil {
                        Image(systemName: "house.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .accessibilityHidden(true)
                    } else {
                        Image("partyCreatePlus")
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                    }
                    Text(listStore.myRoom != nil ? L10n.Party.myRoom : L10n.Party.listCreateRoom)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                )
                .shadow(color: Theme.Palette.partyCreateBtnA.opacity(0.5), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(listStore.myRoom != nil ? L10n.Party.myRoom : L10n.Party.listCreateRoom)
            .padding(.bottom, 24)
        }
    }

    private func openAnchorMyRoom() {
        if let roomId = listStore.myRoom?.id, !roomId.isEmpty {
            onTapMyRoom(roomId, .myRoom)
            return
        }
        Task {
            await listStore.reloadMyRoom()
            if let roomId = listStore.myRoom?.id, !roomId.isEmpty {
                onTapMyRoom(roomId, .myRoom)
            } else if listStore.didLoadMyRoom {
                onTapCreate()
            }
        }
    }

    // MARK: - 语言 pill 横滑

    private var languagePillBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(listStore.languages.enumerated()), id: \.offset) { idx, lang in
                    languagePill(index: idx, lang: lang)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 60)
    }

    private func languagePill(index: Int, lang: PartyLanguage) -> some View {
        let isActive = listStore.activeLanguageIndex == index
        return Button {
            guard !isActive else { return }
            PartyAnalytics.track(
                "partyRoom_language_click",
                properties: ["language_type": lang.languageName]
            )
            listStore.setLanguage(index: index)
        } label: {
            Text(lang.languageName)
                .font(.system(size: isActive ? 15 : 14, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? .white : .white.opacity(0.5))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    if isActive {
                        Capsule().fill(LinearGradient(
                            colors: [Theme.Palette.brandYellow, Theme.Palette.brandOrange, Theme.Palette.brandPinkA],
                            startPoint: .leading, endPoint: .trailing
                        ))
                    } else {
                        Capsule().fill(Color.white.opacity(0.06))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Party Home Banner

    /// 与首页 Live 列表共用 `LiveBanner` 的轮播、圆角、分页指示器和自动播放行为。
    private var partyHomeBanner: some View {
        LiveBanner(
            items: homeBannerStore.items.map(\.liveBannerItem),
            onTap: handleHomeBannerTap,
            onPageDisplayed: handleHomeBannerDisplayed,
            isActive: isPartyTabActive && activeTab == 0,
            autoplayInterval: 5,
            autoplayResumeDelay: 5
        )
        .padding(.horizontal, Theme.Metric.liveScreenMargin)
        .padding(.bottom, 4)
        .onChange(of: homeBannerStore.items) { _ in
            exposedBannerIDs.removeAll()
            reportFirstBannerExposureIfNeeded()
        }
    }

    private func handleHomeBannerTap(_ item: AppPictureItem) {
        guard SelfPermissionBridge.shared.gate(.partyActivities, action: "partyHomeBanner") else {
            return
        }
        guard let banner = homeBannerStore.items.first(where: { $0.id == item.id }) else { return }
        reportBannerClick(banner)
        if banner.clickType == 3, let roomId = banner.partyRoomId, !roomId.isEmpty {
            onTapBannerRoom(roomId, .partyHomeBanner)
            return
        }
        let rawURL = banner.directUrl ?? banner.gameLink
        guard let rawURL,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return
        }
        activeBannerPage = H5Page.banner(url: url)
    }

    /// 调用层先拒绝 107，Store 仍会在请求前后复核能力，覆盖权限在 await 期间变化的情形。
    private func loadPartyHomeBannersIfAllowed() async {
        guard permission.canPartyActivities else {
            homeBannerStore.clearForDisabledActivities()
            return
        }
        await homeBannerStore.loadIfNeeded()
    }

    private func refreshPartyHomeBannersIfAllowed() async {
        guard permission.canPartyActivities else {
            homeBannerStore.clearForDisabledActivities()
            return
        }
        await homeBannerStore.refresh()
    }

    private func handleHomeBannerDisplayed(_ item: AppPictureItem) {
        guard let banner = homeBannerStore.items.first(where: { $0.id == item.id }) else { return }
        reportBannerExposureIfNeeded(banner)
    }

    // MARK: - TabView 3 页

    private var tabContent: some View {
        TabView(selection: activeTabSelection) {
            PartyRoomListContent(
                store: listStore,
                languages: listStore.languages,
                myRoomID: listStore.myRoom?.id,
                onTapRoom: { onTapRoom($0, .standard) },
                comingSoonOnEmpty: false
            )
                .refreshable {
                    // v6 并行：refreshAsync + reloadMyRoom 独立 API 无依赖，用 async let 并发拉，
                    // 下拉转圈时间从 (A+B) ~700-900ms 缩短到 max(A,B) ~500ms
                    // 对齐 H5 onRefresh：并行刷新我的房间、房间列表和 Party 首页 banner。
                    async let a: Void = listStore.refreshAsync()
                    async let b: Void = listStore.reloadMyRoom()
                    async let c: Void = refreshPartyHomeBannersIfAllowed()
                    _ = await (a, b, c)
                }
                .tag(0)
            if permission.canProfileSocial {
                PartyRoomListContent(
                    store: followStore,
                    languages: listStore.languages,
                    myRoomID: listStore.myRoom?.id,
                    onTapRoom: { onTapRoom($0, .partyFollow) },
                    comingSoonOnEmpty: false
                )
                    .refreshable { await followStore.refreshAsync() }
                    .tag(1)
            }
            PartyRoomListContent(
                store: recentStore,
                languages: listStore.languages,
                myRoomID: listStore.myRoom?.id,
                onTapRoom: { onTapRoom($0, .partyRecent) },
                comingSoonOnEmpty: false
            )
                .refreshable { await recentStore.refreshAsync() }
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Follow 页本身不保留给 107；切换身份时重建 pager，避免 UIKit pager 缓存已移除的 tag=1。
        .id(permission.canProfileSocial)
        // 横滑手势/按钮点击切 tab 时首次触发对应 store 拉数据（真接口，替换 v1 占位空态）
        // v7：.idle **和** .error 都触发拉取 —— 首次失败后切走再回可自愈（对齐 Party tab .task 逻辑）
        .onChange(of: activeTab) { newValue in
            lobbyExposureSessionID = UUID()
            let sessionID = lobbyExposureSessionID
            Task { @MainActor in
                switch newValue {
                case 1:
                    guard permission.canProfileSocial else {
                        activeTab = 0
                        return
                    }
                    switch followStore.state {
                    case .idle, .loading, .error: await followStore.refreshAsync()
                    default: break
                    }
                case 2:
                    switch recentStore.state {
                    case .idle, .loading, .error: await recentStore.refreshAsync()
                    default: break
                    }
                default:
                    switch listStore.state {
                    case .idle, .loading, .error: await listStore.refreshAsync()
                    default: break
                    }
                }
                reportLobbyTabExposure(for: newValue, sessionID: sessionID)
            }
        }
    }

    private func handleProfileSocialPermissionChange(_ allowed: Bool) {
        guard !allowed else { return }
        activeTab = normalizedTabIndex(activeTab)
    }

    private var activeTabName: String {
        switch activeTab {
        case 1: return "Follow"
        case 2: return "Recent"
        default: return "Party"
        }
    }

    private func reportLobbyTabExposure(for tab: Int, sessionID: UUID) {
        guard isPartyTabActive,
              isLobbyVisible,
              activeTab == tab,
              lobbyExposureSessionID == sessionID,
              reportedLobbyExposureSessionID != sessionID else {
            return
        }
        let rooms: [PartyRoomInfo]
        let listState: PartyListStore.State
        switch tab {
        case 1:
            rooms = followStore.displayedRooms
            listState = followStore.state
        case 2:
            rooms = recentStore.displayedRooms
            listState = recentStore.state
        default:
            rooms = listStore.displayedRooms
            listState = listStore.state
        }
        // 初始请求未完成时 displayedRooms 为空，无法判断 PK 标识；等到首次列表状态完成后再上报。
        switch listState {
        case .idle, .loading, .error:
            return
        case .loaded, .loadingMore, .refreshing, .pageError:
            break
        }
        var properties: [String: Any] = ["tab_type": activeTabName]
        if rooms.contains(where: { ($0.pkStatus ?? 0) > 0 }) {
            properties["logotype"] = "pk"
        }
        PartyAnalytics.track("partyRoom_tab_view", properties: properties)
        reportedLobbyExposureSessionID = sessionID
    }

    private func reportFirstBannerExposureIfNeeded() {
        guard permission.canPartyActivities,
              isPartyTabActive, activeTab == 0,
              let banner = homeBannerStore.items.first else { return }
        reportBannerExposureIfNeeded(banner)
    }

    private func reportBannerExposureIfNeeded(_ banner: PartyHomeBanner) {
        guard permission.canPartyActivities,
              isPartyTabActive, activeTab == 0,
              exposedBannerIDs.insert(banner.id).inserted else { return }
        PartyAnalytics.track("b_banner_party_view", properties: bannerTrackingProperties(banner))
        PartyAnalytics.track("b_activity_view", properties: activityTrackingProperties(banner))
    }

    private func reportBannerClick(_ banner: PartyHomeBanner) {
        PartyAnalytics.track("b_banner_party_click", properties: bannerTrackingProperties(banner))
        PartyAnalytics.track("b_activity_click", properties: activityTrackingProperties(banner))
    }

    private func bannerTrackingProperties(_ banner: PartyHomeBanner) -> [String: Any] {
        [
            "bannerid": banner.id,
            "type": bannerAnalyticsType(banner.clickType),
        ]
    }

    private func activityTrackingProperties(_ banner: PartyHomeBanner) -> [String: Any] {
        let queryItems = banner.directUrl.flatMap(URLComponents.init(string:))?.queryItems ?? []
        func queryValue(_ name: String) -> String {
            queryItems.first(where: { $0.name == name })?.value ?? ""
        }
        return [
            "name": banner.activityName ?? banner.name ?? "",
            "type": "roomlist",
            "taskid": queryValue("taskId"),
            "activity_id": queryValue("activityId"),
            "lotteryId": queryValue("lotteryId"),
        ]
    }

    private func bannerAnalyticsType(_ clickType: Int) -> String {
        switch clickType {
        case 1: return "game"
        case 2: return "rechargeservice"
        default: return "internal"
        }
    }

}

// MARK: - Lobby ranking

/// H5 `/party/rank` 两个榜单的共享状态。数据按「榜单类型 + 时间 + 当前/上一期」分桶，
/// 离开页面时由 view-owned store 自动释放，避免跨账号复用缓存。
@MainActor
private final class PartyLobbyRankingStore: ObservableObject {
    @Published private(set) var payloads: [String: PartyLobbyRankResponse] = [:]
    @Published private(set) var loadingKeys: Set<String> = []
    private var permissionGeneration = 0

    private var canUseValueRankings: Bool {
        SelfPermissionBridge.shared.canVirtualItems && SelfPermissionBridge.shared.canGiftSending
    }

    func payload(kind: PartyLobbyRankingKind, timeframe: PartyLobbyRankingTimeframe, period: PartyLobbyRankingPeriod) -> PartyLobbyRankResponse? {
        guard canUseValueRankings else { return nil }
        return payloads[key(kind: kind, timeframe: timeframe, period: period)]
    }

    func isLoading(kind: PartyLobbyRankingKind, timeframe: PartyLobbyRankingTimeframe, period: PartyLobbyRankingPeriod) -> Bool {
        guard canUseValueRankings else { return false }
        return loadingKeys.contains(key(kind: kind, timeframe: timeframe, period: period))
    }

    func load(kind: PartyLobbyRankingKind, timeframe: PartyLobbyRankingTimeframe, period: PartyLobbyRankingPeriod, force: Bool = false) async {
        guard canUseValueRankings else {
            clearForDisabledValueRankings()
            return
        }
        let requestKey = key(kind: kind, timeframe: timeframe, period: period)
        if !force, payloads[requestKey] != nil || loadingKeys.contains(requestKey) { return }
        loadingKeys.insert(requestKey)
        let requestPermissionGeneration = permissionGeneration
        defer { loadingKeys.remove(requestKey) }
        do {
            let response: PartyLobbyRankResponse
            switch kind {
            case .partyRich:
                response = try await PartyAPI.partyRichRank(rankType: timeframe.rawValue, periodType: period.rawValue)
            case .room:
                response = try await PartyAPI.partyLobbyRoomRank(rankType: timeframe.rawValue, periodType: period.rawValue)
            }
            guard requestPermissionGeneration == permissionGeneration else { return }
            guard canUseValueRankings else {
                clearForDisabledValueRankings()
                return
            }
            payloads[requestKey] = response
        } catch {
            guard requestPermissionGeneration == permissionGeneration else { return }
            guard canUseValueRankings else {
                clearForDisabledValueRankings()
                return
            }
            if Task.isCancelled || GlobalErrorBannerNotify.isCancellation(error) { return }
            AppLogger.party.error("[PartyLobbyRank] load \(requestKey, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 权限撤销时清缓存并使已开始的请求失效，避免导航恢复后出现旧榜单数据。
    func clearForDisabledValueRankings() {
        guard !canUseValueRankings else { return }
        permissionGeneration &+= 1
        payloads = [:]
        loadingKeys = []
    }

    private func key(kind: PartyLobbyRankingKind, timeframe: PartyLobbyRankingTimeframe, period: PartyLobbyRankingPeriod) -> String {
        "\(kind.rawValue)-\(timeframe.rawValue)-\(period.rawValue)"
    }
}

@MainActor
private final class PartyHomeBannerStore: ObservableObject {
    @Published private(set) var items: [PartyHomeBanner] = []
    private var didLoad = false
    private var requestToken = UUID()

    func loadIfNeeded() async {
        guard canLoadPartyActivities else {
            clearForDisabledActivities()
            return
        }
        guard !didLoad else { return }
        await load()
    }

    func refresh() async {
        guard canLoadPartyActivities else {
            clearForDisabledActivities()
            return
        }
        await load(force: true)
    }

    /// 权限撤销时清旧内容并失效飞行请求，防止 await 返回后把活动 banner 写回内存。
    func clearForDisabledActivities() {
        requestToken = UUID()
        didLoad = false
        items = []
    }

    private func load(force: Bool = false) async {
        guard canLoadPartyActivities else {
            clearForDisabledActivities()
            return
        }
        guard force || !didLoad else { return }
        let token = UUID()
        requestToken = token
        do {
            let result = try await PartyAPI.partyHomeBanners()
            guard requestToken == token, !Task.isCancelled, canLoadPartyActivities else { return }
            items = result.filter { $0.picUrl?.isEmpty == false }
            didLoad = true
        } catch {
            guard requestToken == token, !Task.isCancelled else { return }
            AppLogger.party.error("[PartyHomeBanner] load failed: \(String(describing: error), privacy: .public)")
        }
    }

    private var canLoadPartyActivities: Bool {
        SelfPermissionBridge.shared.canPartyActivities
    }
}


private enum PartyLobbyRankingTimeframe: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return L10n.PartyRoom.rankTabDaily
        case .week: return L10n.commonWeekly
        case .month: return L10n.commonMonthly
        }
    }
}

private enum PartyLobbyRankingPeriod: String {
    case current = "CURRENT"
    case last = "LAST"
}

/// Party Rich / Room 共用 Charm 型榜单结构。Couple 的双人名片和奖励结构不同，保持独立实现。
struct PartyLobbyRankingView: View {
    let initialKind: PartyLobbyRankingKind
    let onOpenRoom: (String) -> Void

    @StateObject private var store = PartyLobbyRankingStore()
    @State private var kind: PartyLobbyRankingKind
    @State private var timeframe: PartyLobbyRankingTimeframe = .day
    @State private var period: PartyLobbyRankingPeriod = .current
    @State private var showRules = false
    @State private var rewardEntry: PartyLobbyRewardPresentation?
    @State private var userCard: UserCardPresentation?
    @State private var isNavigationBarScrolled = false
    @State private var openedAt: Date?
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @Environment(\.dismiss) private var dismiss

    init(initialKind: PartyLobbyRankingKind, onOpenRoom: @escaping (String) -> Void) {
        self.initialKind = initialKind
        self.onOpenRoom = onOpenRoom
        _kind = State(initialValue: initialKind)
    }

    private var payload: PartyLobbyRankResponse? {
        store.payload(kind: kind, timeframe: timeframe, period: period)
    }

    private var canShowValueRankings: Bool {
        permission.canVirtualItems && permission.canGiftSending
    }

    var body: some View {
        Group {
            if canShowValueRankings {
                rankingContent
            } else {
                Color.clear.onAppear(perform: dismissIfValueRankingsAreDisabled)
            }
        }
        .onChange(of: canShowValueRankings, perform: handleValueRankingPermissionChange)
    }

    private var rankingContent: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color(hex: kind == .partyRich ? 0x957654 : 0x3B5D45).ignoresSafeArea()
                if kind == .partyRich {
                    Image("homeRankCharmBackground")
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: backgroundHeight(topSafeArea: proxy.safeAreaInsets.top), alignment: .top)
                        .clipped()
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                } else {
                    Image("partyLobbyRoomBackground")
                        .resizable()
                        .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: backgroundHeight(topSafeArea: proxy.safeAreaInsets.top), alignment: .top)
                    .clipped()
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                }

                PartyStandardRankingBody(
                    kind: kind,
                    timeframe: $timeframe,
                    period: $period,
                    payload: payload,
                    isLoading: store.isLoading(kind: kind, timeframe: timeframe, period: period),
                    onTapEntry: tapEntry,
                    onTapRewards: { entry in rewardEntry = PartyLobbyRewardPresentation(entry: entry, kind: kind) },
                    onRefresh: { await store.load(kind: kind, timeframe: timeframe, period: period, force: true) }
                )
            }
        }
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
                HStack(spacing: 26) {
                    ForEach(PartyLobbyRankingKind.allCases) { item in
                        Button { kind = item } label: {
                            Text(item.title)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(kind == item ? .white : .white.opacity(0.5))
                                .padding(.vertical, 8)
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
            }
        }
        .task(id: requestKey) {
            await store.load(kind: kind, timeframe: timeframe, period: period)
        }
        // H5 在首次进入、榜单类型或统计周期切换时上报浏览；周期切换不影响该事件。
        .task(id: "\(kind.rawValue)-\(timeframe.rawValue)") {
            PartyAnalytics.track(
                "partyRich_Rank_view",
                properties: [
                    "rank_type": kind == .partyRich ? "PartyRich" : "Room",
                    "cycle": timeframe.rawValue,
                ]
            )
        }
        .onAppear {
            if openedAt == nil {
                openedAt = Date()
            }
        }
        .onDisappear {
            guard let openedAt else { return }
            PartyAnalytics.track(
                "partyRich_leave",
                properties: ["duration": max(0, Int(Date().timeIntervalSince(openedAt)))]
            )
            self.openedAt = nil
        }
        .onChange(of: kind) { _ in
            timeframe = .day
            period = .current
        }
        .onPreferenceChange(PartyLobbyRankingScrollOffsetPreferenceKey.self, perform: updateNavigationBar)
        .userCardSheet(item: $userCard)
        .overlay {
            if showRules {
                PartyLobbyRankRules(kind: kind, timeframe: timeframe) { showRules = false }
            }
            if let rewardEntry {
                PartyLobbyRankRewardSheet(presentation: rewardEntry) { self.rewardEntry = nil }
            }
        }
    }

    private func handleValueRankingPermissionChange(_ allowed: Bool) {
        guard !allowed else { return }
        dismissIfValueRankingsAreDisabled()
    }

    private func dismissIfValueRankingsAreDisabled() {
        guard !canShowValueRankings else { return }
        store.clearForDisabledValueRankings()
        showRules = false
        rewardEntry = nil
        userCard = nil
        dismiss()
    }

    private var requestKey: String { "\(kind.rawValue)-\(timeframe.rawValue)-\(period.rawValue)" }

    private func backgroundHeight(topSafeArea: CGFloat) -> CGFloat {
        // Party 比首页普通榜多了倒计时/当前期切换行，背景需随列表起点下移。
        let topChrome = max(topSafeArea, 44) + 44
        let partyListTop: CGFloat = 54 + 33 + 250 - 12
        return topChrome + partyListTop + 20
    }

    private func updateNavigationBar(_ offset: CGFloat) {
        let shouldShowBackground = offset < -8
        guard shouldShowBackground != isNavigationBarScrolled else { return }
        isNavigationBarScrolled = shouldShowBackground
    }

    private func tapEntry(_ entry: PartyRankEntry) {
        guard canShowValueRankings else { return }
        switch kind {
        case .partyRich:
            guard !entry.userId.isEmpty else { return }
            userCard = UserCardPresentation(preview: entry.userCardPreview)
        case .room:
            if let roomId = entry.roomId, !roomId.isEmpty { onOpenRoom(roomId) }
        }
    }
}

/// 标准榜单主体：Top3 + 4+ 列表 + 我的排名。后续 Charm 类榜单可以只替换数据适配器继续复用。
private struct PartyStandardRankingBody: View {
    let kind: PartyLobbyRankingKind
    @Binding var timeframe: PartyLobbyRankingTimeframe
    @Binding var period: PartyLobbyRankingPeriod
    let payload: PartyLobbyRankResponse?
    let isLoading: Bool
    let onTapEntry: (PartyRankEntry) -> Void
    let onTapRewards: (PartyRankEntry) -> Void
    let onRefresh: () async -> Void

    private var entries: [PartyRankEntry] { payload?.rankList ?? [] }
    private var charmMembers: [HomeRankingMember] { entries.map(asCharmMember) }
    private var charmMine: HomeRankingMember? { payload?.myRank.map(asCharmMember) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                PartyLobbyRankingScrollOffsetMarker()
                VStack(spacing: 0) {
                    timeframeControl
                    periodAndCountdown
                    HomeRankingTopThree(
                        members: charmMembers,
                        category: .charm,
                        onTap: openAdaptedMember
                    )
                    listSection(minimumHeight: max(124, geometry.size.height - 337))
                        .padding(.top, -12)
                }
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: partyLobbyRankingScrollCoordinateSpace)
            .scrollIndicators(.hidden)
            .refreshable { await onRefresh() }
        }
        .overlay(alignment: .bottom) {
            HomeRankingMineRow(member: charmMine, category: .charm, onTap: openAdaptedMember)
                .padding(.bottom, -20)
        }
    }

    private var timeframeControl: some View {
        HStack(spacing: 0) {
            ForEach(PartyLobbyRankingTimeframe.allCases) { value in
                Button { timeframe = value } label: {
                    Text(value.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if timeframe == value {
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
            }
        }
        .padding(2)
        .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, 12)
    }

    private var periodAndCountdown: some View {
        HStack {
            if period == .current, let duration = payload?.duration, duration > 0 {
                PartyRankCountdown(seconds: duration)
            }
            Spacer()
            Button { period = period == .current ? .last : .current } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text(periodLabel)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.3)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var periodLabel: String {
        switch (period, timeframe) {
        case (.current, .day): return L10n.PartyRoom.rankPeriodToday
        case (.last, .day): return L10n.PartyRoom.rankPeriodYesterday
        case (.current, .week): return L10n.Party.rankPeriodThisWeek
        case (.last, .week): return L10n.Party.rankPeriodLastWeek
        case (.current, .month): return L10n.Party.rankPeriodThisMonth
        case (.last, .month): return L10n.Party.rankPeriodLastMonth
        }
    }

    @ViewBuilder
    private func listSection(minimumHeight: CGFloat) -> some View {
        if entries.count <= 3 {
            ZStack {
                // 空态由外层占满 Top3 以下的可用区域，公共空态始终居中。
                HomeRankingList(
                    members: [],
                    category: .charm,
                    onTap: openAdaptedMember,
                    minimumHeight: minimumHeight,
                    bottomContentInset: 50,
                    hasMore: false,
                    isLoadingMore: false,
                    pageError: nil,
                    onLoadMore: {}
                )
                if isLoading {
                    HomeRankingLoadingOverlay()
                }
            }
        } else {
            HomeRankingList(
                members: charmMembers,
                category: .charm,
                onTap: openAdaptedMember,
                minimumHeight: minimumHeight,
                bottomContentInset: 50,
                hasMore: false,
                isLoadingMore: false,
                pageError: nil,
                onLoadMore: {}
            )
        }
    }

    private func asCharmMember(_ entry: PartyRankEntry) -> HomeRankingMember {
        let identity = kind == .room ? (entry.roomId ?? entry.userId) : entry.userId
        return HomeRankingMember(
            userId: identity,
            nickname: entry.nickname ?? L10n.anonymous,
            icon: entry.avatar,
            countryId: entry.countryId,
            age: entry.age,
            value: compactValue(entry.rankValue),
            rank: entry.rankIndex,
            isRanked: (entry.rankIndex ?? 0) > 0
        )
    }

    private func compactValue(_ value: Int?) -> String {
        let number = value ?? 0
        if number >= 1_000_000 { return String(format: "%.2fM", Double(number) / 1_000_000) }
        if number >= 1_000 { return String(format: "%.2fK", Double(number) / 1_000) }
        return "\(number)"
    }

    private func openAdaptedMember(_ member: HomeRankingMember?) {
        guard let identity = member?.userId, !identity.isEmpty else { return }
        if kind == .room, let entry = entries.first(where: { ($0.roomId ?? $0.userId) == identity }) {
            onTapEntry(entry)
        } else if let entry = entries.first(where: { $0.userId == identity }) {
            onTapEntry(entry)
        }
    }
}

private struct PartyRankCountdown: View {
    private let endDate: Date

    init(seconds: Int) {
        endDate = Date().addingTimeInterval(TimeInterval(max(0, seconds)))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remain = max(0, Int(endDate.timeIntervalSince(context.date)))
            let days = remain / 86_400
            let hours = (remain % 86_400) / 3_600
            let minutes = (remain % 3_600) / 60
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(String(format: "%02dD:%02dH:%02dM", days, hours, minutes))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.3)))
        }
    }
}

private struct PartyLobbyRewardPresentation: Identifiable {
    let entry: PartyRankEntry
    let kind: PartyLobbyRankingKind
    var id: String { "\(kind.rawValue)-\(entry.id)" }
}

private struct PartyLobbyRankRewardSheet: View {
    let presentation: PartyLobbyRewardPresentation
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea().onTapGesture(perform: onDismiss)
            VStack(spacing: 16) {
                Text(presentation.kind.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(presentation.entry.rewardConfig) { reward in
                        VStack(spacing: 6) {
                            CachedAsyncImage(url: reward.itemSmallImg.flatMap(URL.init(string:)),
                                             contentMode: .fit,
                                             cdn: (.gift, .fit)) {
                                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1))
                            }
                            .frame(width: 54, height: 54)
                            Text(reward.itemName ?? "-")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(Color(hex: 0x251A3A))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct PartyLobbyRankRules: View {
    let kind: PartyLobbyRankingKind
    let timeframe: PartyLobbyRankingTimeframe
    let onDismiss: () -> Void
    @State private var dynamicRuleImageURL: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea().onTapGesture(perform: onDismiss)
            VStack(spacing: 16) {
                Text(L10n.Party.rankRulesTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                if timeframe == .day {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ruleLines, id: \.self) { line in
                            Text(line)
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.leading)
                } else if isLoading {
                    ProgressView().tint(.white).frame(height: 120)
                } else if let dynamicRuleImageURL {
                    CachedAsyncImage(url: URL(string: dynamicRuleImageURL), contentMode: .fit) {
                        Color.clear
                    }
                    .frame(maxHeight: 360)
                }
                Button(L10n.commonOK, action: onDismiss)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Capsule().fill(Color(hex: 0x8515FF)))
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(Color(hex: 0x251A3A))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .task(id: "\(kind.rawValue)-\(timeframe.rawValue)") {
            guard timeframe != .day else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                dynamicRuleImageURL = try await PartyAPI.partyLobbyRankRuleContent(belongAct: belongAct)
            } catch {
                AppLogger.party.error("[PartyLobbyRank] rule image failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private var ruleLines: [String] {
        switch kind {
        case .partyRich:
            return [L10n.Party.rankPartyRichRule1, L10n.Party.rankPartyRichRule2, L10n.Party.rankPartyRichRule3]
        case .room:
            return [L10n.Party.rankRoomRule1, L10n.Party.rankRoomRule2, L10n.Party.rankRoomRule3]
        }
    }

    private var belongAct: Int {
        switch (kind, timeframe) {
        case (.partyRich, .week): return 5
        case (.partyRich, .month): return 6
        case (.room, .week): return 3
        case (.room, .month): return 4
        case (_, .day): return 0
        }
    }
}
