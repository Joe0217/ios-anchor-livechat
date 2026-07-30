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
    /// 进入某个房间。密码房由大厅前置校验成功后再创建此路由；`password` 保留给深链等直接进入场景。
    /// `entryPath` 只承载产品来源语义，不能由服务端回包反向推断。
    case room(id: String, password: String?, entryPath: PartyRoomEntryPath = .standard)
    /// 搜索页（E 增强 2026-07-10：对齐 H5 用户端 `/party/search`）
    case search
    /// 大厅 Party Rich / Room 榜（对齐 H5 用户端 `/party/rank?type=0|1`）。
    case lobbyRanking(PartyLobbyRankingKind)
}

/// 进入 Party 房的业务来源。热门房掉榜引导只允许由 `topRoomGuide` 链路继续触发。
enum PartyRoomEntryPath: String, Hashable {
    case standard = "partyroom_feed"
    case partyFollow = "partyroom_follow"
    case partyRecent = "partyroom_recent"
    case myRoom = "float_btn"
    case partyHomeBanner = "partyHome_banner"
    case search = "partyroom_search"
    case rankRoom = "rank_room"
    case topRoomGuide = "top_room_guide"
}

enum PartyLobbyRankingKind: String, CaseIterable, Identifiable, Hashable {
    case partyRich
    case room

    var id: String { rawValue }

    var title: String {
        switch self {
        case .partyRich: return L10n.Party.rankPartyRich
        case .room: return L10n.Party.rankRoom
        }
    }
}
