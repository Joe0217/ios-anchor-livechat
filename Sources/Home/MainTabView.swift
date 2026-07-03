import SwiftUI

/// 底部 4 tab 主壳。设计稿无原生 tab 栏样式（深色、无分隔线、激活态仅靠颜色区分），
/// 故用自定义 tab 栏 + safeAreaInset，使内容自动避让，不被遮挡。
///
/// 通用规则：tabbar 仅在 4 个 tab 根页显示；任何 push 入栈的子页（含未来新增）一律隐藏 tabbar。
/// 实现：Work / Profile 的 NavigationStack path 均上抬到本视图持有，由派生 Equatable
/// `SubpageSignal` 统一驱动 `isOnSubpage`，单 `onChange` 触发 250ms easeInOut 几何坍缩 + 淡出。
/// 容器永驻视图层级（frame(height: 0) + clipped + opacity 0 + allowsHitTesting false），
/// 不做 if/EmptyView 增删——iOS 16 上几何坍缩比 view 增删的过渡动画更稳。
///
/// **Tab keep-alive 策略**：
/// - **Home / Messages**：用 ZStack + opacity 永久持有，view 树不被 dismantle —— 切走再回来时
///   `@StateObject`（朋友圈 feed / List segment / 滚动位置 / 网络请求缓存）全部保留
/// - **Work / Profile**：仍走 switch 销毁重建（用户接受重新加载）—— 避免长持栈占资源
///
/// 切 tab 行为：用户选择"切走回根"——`onChange(of: selection)` 触发即清空两 tab 的 path，
/// 切回时回到 tab 根页（与 Instagram 一致；NavigationStack 永久持有但 path 清空，所以视觉上
/// 仍回根页，而根页内 @StateObject 状态完整保留——朋友圈滚动位置不丢）。
///
/// scenePhase 守卫：CLAUDE.md v5.3.3 真根因坑——SwiftUI 在 `.background` 时仍触发 onChange，
/// 切后台时不要触发 withAnimation（回前台 backlog 会一次性闪烁），仅在 active/inactive 才动画。
struct MainTabView: View {
    @State private var selection: MainTab = .home
    @State private var homePath: NavigationPath = NavigationPath()
    @State private var workPath: NavigationPath = NavigationPath()
    @State private var profilePath: NavigationPath = NavigationPath()
    @State private var isOnSubpage: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    /// `.starting` 期间锁 tabbar 拦截触摸，防止 push 到 LiveRoomView 前 tab 切换导致
    /// NavigationStack 销毁 → 后端已建房 iOS 无心跳/rtc = 僵尸房间（B-spec-开播设置页 §1.4 🔴#1 🔴#5）
    @ObservedObject private var liveSettingsLock = LiveSettingsLock.shared

    /// 派生信号：当前选中 tab 是否在子页（对应 tab 的 path 非空）。
    /// 用单一 Equatable 信号触发 onChange，避免 selection / workPath.count / profilePath.count
    /// 三个独立 onChange 在同一 transaction 内互相 reentrancy 导致动画闪烁。
    private var isOnSubpageSignal: Bool {
        switch selection {
        case .home:    return !homePath.isEmpty    // H-0：用户详情页等多入口共享 UserProfileRoute
        case .work:    return !workPath.isEmpty
        case .profile: return !profilePath.isEmpty
        default:       return false
        }
    }

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            tabBarHostContainer
        }
        .onChange(of: isOnSubpageSignal) { newValue in
            // 后台时 SwiftUI 仍可能调度 onChange（v5.3.3 已知坑），避免动画 backlog
            guard scenePhase != .background else {
                isOnSubpage = newValue
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                isOnSubpage = newValue
            }
        }
        .onChange(of: selection) { _ in
            // 切走 tab 立即清空各 tab 的 path，切回时回到根页
            homePath = NavigationPath()
            workPath = NavigationPath()
            profilePath = NavigationPath()
        }
        .task {
            // 全局图片配置预热（对齐 H5 app.js `getBannerList([2])`）：
            // 首页 banner 位靠此接口喂数据；J 里程碑接入启动图/挂件/榜单/分类贴图时按需扩 types
            await AppPictureStore.shared.loadIfNeeded(types: [.banner])
        }
        .task {
            // 跑马灯预热（对齐 H5 `getLiveMarqueeListData()` 进 Live 广场就调）——
            // 独立 .task 让两个预热并发起飞（一起 await 也可以；分开更直观）
            await GiftMarqueeStore.shared.loadIfNeeded()
        }
        .preferredColorScheme(.dark)
    }

    /// content 分两层：
    /// 1. ZStack 永久持有 Home / Messages（opacity 切显隐，view 树不 dismantle）
    /// 2. 内嵌 if 切换 Work / Profile（销毁重建，资源不长持）
    private var content: some View {
        ZStack {
            // —— Home：永久持有 ——
            // H-0：home tab 加 NavigationStack 支持多入口 UserProfileRoute（spec §5.3）。
            // 未来兄弟入口（Circle 头像 / Live 主播头像）也通过 NavigationLink(value: UserProfileRoute.userId(...)) 推入。
            //
            // `isHomeTabActive` 注入：keep-alive 架构下 view 永久持有，view tree 不能用 .task 触发首次拉数据
            // （否则 app 启动即预热）。下游 LiveTabView 据此判断"home 是否真正被用户访问"，做 lazy load。
            NavigationStack(path: $homePath) {
                HomeView()
                    .navigationDestination(for: UserProfileRoute.self) { route in
                        if case let .userId(uid) = route {
                            UserProfileView(userId: uid)
                        }
                    }
                    // Home 也持有 WorkRoute destination——QuickGoLive 从 Home 内 push LiveSettings 后,
                    // LiveSettings 内嵌 NavigationLink(WorkRoute.wishSetting/.beautySettings) 也要能
                    // 在同一 stack 内 push。**必须与 Work stack 保持 case 一致**，否则从 Home 入口进入
                    // 开播设置后点 Wishlist / Beauty 会走 EmptyView。
                    // 复用 WorkRoute 类型（不新建 HomeRoute）——LiveSettings 内的链接 value 类型已固定为 WorkRoute，
                    // 换类型需侵入 LiveSettings 源码。
                    .navigationDestination(for: WorkRoute.self) { route in
                        switch route {
                        case .liveSettings:   LiveSettingsView()
                        case .wishSetting:    WishSettingView()
                        case .beautySettings: BeautySettingsView()
                        case .giftMessage:    GiftMessageView()
                        case .pocDebug:       POCDebugView()
                        }
                    }
            }
            .environment(\.isHomeTabActive, selection == .home)
            .environment(\.quickGoLive, QuickGoLiveAction {
                // 在当前 Home NavigationStack 内 push LiveSettings（对齐用户偏好：
                // 不切 tab、保持上下文；比 H5 CGoLive 切 tab 更内聚）。
                homePath.append(WorkRoute.liveSettings)
            })
            .opacity(selection == .home ? 1 : 0)
            .allowsHitTesting(selection == .home)
            .accessibilityHidden(selection != .home)

            // —— Messages：永久持有 ——
            // H-1 MVP：P2P 会话列表 shared 单例 + keep-alive；切走再回来保留 selectedCategory /
            // sessions / delegate 订阅。详见 [MessageSessionStoreShared.swift](../Message/MessageSessionStoreShared.swift)
            MessageListView(store: MessageSessionStore.shared)
                .opacity(selection == .messages ? 1 : 0)
                .allowsHitTesting(selection == .messages)
                .accessibilityHidden(selection != .messages)

            // —— Work / Profile：if 切换销毁重建 ——
            // 用户接受重新加载；不长持 NavigationStack + WorkView/ProfileView 内的资源。
            if selection == .work {
                NavigationStack(path: $workPath) {
                    WorkView(path: $workPath)
                        .navigationDestination(for: WorkRoute.self) { route in
                            switch route {
                            case .pocDebug:
                                POCDebugView()
                            case .liveSettings:
                                LiveSettingsView()
                            case .wishSetting:
                                WishSettingView()
                            case .beautySettings:
                                BeautySettingsView()
                            case .giftMessage:
                                GiftMessageView()
                            }
                        }
                }
            } else if selection == .profile {
                NavigationStack(path: $profilePath) {
                    ProfileView(path: $profilePath)
                        .navigationDestination(for: FollowSegment.self) { segment in
                            FollowListView(initialSegment: segment)
                        }
                        .navigationDestination(for: ProfileRoute.self) { route in
                            switch route {
                            case .settings:    SettingsView()
                            case .levelDetail: LevelDetailView()
                            case .blocklist:   BlocklistView()
                            }
                        }
                }
            }
        }
    }

    /// tabbar 永驻容器：用几何坍缩 + 透明度切换隐显，不做 if/EmptyView 增删。
    /// allowsHitTesting / accessibilityHidden 同步切，避免坍缩后误命中或被 VoiceOver 聚焦。
    ///
    /// `liveSettingsLock.isLocked` 拦截触摸（B-spec-开播设置页 §1.4）：
    /// 即使 tabbar 视觉上因子页坍缩为 0 高度，isOnSubpage=true 时它已不响应；`.starting`
    /// 状态下 LiveSettingsView 仍在栈内（isOnSubpage=true），tabbar 已经拦截，本 lock 兜底
    /// 覆盖"子页突然消失"边界（B 档保守）。
    private var tabBarHostContainer: some View {
        ZStack { tabBar }
            .frame(height: isOnSubpage ? 0 : Theme.Metric.tabBarHeight)
            .clipped()
            .opacity(isOnSubpage ? 0 : 1)
            .allowsHitTesting(!isOnSubpage && !liveSettingsLock.isLocked)
            .accessibilityHidden(isOnSubpage)
    }

    private var tabBar: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    tabItem(tab, isSelected: selection == tab)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Metric.tabBarHeight)
        .background(Theme.Palette.screenBackground)
    }

    private func tabItem(_ tab: MainTab, isSelected: Bool) -> some View {
        VStack(spacing: 4) {
            Image(isSelected ? tab.activeIcon : tab.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text(tab.label)
                .font(Theme.Typography.tabLabel)
                .foregroundStyle(isSelected ? Theme.Palette.tabActive : Theme.Palette.tabInactiveLabel)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 4 个 tab 定义（图标取切图，标签走 i18n）。
enum MainTab: CaseIterable {
    case home, messages, work, profile

    /// 未选中态切图（浅紫静态色调）
    var icon: String {
        switch self {
        case .home:     return "tabHome"
        case .messages: return "tabMessages"
        case .work:     return "tabWork"
        case .profile:  return "tabProfile"
        }
    }

    /// 选中态切图（橙红渐变彩色）
    var activeIcon: String {
        switch self {
        case .home:     return "tabHomeActive"
        case .messages: return "tabMessagesActive"
        case .work:     return "tabWorkActive"
        case .profile:  return "tabProfileActive"
        }
    }

    var label: String {
        switch self {
        case .home:     return L10n.tabHome
        case .messages: return L10n.tabMessages
        case .work:     return L10n.tabWork
        case .profile:  return L10n.tabProfile
        }
    }
}

// MARK: - EnvironmentKey

/// 标记 home tab 是否被用户选中。MainTabView 注入，LiveTabView/CircleView 等下游消费。
///
/// **设计动机**：home tab 采用 ZStack opacity 的 keep-alive 架构，view tree 永久持有 →
/// `.task` / `.onAppear` 不在用户切到 home 时触发（启动时即触发）。
/// 下游需要"home 是否真正访问"信号来做 lazy load —— 避免启动即预热朋友圈 / List 数据。
private struct IsHomeTabActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isHomeTabActive: Bool {
        get { self[IsHomeTabActiveKey.self] }
        set { self[IsHomeTabActiveKey.self] = newValue }
    }
}

/// 跨 tab 导航 action：Home Live tab 的 QuickGoLiveButton 触发时切到 Work tab + push LiveSettings。
///
/// **设计动机**：`LiveSettingsView` 挂在 Work NavigationStack 的 `WorkRoute.liveSettings`，
/// 单一入口避免多 tab 持有同一 view 导致 state 冲突。CGoLive 对齐 H5：进入开播设置流程。
struct QuickGoLiveAction {
    let perform: () -> Void
    static let noop = QuickGoLiveAction(perform: {})
}

private struct QuickGoLiveKey: EnvironmentKey {
    static let defaultValue: QuickGoLiveAction = .noop
}

extension EnvironmentValues {
    var quickGoLive: QuickGoLiveAction {
        get { self[QuickGoLiveKey.self] }
        set { self[QuickGoLiveKey.self] = newValue }
    }
}

/// 未实现 tab 的占位页。
struct PlaceholderTab: View {
    let title: String

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}
