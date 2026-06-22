import SwiftUI

/// 底部 4 tab 主壳。设计稿无原生 tab 栏样式（深色、无分隔线、激活态仅靠颜色区分），
/// 故用自定义 tab 栏 + safeAreaInset，使内容自动避让，不被遮挡。
/// Home tab 暂挂现有调试菜单（保留真机测试入口），Messages/Profile 为占位。
struct MainTabView: View {
    @State private var selection: MainTab = .work

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            tabBar
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home:     HomeView()
        case .messages: PlaceholderTab(title: L10n.tabMessages)
        case .work:     WorkView()
        case .profile:  PlaceholderTab(title: L10n.tabProfile)
        }
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
            Image(tab.icon)
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

    var icon: String {
        switch self {
        case .home:     return "tabHome"
        case .messages: return "tabMessages"
        case .work:     return "tabWork"
        case .profile:  return "tabProfile"
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
