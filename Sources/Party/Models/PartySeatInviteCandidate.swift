import Foundation

/// 空麦位邀请面板的在线推荐用户。
/// 对齐 H5 `room/getRecommendInviteList`，只保留列表与邀请分流所需字段。
struct PartySeatInviteCandidate: Decodable, Identifiable, Equatable, Hashable {
    let userId: String
    let nickname: String?
    let avatar: String?
    /// 1=普通用户；视频位邀请普通用户需走 `inviteOnSeat` 二次确认。
    let userType: Int?
    let roomRoleType: Int?
    /// 下一页游标，原样回传给服务端。
    let score: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId, nickname, nickName, avatar, icon, userType, roomRoleType, score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .userId), !value.isEmpty {
            userId = value
        } else if let value = try? container.decode(Int64.self, forKey: .userId) {
            userId = String(value)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .userId,
                in: container,
                debugDescription: "PartySeatInviteCandidate: missing userId"
            )
        }
        nickname = (try? container.decode(String.self, forKey: .nickname))
            ?? (try? container.decode(String.self, forKey: .nickName))
        avatar = (try? container.decode(String.self, forKey: .avatar))
            ?? (try? container.decode(String.self, forKey: .icon))
        userType = Self.decodeInt(container, forKey: .userType)
        roomRoleType = Self.decodeInt(container, forKey: .roomRoleType)
        if let value = try? container.decode(String.self, forKey: .score) {
            score = value
        } else if let value = try? container.decode(Int64.self, forKey: .score) {
            score = String(value)
        } else if let value = try? container.decode(Double.self, forKey: .score) {
            score = String(value)
        } else {
            score = nil
        }
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }
}
