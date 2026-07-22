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

    enum Tab: Hashable {
        case news
        case mine
    }

    var body: some View {
        let _ = AppLogger.auth.info("[RestrictedTabView] body eval: selection=\(String(describing: selection), privacy: .public)")
        return TabView(selection: $selection) {
            NewsRestrictedView()
                .tabItem {
                    Label("Messages", systemImage: "message.fill")
                }
                .tag(Tab.news)

            MineRestrictedView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
                }
                .tag(Tab.mine)
        }
        .appLocaleEnvironment()
        .task {
            // 对齐 H5 App.vue.isLogin() 每次冷启动拉 getAnchorInfo 刷新审核态 —— iOS 首次进入受限首屏时同步一次,
            // 避免用户离线时审核通过/被封禁但本地 LoginResult 仍是登录快照的问题。
            // sysMsg 58 push 只覆盖在线时的实时变化;进入 view 主动拉一次是**冷启动/长离线**的兜底路径。
            await session.refreshAuditStatus()
        }
    }
}
