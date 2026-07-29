import SwiftUI

/// 未审核账号受限首屏容器:底部只两个 tab(消息 + 我的),对齐 H5 [tabList.ts:38-53](../../../anchor-livechat-h5/src/config/tabList.ts) `tabListRestricted`。
///
/// RootView 分流入口:`session.user?.userType != 2 && != 9` 时使用本 view 替代 MainTabView,
/// 让未审核/审核中/被拒/封禁账号看到受限界面而非完整主界面。
///
/// 独立实现不复用 MainTabView 内部组件(按 .claude/rules/cross-scene-component-reuse-preflight.md
/// preflight 结论:MainTabView 挂载复杂 store 依赖 + 直播/派对/礼物特效等基建,不适合受限账号)。
///
/// 两个 tab 各自 NavigationStack:MineRestrictedView 承载 Register 4 步流程(与 LoginView 复用 RegisterPathHolder.shared)。
struct RestrictedTabView: View {
    @EnvironmentObject private var session: SessionStore
    /// 默认落地 news tab —— 对齐 H5 `App.vue:isLogin()` `router.replace('/newsRestricted')`(未审核账号
    /// 登录后先看审核提示 + Administrator 联系入口,而不是自己已提交的资料)
    @State private var selection: Tab = .news
    @State private var isNewsOnSubpage = false
    @State private var isMineOnSubpage = false

    enum Tab: Hashable {
        case news
        case mine
    }

    var body: some View {
        ZStack {
            NewsRestrictedView(isOnSubpage: $isNewsOnSubpage)
                .opacity(selection == .news ? 1 : 0)
                .allowsHitTesting(selection == .news)

            MineRestrictedView(isOnSubpage: $isMineOnSubpage)
                .opacity(selection == .mine ? 1 : 0)
                .allowsHitTesting(selection == .mine)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isOnSubpage {
                tabBar
            }
        }
        .background(Theme.Palette.profileBackground)
        .appLocaleEnvironment()
        .task {
            // 对齐 H5 App.vue.isLogin() 每次冷启动拉 getAnchorInfo 刷新审核态 —— iOS 首次进入受限首屏时同步一次,
            // 避免用户离线时审核通过/被封禁但本地 LoginResult 仍是登录快照的问题。
            // sysMsg 58 push 只覆盖在线时的实时变化;进入 view 主动拉一次是**冷启动/长离线**的兜底路径。
            await session.refreshAuditStatus()
        }
    }

    /// 对齐 H5 `showTabbar = tabPathArray.includes(route.path)`：仅两个根页面显示底栏。
    private var isOnSubpage: Bool {
        switch selection {
        case .news: return isNewsOnSubpage
        case .mine: return isMineOnSubpage
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.news, icon: "tabMessages", activeIcon: "tabMessagesActive", title: L10n.tabMessages)
            tabButton(.mine, icon: "tabProfile", activeIcon: "tabProfileActive", title: L10n.tabProfile)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Metric.tabBarHeight)
        .background(Theme.Palette.screenBackground)
        .background {
            Theme.Palette.screenBackground.ignoresSafeArea(edges: .bottom)
        }
    }

    private func tabButton(_ tab: Tab, icon: String, activeIcon: String, title: String) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(isSelected ? activeIcon : icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.Typography.tabLabel)
                    .foregroundStyle(isSelected ? Theme.Palette.tabActive : Theme.Palette.tabInactiveLabel)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
