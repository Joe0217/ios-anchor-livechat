import SwiftUI

/// Home 默认子页：直播流广场 + 顶部 4 tab 横滑联动 (trial #1 A-spec §3.1 / §6A.2)。
///
/// 重构记录 (v2 trial #1)：
/// - 顶部 4 tab 切换从 `switch` 改为 `TabView(.page)` 支持横滑联动
/// - 按主播段位派生 tab 顺序 (S 级 / 非 S 级)，段位异步加载竞态处理 §5.12
/// - Circle case 接入 `CircleView`（含内层 3 子 tab + Moment 子 tab 业务）
struct LiveTabView: View {
    /// trial step 3 真集成反悔：spec §3.1 / §5.12 原本"段位未就绪 loading 占位"
    /// 真接口拉慢/失败时变成永久 dead-state。改为**默认按 S 级兜底**，info 到达后 onChange 矫正。
    @StateObject private var homeStore = HomeTopTabStore(initialIsSLevel: true)
    @StateObject private var viewModel = LiveTabViewModel()
    /// List 子页 VM 在父级持有，避免 .list 分支被销毁时丢失 segment / scroll 状态。
    /// 网络错误兜底文案走 L10n（ar/tr 用户感知一致）；ViewModel 内 default 是英文，仅供 HilyTests 使用。
    @StateObject private var listViewModel = LiveListViewModel(
        networkErrorFallback: L10n.userProfileNetworkError
    )
    /// Live 子页广场 VM（同样在父级持有以撑 keep-alive 体感）
    @StateObject private var streamViewModel = LiveStreamViewModel(
        networkErrorFallback: L10n.userProfileNetworkError
    )

    /// 单例观察：段位变化触发 applyTier
    @ObservedObject private var anchorInfoStore = AnchorInfoStore.shared
    /// Banner 单例：subscribe 完整 store（当前只订 type=2 一桶；J 里程碑加其他 type 时
    /// 需按 `.claude/rules/swiftui-keepalive-publisher-isolation.md` 抽 bridge）
    @ObservedObject private var appPictureStore = AppPictureStore.shared
    /// 跑马灯单例（H5 `getLiveMarqueeListData`）
    @ObservedObject private var giftMarqueeStore = GiftMarqueeStore.shared

    /// MainTabView 注入：home tab 是否被用户选中。
    /// 用于 List 子页 lazy load —— keep-alive 架构下 view tree 永久持有，
    /// .task 在 app 启动即触发；改用此信号 + currentOuter 组合判定首次进入触发。
    @Environment(\.isHomeTabActive) private var isHomeTabActive
    /// 首页右上角榜单入口。由 MainTabView 的 home NavigationStack 承接 push。
    @Environment(\.openHomeLeaderboard) private var openHomeLeaderboard
    /// 首页 banner H5 跳转入口。由 MainTabView 的 home NavigationStack 承接 push。
    @Environment(\.openHomeBanner) private var openHomeBanner

    /// reconnect toast 展示态（对齐 H5 `refreshIMOnline` 后 1s 弹的 toast）。
    /// LiveTopBar 点刷新 → OnlineStatusStore.refreshToastTick 变化 → 本 view onChange 抬起。
    @State private var showReconnectToast: Bool = false
    @ObservedObject private var onlineStatus = OnlineStatusStore.shared

    /// Home 4 tab 跨模块导航总线（Work Match 点击时切 Match top tab 用）
    @ObservedObject private var navBus = HomeNavigationBus.shared
    /// P 项目权限管理 v2：观察 canCall 变化触发 top tab 重派生（filter .match）
    @ObservedObject private var permission = SelfPermissionBridge.shared

    /// scenePhase 用于"onResume 静默检查"（对齐安卓 HomeHomeFragment.onResume）。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                backgroundLayer
            }
            .overlay(alignment: .top) { reconnectToast }
            .overlay {
                if onlineStatus.showSetToBusyDialog {
                    SetToBusyDialog(
                        onGoLive: { onlineStatus.showSetToBusyDialog = false /* TODO: 接 WorkRoute.liveSettings 跨 tab 跳转 */ },
                        onGoMatch: { onlineStatus.showSetToBusyDialog = false; homeStore.tapOuter(.match) },
                        onDismiss: { onlineStatus.showSetToBusyDialog = false }
                    )
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: onlineStatus.showSetToBusyDialog)
            .onChange(of: onlineStatus.refreshToastTick) { tick in
                guard tick != nil else { return }
                showReconnectToast = true
            }
            // Work toolMatch 请求切到 Home Match top tab（对齐首页 Match 入口）
            .onChange(of: navBus.pendingTopTab) { pending in
                guard let tab = pending else { return }
                homeStore.tapOuter(tab)
                navBus.pendingTopTab = nil
            }
            // scenePhase → .active：对齐安卓 onResume 静默检查（showToast=false, doAction=false）
            // 走 triggerCheckForcedBusy 统一到 activeCheckTask 串行化（审查报告-202607061550 必修-2）
            .onChange(of: scenePhase) { newPhase in
                guard newPhase == .active, isHomeTabActive else { return }
                onlineStatus.triggerCheckForcedBusy(showToast: false, doAction: false)
            }
            .preferredColorScheme(.dark)
            .onAppear {
                Task { @MainActor in
                    await anchorInfoStore.loadIfNeeded()
                    reapplyTier()
                }
                // initial state 已满足加载条件时的首次触发——
                // S 级默认 currentOuter=.live、非 S 级默认 currentOuter=.list，
                // `.onChange` 契约不在初始挂载 fire，需要 onAppear 显式补触发一次
                // 否则默认落在的子 tab 会永远停在 loadState=.idle → 视觉上"一直转圈"
                triggerStreamLazyLoadIfNeeded()
                triggerListLazyLoadIfNeeded()
            }
            // 监听派生 Bool 而非 AnchorInfo (后者未 Equatable 不能 onChange)：
            // hasLoadedTier  false→true 触发首次 applyTier；
            // isSLevelAnchor 变化（极少：段位远程刷新）触发重派生。
            .onChange(of: anchorInfoStore.hasLoadedTier) { _ in reapplyTier() }
            .onChange(of: anchorInfoStore.isSLevelAnchor) { _ in reapplyTier() }
            // P 项目权限管理 v2：canCall 变化时（切账号 / DebugPermissionOverride）重新派生 top tab
            .onChange(of: permission.canCall) { _ in reapplyTier() }
            // code-review Finding 3：permission.isLoaded 变化也要触发（避免冷启动 permission=false 首帧摘 Match tab 再补的闪烁）
            .onChange(of: permission.isLoaded) { _ in reapplyTier() }
            // Live / List 子页 lazy load：keep-alive 架构下不在 view tree mount 时触发，
            // 仅在 home 真正 active + 当前 outer tab 匹配 + 未加载过时触发。
            .onChange(of: isHomeTabActive) { _ in
                triggerListLazyLoadIfNeeded()
                triggerStreamLazyLoadIfNeeded()
            }
            .onChange(of: homeStore.currentOuter) { _ in
                triggerListLazyLoadIfNeeded()
                triggerStreamLazyLoadIfNeeded()
            }
    }

    /// 触发 List 首页加载——三重守卫：
    /// P 权限管理 · 统一 applyTier 入口（code-review Finding 3/7 消除 4 处 3-line 复制块）。
    ///
    /// **只 gate `permission.isLoaded`**（deny-by-default 权限侧）；`hasLoadedTier` 不 gate ——
    /// tier 未 loaded 时用假设 `isSLevel: true`（默认 S 级顺序，仍含 .match）。
    ///
    /// **反例（前一版双 gate 导致的 bug）**：dev 环境 hasLoadedTier 长时间 false（AnchorInfoStore
    /// 未拉到 level）→ 双 gate 永久 early return → permission override 切换（101 屏通话+匹配）
    /// 后 availableOrder 保持 init 时的 optimistic order 不更新 → Match tab 无法消失。
    /// 用户实测发现：Work 页 Match cell 正确隐藏（直接读 canCall @Published），首页 Match tab
    /// 仍显示（依赖 reapplyTier → hasLoadedTier gate 挡）。修法：解耦 tier gate。
    private func reapplyTier() {
        guard permission.isLoaded else { return }
        // tier 未 loaded 时用默认 S 级顺序（含 .match）；tier loaded 后正确的 isSLevel 会再触发一次 apply
        let isSLevel = anchorInfoStore.hasLoadedTier ? anchorInfoStore.isSLevelAnchor : true
        homeStore.applyTier(isSLevel: isSLevel, canCall: permission.canCall)
    }

    /// 1. home tab 必须 active（避免启动即预热）
    /// 2. 当前 outer tab 必须是 .list（避免用户在 live/circle 时浪费请求）
    /// 3. loadState 必须是 .idle（避免重复加载——切走再回不重发，对齐 keep-alive 体感）
    private func triggerListLazyLoadIfNeeded() {
        guard isHomeTabActive,
              homeStore.currentOuter == .list,
              case .idle = listViewModel.loadState else { return }
        Task { await listViewModel.loadFirstPage() }
    }

    /// 触发 Live 广场首页加载——与 List 同款三重守卫。
    private func triggerStreamLazyLoadIfNeeded() {
        guard isHomeTabActive,
              homeStore.currentOuter == .live,
              case .idle = streamViewModel.loadState else { return }
        Task { await streamViewModel.loadFirstPage() }
    }

    /// 整页背景：底层径向晕染切图 + 上方渐变叠层增加层次感。
    /// 仅顶部扩展到状态栏，**不**扩到底部，避免覆盖 MainTabView 的 TabBar。
    /// 4 个子 tab 共用同一张顶部背景图，避免切换时背景闪烁。
    private var backgroundLayer: some View {
        ZStack {
            Theme.Palette.liveBottomDark
            Image("liveBackground")
                .resizable()
                .scaledToFill()
                .opacity(0.95)
            LinearGradient(
                colors: [Color.clear, Theme.Palette.liveBottomDark.opacity(0.85)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .clipped()
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var content: some View {
        // 默认按 S 级兜底 → currentOuter / availableOrder 永远非 nil
        // info 到达后 onChange 矫正顺序（保留 userSelected 业务语义）
        if let order = homeStore.availableOrder, let current = homeStore.currentOuter {
            tabContent(order: order, current: current)
        } else {
            // 防御性 — 理论不进入（initialIsSLevel: true 保证已就绪）
            EmptyView()
        }
    }

    /// 渲染 LiveTopBar + TabView(.page) + 浮动按钮（右下）。
    /// 浮动按钮按 outer tab 分流：live → QuickGoLive，其余暂无（对齐 H5 FloatButtons showFloatButtons 值切分）
    private func tabContent(order: [HomeTopTab], current: HomeTopTab) -> some View {
        VStack(spacing: 0) {
            LiveTopBar(
                selected: Binding(
                    get: { current },
                    set: { homeStore.tapOuter($0) }
                ),
                availableOrder: order,
                rankCount: viewModel.rankCount,
                onRankTap: {
                    openHomeLeaderboard.perform(current == .circle ? .points : .ranking)
                }
            )
            .padding(.top, 6)

            TabView(selection: Binding(
                get: { current },
                set: { homeStore.tapOuter($0) }
            )) {
                // isActive 组合两条件：Home tab 被选中 + outer tab 是 .live——切走任一都停 autoplay
                liveStream(isActive: isHomeTabActive && current == .live).tag(HomeTopTab.live)
                LiveListView(viewModel: listViewModel).tag(HomeTopTab.list)
                // L 里程碑：Match tab 实装（v3 spec §4.1）。placeholderTab → MatchTabView。
                MatchTabView(
                    isActive: isHomeTabActive
                        && current == .match
                        && permission.canHomeDiscovery
                        && permission.canCall
                )
                .tag(HomeTopTab.match)
                // CircleView 接收 isActive，在 outer tab 切到 .circle 时才触发 sub store 的 lazy load
                CircleView(isActive: current == .circle).tag(HomeTopTab.circle)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .overlay(alignment: .bottomTrailing) {
            floatingButtons(for: current)
        }
    }

    /// 右下角浮动按钮群。当前只有 Live 子 tab 的 QuickGoLive；
    /// H5 侧还有 CGoMatch / BeautyProgress / CNewbieTask，按里程碑逐步接入。
    /// bottom 180pt：从 tabbar 顶往上抬高，避免被视觉遮挡（用户要求）。
    @ViewBuilder
    private func floatingButtons(for current: HomeTopTab) -> some View {
        // P 项目权限管理：canCall/canLive 命中 userType 黑名单时对应浮动按钮不渲染
        if current == .live, SelfPermissionBridge.shared.canLive {
            QuickGoLiveButton()
                .padding(.trailing, 12)
                .padding(.bottom, 180)
                .transition(.opacity)
        } else if current == .match, SelfPermissionBridge.shared.canCall {
            // L 里程碑：Match tab 浮动开关（v3 spec §4.2）· .call bit 覆盖匹配
            CGoMatchButton(store: MatchStore.shared)
                .padding(.trailing, Theme.Metric.matchButtonTrailingInset)
                .padding(.bottom, Theme.Metric.matchButtonBottomInset)
                .transition(.opacity)
        }
    }

    /// Live 子 tab 主体：跑马灯(接口) + banner(接口) + 广场卡片网格(接口)，可纵向滚动 + 下拉刷新。
    /// 下拉刷新只刷广场（对齐 H5：`listRefresh` 只调 `getListData`；跑马灯/banner 走启动预热）。
    /// - Parameter isActive: `isHomeTabActive && current == .live`；仅真可见时跑马灯/Banner 才 autoplay
    private func liveStream(isActive: Bool) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                LiveNoticeBar(items: giftMarqueeStore.items, isActive: isActive)
                    .padding(.horizontal, Theme.Metric.liveScreenMargin)
                    .padding(.top, giftMarqueeStore.items.isEmpty ? 0 : 10)

                LiveBanner(items: homeBannerItems, onTap: openBanner, isActive: isActive)
                    .padding(.horizontal, Theme.Metric.liveScreenMargin)

                LiveStreamGrid(viewModel: streamViewModel)
                    .padding(.horizontal, Theme.Metric.liveScreenMargin)
                    .padding(.top, 4)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await streamViewModel.loadFirstPage()
        }
    }

    /// H5 `bannerList` 派生：type=2 且 `bannerPosition includes '首页'`。
    private var homeBannerItems: [AppPictureItem] {
        appPictureStore.items(of: .banner, position: "首页")
    }

    private func openBanner(_ item: AppPictureItem) {
        guard let route = HomeBannerH5Route(item: item) else { return }
        if !route.isInternalH5Route {
            if route.originalURLString.contains("isPkActive") {
                AnalyticsTracker.track("hostPK_activity")
            }
            AnalyticsTracker.track("h_home_banner_click", properties: ["bannerid": item.id])
        }
        openHomeBanner.perform(route)
    }

    /// reconnect toast（对齐 H5 `refreshIMOnline` 后 1s showToast(call.reconnect)）。
    /// 顶部胶囊，2s 自动消失；同页多次点刷新每次都覆盖延续 2s。
    @ViewBuilder
    private var reconnectToast: some View {
        if showReconnectToast {
            Text(L10n.callReconnect)
                .toastStyle()
                .transition(Toast.transition)
                .task(id: showReconnectToast) {
                    do {
                        try await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                        try Task.checkCancellation()
                    } catch { return }
                    showReconnectToast = false
                }
        }
    }

    private var placeholderTab: some View {
        VStack {
            Spacer()
            Text(L10n.homeTopTabComingSoon)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
    }
}

#Preview {
    LiveTabView()
}
