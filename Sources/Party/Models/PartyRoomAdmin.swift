import Foundation

/// 派对房房管（Store/View 消费的轻量 model）。
///
/// **数据来源**：H5 用户端无独立"房管列表"接口；`PartyAdminServiceLive.fetchAdminList` 拉
/// `room/getViewers`(`type: 1`) 后客户端按 `roomRoleType == 2` 筛出，转为本 struct 供 UI。
/// Decodable 实现保留供未来若后端上线独立接口时直接兼容。
struct PartyRoomAdmin: Decodable, Identifiable, Equatable, Hashable {
    let userId: String
    let nickname: String?
    let icon: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId, nickname, icon
        // 常见 alias
        case id
        case avatar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // userId 兼容 String/Int（对齐 ios-decode-userid-compat rule）
        if let s = try? c.decode(String.self, forKey: .userId), !s.isEmpty {
            userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .userId) {
            userId = String(i)
        } else if let s = try? c.decode(String.self, forKey: .id), !s.isEmpty {
            userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .id) {
            userId = String(i)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .userId, in: c,
                debugDescription: "PartyRoomAdmin: neither userId nor id present")
        }
        nickname = try? c.decode(String.self, forKey: .nickname)
        icon = (try? c.decode(String.self, forKey: .icon))
            ?? (try? c.decode(String.self, forKey: .avatar))
    }

    init(userId: String, nickname: String? = nil, icon: String? = nil) {
        self.userId = userId
        self.nickname = nickname
        self.icon = icon
    }
}
