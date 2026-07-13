import Foundation

/// 我的派对房 wrapper（对齐 H5 用户端 `apiGetPartyRoomInfo` 返回结构）。
///
/// 后端返回 `{ myRoom: { id, roomStatus }, ... }`；本 wrapper 只关心 `myRoom` 字段。
/// H5 判定 `!!myPartyInfo?.myRoom?.id && myRoom?.roomStatus !== 2` (roomStatus=2 视为封禁)。
struct PartyMyRoomInfoWrapper: Codable, Equatable, Sendable {
    let myRoom: PartyMyRoom?
}

struct PartyMyRoom: Codable, Equatable, Sendable {
    let id: String?
    /// 后端房间状态：`2` = 封禁（H5 语义：不显示 My Room 入口）
    let roomStatus: Int?

    /// 有效 room：id 非空 + 非封禁
    var isVisible: Bool {
        guard let id, !id.isEmpty else { return false }
        return roomStatus != 2
    }
}

extension PartyMyRoom {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id 字段 String/Int 兼容（api-http-method-strict rule + ios-decode-userid-compat rule）
        if let s = try? c.decode(String.self, forKey: .id) {
            self.id = s
        } else if let i = try? c.decode(Int64.self, forKey: .id) {
            self.id = String(i)
        } else {
            self.id = nil
        }
        self.roomStatus = try? c.decode(Int.self, forKey: .roomStatus)
    }
}
