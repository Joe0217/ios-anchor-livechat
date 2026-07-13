import Foundation

/// 派对房大厅列表 3 种数据源（对齐 H5 用户端 `src/views/party/index.vue` L88-93）。
///
/// - `.party`    → `/party/room/list`         主大厅（支持 languageCode 筛选 + 搜索）
/// - `.followed` → `/party/room/followed/list` 关注房间（H5 强制不筛语言）
/// - `.recent`   → `/party/room/recent/list`   最近访问（H5 强制不筛语言）
enum PartyRoomListKind: Sendable, Hashable {
    case party
    case followed
    case recent

    var endpointSuffix: String {
        switch self {
        case .party:    return "/room/list"
        case .followed: return "/room/followed/list"
        case .recent:   return "/room/recent/list"
        }
    }
}
