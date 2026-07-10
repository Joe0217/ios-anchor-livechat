import Foundation

/// 房间模板（`room/getRoomTempList` 返回的 `List<PartyRoomMode>`）。
/// 模板决定麦位布局：语聊位与视频位的数量、位置、最大上麦数。
/// MVP 至少需要 dev 后端配置一个**混合模板**（含 1 视频位 + 多语聊位）。
struct PartyRoomTemplate: Decodable, Equatable, Identifiable {
    let id: Int
    let name: String?
    let modeType: Int?           // 安卓字段名，H5 用户端字段名 `type`（1=Voice / 2=Live+Voice）
    let seatCount: Int?          // 总麦位数
    let videoSeatCount: Int?     // 视频位数（含接待位）
    let voiceSeatCount: Int?     // 语聊位数
    let coverImage: String?      // H5 字段名 `imgUrl`，iOS 沿用旧命名
    /// H5 用户端字段 `createRoomLevel`：创房者需要达到的最低段位，`userLevel >= createRoomLevel` 才解锁
    /// nil 视为无门槛（对所有用户 Unlock）
    let createRoomLevel: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, modeType, seatCount, videoSeatCount, voiceSeatCount
        case coverImage
        case createRoomLevel
        // H5 用户端别名兼容
        case type          // 后端可能返 type 而不是 modeType
        case imgUrl        // 后端可能返 imgUrl 而不是 coverImage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        // modeType alias 到 type
        modeType = (try? c.decode(Int.self, forKey: .modeType))
                ?? (try? c.decode(Int.self, forKey: .type))
        seatCount = try? c.decode(Int.self, forKey: .seatCount)
        videoSeatCount = try? c.decode(Int.self, forKey: .videoSeatCount)
        voiceSeatCount = try? c.decode(Int.self, forKey: .voiceSeatCount)
        // coverImage alias 到 imgUrl
        coverImage = (try? c.decode(String.self, forKey: .coverImage))
                  ?? (try? c.decode(String.self, forKey: .imgUrl))
        createRoomLevel = try? c.decode(Int.self, forKey: .createRoomLevel)
    }

    /// 测试/Preview 用 memberwise 构造
    init(id: Int, name: String? = nil, modeType: Int? = nil, seatCount: Int? = nil,
         videoSeatCount: Int? = nil, voiceSeatCount: Int? = nil, coverImage: String? = nil,
         createRoomLevel: Int? = nil) {
        self.id = id
        self.name = name
        self.modeType = modeType
        self.seatCount = seatCount
        self.videoSeatCount = videoSeatCount
        self.voiceSeatCount = voiceSeatCount
        self.coverImage = coverImage
        self.createRoomLevel = createRoomLevel
    }
}
