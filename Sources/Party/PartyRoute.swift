import Foundation

/// 派对房 tab 内的导航路由（E-spec §0.2）。
///
/// 用 value-based `NavigationLink(value:) + .navigationDestination(for: PartyRoute.self)`
/// 消除 v1 借宿 `MainTabView.workPath` (`WorkRoute.self`) 的技术债。
///
/// 未来 F 期加 pill (推荐/关注/最近)时，pill 走**内嵌 view 切换**而非新 route case，
/// 避免 pill 切换触发 partyPath 变化让 tabbar 隐藏（对齐 spec §12 F 期路由演进笔记）。
enum PartyRoute: Hashable {
    /// 创建派对房入口页
    case create
    /// 进入某个房间（密码房 MVP 不做前置密码框，password 保留字段供 F 期使用）
    case room(id: String, password: String?)
}
