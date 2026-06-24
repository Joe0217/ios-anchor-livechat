import Foundation

/// 派对房用户角色（对齐安卓 `PartyRoomRoleType`）。
/// MVP 仅消费 `.owner` / `.audience` 二态分流（管理动作推 F）。
enum PartyRoomRoleType: Int, Codable {
    case owner = 1
    case admin = 2
    case audience = 3
}

/// 麦位类型（对齐安卓 `PartyRoomSeatType`）。
/// MVP 同时支持语聊位 + 视频位（v2 反悔决策，原 v1 仅语聊）。
enum PartyRoomSeatType: Int, Codable {
    case video = 1
    case voice = 2
}

/// 麦位操作类型（对齐安卓 `OperatorType`，完整定义 1-11；MVP 仅消费 1/2，其余留 F 复用）。
/// `prohibit/unprohibit` MVP 期仅作为他人广播态接收（自己施加于他人是管理动作，推 F）。
enum PartyOperatorType: Int, Codable {
    case onSeat = 1
    case downSeat = 2
    case holdDown = 3
    case holdUp = 4
    case prohibit = 6
    case unprohibit = 7
    case lock = 8
    case unlock = 9
    case exchange = 10
    case removeAdminAndHoldDown = 11
}

/// 派对房房间状态机（spec §1.4.2）。F 期再扩 `.kicked` / `.minimized`。
enum PartyRoomState: Equatable {
    case idle
    case preparing
    case entering
    case joined
    case leaving
    case ended
}

/// 强制退房原因（spec §1.4.6 `forceLeaveRoom`）。
enum PartyForceLeaveReason: Equatable {
    case kicked            // 1003 KICKED_OUT_PARTY_ROOM 双字段守护匹配后触发
    case entryFailed       // enter 接口 / RTC join / IM chatroom 任一阶段失败
    case networkLost       // NIM `UNLOGIN/NET_BROKEN` 长时间未恢复
    case userRequest       // 用户主动退房
}
