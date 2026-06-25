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
/// 切 tab 行为：用户选择"切走回根"——`onChange(of: selection)` 触发即清空两 tab 的 path，
/// 切回时回到 tab 根页（与 Instagram 一致；不沿用 iOS 系统 TabView 默认保留行为）。
///
/// scenePhase 守卫：CLAUDE.md v5.3.3 真根因坑——SwiftUI 在 `.background` 时仍触发 onChange，
/// 切后台时不要触发 withAnimation（回前台 backlog 会一次性闪烁），仅在 active/inactive 才动画。
struct MainTabView: View {
    @State private var selection: MainTab = .home
    @State private var workPath: NavigationPath = NavigationPath()
    @State private var profilePath: NavigationPath = NavigationPath()
    @State private var isOnSubpage: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    /// 派生信号：当前选中 tab 是否在子页（对应 tab 的 path 非空）。
    /// 用单一 Equatable 信号触发 onChange，避免 selection / workPath.count / profilePath.count
    /// 三个独立 onChange 在同一 transaction 内互相 reentrancy 导致动画闪烁。
    private var isOnSubpageSignal: Bool {
        switch selection {
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
            // 切走 tab 立即清空两 tab 的 path，切回时回到根页
            workPath = NavigationPath()
            profilePath = NavigationPath()
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home:
            HomeView()
        case .messages:
            PlaceholderTab(title: L10n.tabMessages)
        case .work:
            // workPath 由 MainTabView 持有：tabbar 才能感知 push/pop 深度
            // navigationDestination 紧贴 NavigationStack 根节点注册，避免挂在 WorkView ZStack 时的解析时机风险
            NavigationStack(path: $workPath) {
                WorkView(path: $workPath)
                    .navigationDestination(for: WorkRoute.self) { route in
                        switch route {
                        case .pocDebug:
                            POCDebugView()
                        }
                    }
            }
        case .profile:
            // profilePath 同 workPath 上抬到 MainTabView：Profile 子页 push 时 tabbar 也参与坍缩。
            // ProfileView 内自带 NavigationStack 已删除，两段 navigationDestination
            //（FollowSegment + ProfileRoute）上移到此根节点统一注册。
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

    /// tabbar 永驻容器：用几何坍缩 + 透明度切换隐显，不做 if/EmptyView 增删。
    /// allowsHitTesting / accessibilityHidden 同步切，避免坍缩后误命中或被 VoiceOver 聚焦。
    private var tabBarHostContainer: some View {
        ZStack { tabBar }
            .frame(height: isOnSubpage ? 0 : Theme.Metric.tabBarHeight)
            .clipped()
            .opacity(isOnSubpage ? 0 : 1)
            .allowsHitTesting(!isOnSubpage)
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
