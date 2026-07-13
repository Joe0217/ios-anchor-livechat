import Foundation

/// 派对房房管（`room/getRoomAdminList` 返回项）。
///
/// 字段名来自 H5 常规命名推断，**待真机 log 验证**
/// （对齐 `.claude/rules/agent-recon-field-names-unverified.md`）
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
