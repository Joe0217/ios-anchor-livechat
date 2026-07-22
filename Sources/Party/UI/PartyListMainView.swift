import SwiftUI

/// 派对房大厅新顶层 view（E 增强，2026-07-10）。
///
/// 对齐 H5 用户端 `livechat-h5/src/views/party/index.vue`：
/// - 顶部 3 tab（Party / Follow / Recent）+ 🔍 搜索 + `liveRankBadge` 榜单入口
/// - 语言 pill 横滑（仅 Party tab 显示）
/// - 双榜单卡（PartyRich / Room，仅 Party tab 显示；点击 toast Coming soon）
/// - 内容区 3-tab TabView(.page) 横滑手势切换
/// - 浮动 Create Room 按钮（保留 iOS 主播端约定，不改用 H5 用户端的右上角小图标）
///
/// **架构**：view 只订阅 Store。副作用（拉数据/切语言/dispatch 榜单入口）全走 Store 方法。
struct PartyListMainView: View {
    @ObservedObject var listStore: PartyListStore
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
    let onTapMyRoom: (String) -> Void
    /// v4：传完整对象让 PartyTabRootView 判密码房/其他前置逻辑
    let onTapRoom: (PartyRoomInfo) -> Void
    let onTapSearch: () -> Void
    /// 右上角榜单与首页共用 `HomeRankingView`。
    let onTapRanking: () -> Void

    @State private var activeTab: Int = 0
    @State private var toastTick: UUID?
    @Environment(\.isPartyTabActive) private var isPartyTabActive

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Palette.partyListBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                if activeTab == 0 {
                    languagePillBar
                    rankBanner
                }
                tabContent
            }

            // 未 load 完 myRoom 前不显示按钮（避免"先显 Create 后切 My Room"闪切体验，用户反馈 2026-07-11）
            // P 项目：userType 命中 .party bit 时不渲染按钮（三层防护 UI 层）
            if listStore.didLoadMyRoom && SelfPermissionBridge.shared.canParty {
                createRoomButton
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }

            toast
        }
        .task(id: isPartyTabActive) {
            guard isPartyTabActive else { return }
            // v7（2026-07-14）：.idle **和** .error 都触发拉取 —— 首次失败后 tab 切走再回可自愈
            switch listStore.state {
            case .idle, .error:
                listStore.startInitial()
            default:
                break
            }
            await listStore.loadLanguagesIfNeeded()
            await listStore.loadMyRoomIfNeeded()
        }
        .navigationBarHidden(true)
        // iOS 16 已知：`.navigationBarHidden(true)` 会截断外层 `.safeAreaInset(edge:.bottom)` 传播。
        // 参 PartyRoomListView v3 注释，补一层本地 safeAreaInset 兜底。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: Theme.Metric.tabBarHeight)
        }
    }

    // MARK: - 顶部 3 tab + 图标区

    private var topBar: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 20) {
                ForEach(0..<3, id: \.self) { i in
                    tabButton(index: i, label: tabLabel(i))
                }
            }
            Spacer(minLength: 8)
            searchIcon
            rankBadge
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
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
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Party.searchPlaceholder)
    }

    private var rankBadge: some View {
        Button(action: onTapRanking) {
            Image("liveRankBadge")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 28)
                .padding(.leading, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Party.rankPartyRich)
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
        .frame(height: 44)
    }

    private func languagePill(index: Int, lang: PartyLanguage) -> some View {
        let isActive = listStore.activeLanguageIndex == index
        return Button {
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

    // MARK: - 双榜单卡（对齐 H5 用户端 CDN 背景图 rank1.webp / rank2.webp）

    private var rankBanner: some View {
        HStack(spacing: 12) {
            rankCard(title: L10n.Party.rankPartyRich, cdnURL: "https://img.hnhily.link/mstatic/party/rank1.webp")
            rankCard(title: L10n.Party.rankRoom, cdnURL: "https://img.hnhily.link/mstatic/party/rank2.webp")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// 卡片视觉对齐 H5 index.vue L279-296：CDN 背景图 + 顶部标题 + 底部 top3 头像装饰。
    ///
    /// v17（2026-07-14）：**头像统一走默认图**（不调 top3 接口），装饰框走 H5 CDN
    /// `party-rank1/2/3.webp` —— 榜单入口后续走 H5 webview 链接，主播端不需要 top3 真数据。
    /// 布局对齐 H5：中(第1)32×32/装饰 44 + 左(第2)24×24/装饰 36 + 右(第3)24×24/装饰 36。
    private func rankCard(title: String, cdnURL: String) -> some View {
        Button {
            fireToast()
        } label: {
            ZStack(alignment: .top) {
                CachedAsyncImage(url: URL(string: cdnURL), contentMode: .fill) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                }
                .frame(height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 0.5)
                    .padding(.top, 6)

                rankTop3Placeholders
            }
            .frame(height: 78)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 3 头像占位（默认头像 + H5 CDN 装饰框）
    /// - 中间第 1 名：avatar 32 + headwear 44（headwearRatio 1.375）
    /// - 左第 2 名 / 右第 3 名：avatar 24 + headwear 36（headwearRatio 1.5）
    ///
    /// v17.1（2026-07-14 微调）：三个头像位置逐一 offset 微调；SwiftUI y+ 为向下。
    private var rankTop3Placeholders: some View {
        // AvatarView(urlString: nil) → 显示 defaultUserAvatar 默认图（AvatarView.Kind.user）
        let cdnRank1 = "https://img.hnhily.link/mstatic/party/party-rank1.webp"
        let cdnRank2 = "https://img.hnhily.link/mstatic/party/party-rank2.webp"
        let cdnRank3 = "https://img.hnhily.link/mstatic/party/party-rank3.webp"
        return ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                // 第 2 名（左）：往右 22 + 往下 30
                AvatarView(urlString: nil, size: 24, kind: .user,
                           headwearURL: cdnRank2, headwearRatio: 1.5)
                    .padding(.bottom, 12)
                    .offset(x: 22, y: 30)
                Spacer()
                // 第 3 名（右）：往左 20 + 往下 30
                AvatarView(urlString: nil, size: 24, kind: .user,
                           headwearURL: cdnRank3, headwearRatio: 1.5)
                    .padding(.bottom, 9)
                    .offset(x: -20, y: 30)
            }
            .padding(.horizontal, 20)

            // 第 1 名（中，居中偏下）：往右 3 + 往下 20
            AvatarView(urlString: nil, size: 32, kind: .user,
                       headwearURL: cdnRank1, headwearRatio: 1.375)
                .padding(.bottom, 8)
                .offset(x: 3, y: 20)
        }
    }

    // MARK: - TabView 3 页

    private var tabContent: some View {
        TabView(selection: $activeTab) {
            PartyRoomListContent(store: listStore, onTapRoom: onTapRoom, comingSoonOnEmpty: false)
                .refreshable {
                    // v6 并行：refreshAsync + reloadMyRoom 独立 API 无依赖，用 async let 并发拉，
                    // 下拉转圈时间从 (A+B) ~700-900ms 缩短到 max(A,B) ~500ms
                    // 对齐 H5 onRefresh（getMyPartyRoomInfo + getPartyRoomList；top3 榜单不拉，
                    // 主播端榜单入口后续走 H5 webview 链接，top3 头像用默认图占位）
                    async let a: Void = listStore.refreshAsync()
                    async let b: Void = listStore.reloadMyRoom()
                    _ = await (a, b)
                }
                .tag(0)
            PartyRoomListContent(store: followStore, onTapRoom: onTapRoom, comingSoonOnEmpty: false)
                .refreshable { await followStore.refreshAsync() }
                .tag(1)
            PartyRoomListContent(store: recentStore, onTapRoom: onTapRoom, comingSoonOnEmpty: false)
                .refreshable { await recentStore.refreshAsync() }
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // 横滑手势/按钮点击切 tab 时首次触发对应 store 拉数据（真接口，替换 v1 占位空态）
        // v7：.idle **和** .error 都触发拉取 —— 首次失败后切走再回可自愈（对齐 Party tab .task 逻辑）
        .onChange(of: activeTab) { newValue in
            if newValue == 1 {
                switch followStore.state {
                case .idle, .error: followStore.startInitial()
                default: break
                }
            }
            if newValue == 2 {
                switch recentStore.state {
                case .idle, .error: recentStore.startInitial()
                default: break
                }
            }
        }
    }

    // MARK: - 浮动按钮（v2：Create Room / My Room 分流，对齐 H5 用户端 index.vue L191-207）

    /// 有 myRoom → 显 My Room；无 → 显 Create Room。
    private var createRoomButton: some View {
        Button {
            if let myRoomId = listStore.myRoom?.id {
                onTapMyRoom(myRoomId)
            } else {
                onTapCreate()
            }
        } label: {
            HStack(spacing: 6) {
                if listStore.myRoom != nil {
                    Image(systemName: "house.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityHidden(true)
                } else {
                    Image("partyCreatePlus")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                Text(listStore.myRoom != nil ? L10n.Party.myRoom : L10n.Party.listCreateRoom)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
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
    }

    // MARK: - Toast（顶部胶囊 2s 自消，对齐 LiveTabView.reconnectToast 模式）

    @ViewBuilder
    private var toast: some View {
        if toastTick != nil {
            VStack {
                Text(L10n.Party.comingSoon).toastStyle()
                Spacer()
            }
            .transition(Toast.transition)
            .task(id: toastTick) {
                do {
                    try await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                    try Task.checkCancellation()
                } catch { return }
                toastTick = nil
            }
        }
    }

    private func fireToast() {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastTick = UUID()
        }
    }
}
