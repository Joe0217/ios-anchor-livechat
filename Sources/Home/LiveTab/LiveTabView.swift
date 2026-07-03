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

    /// reconnect toast 展示态（对齐 H5 `refreshIMOnline` 后 1s 弹的 toast）。
    /// LiveTopBar 点刷新 → OnlineStatusStore.refreshToastTick 变化 → 本 view onChange 抬起。
    @State private var showReconnectToast: Bool = false
    @ObservedObject private var onlineStatus = OnlineStatusStore.shared

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
            // scenePhase → .active：对齐安卓 onResume 静默检查（showToast=false, doAction=false）
            .onChange(of: scenePhase) { newPhase in
                guard newPhase == .active, isHomeTabActive else { return }
                Task { @MainActor in
                    await onlineStatus.checkForcedBusy(showToast: false, doAction: false)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                Task { @MainActor in
                    await anchorInfoStore.loadIfNeeded()
                    if anchorInfoStore.hasLoadedTier {
                        homeStore.applyTier(isSLevel: anchorInfoStore.isSLevelAnchor)
                    }
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
            .onChange(of: anchorInfoStore.hasLoadedTier) { _ in
                homeStore.applyTier(isSLevel: anchorInfoStore.isSLevelAnchor)
            }
            .onChange(of: anchorInfoStore.isSLevelAnchor) { _ in
                if anchorInfoStore.hasLoadedTier {
                    homeStore.applyTier(isSLevel: anchorInfoStore.isSLevelAnchor)
                }
            }
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
                rankCount: viewModel.rankCount
            )
            .padding(.top, 6)

            TabView(selection: Binding(
                get: { current },
                set: { homeStore.tapOuter($0) }
            )) {
                // isActive 组合两条件：Home tab 被选中 + outer tab 是 .live——切走任一都停 autoplay
                liveStream(isActive: isHomeTabActive && current == .live).tag(HomeTopTab.live)
                LiveListView(viewModel: listViewModel).tag(HomeTopTab.list)
                placeholderTab.tag(HomeTopTab.match)
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
        if current == .live {
            QuickGoLiveButton()
                .padding(.trailing, 12)
                .padding(.bottom, 180)
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

                LiveBanner(items: homeBannerItems, isActive: isActive)
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

    /// reconnect toast（对齐 H5 `refreshIMOnline` 后 1s showToast(call.reconnect)）。
    /// 顶部胶囊，2s 自动消失；同页多次点刷新每次都覆盖延续 2s。
    @ViewBuilder
    private var reconnectToast: some View {
        if showReconnectToast {
            Text(L10n.callReconnect)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: 0x424242), in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: showReconnectToast) {
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
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
