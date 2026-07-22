import Foundation

/// 派对房榜单项（贡献榜 / 荣誉榜 / 观众列表共用）。
///
/// 对齐 H5 `livechat-h5/src/components/party/components/room-rank.vue` 列表项 schema：
/// `{userId, avatar, nickname, age, gender, medals, rankValue, roomRoleType, headFrame}`
///
/// 观众列表模式复用同 model：`rankValue` 缺省 nil；`roomRoleType` 用于 role badge 展示。
///
/// **字段名来自 H5 源码 + 常规推断，未真机 log 校准**
/// （对齐 [agent-recon-field-names-unverified] rule；真机首次拉后如与实际不符补 CodingKeys alias）
struct PartyRankEntry: Decodable, Identifiable, Equatable, Hashable {
    let userId: String
    let nickname: String?
    let avatar: String?
    /// 榜单分值（贡献 = 钻石，荣誉 = 宝石；观众列表模式为 nil）
    let rankValue: Int?
    /// 房间内角色：1=owner / 2=admin / 3=audience（观众列表 tab 用于显示徽章）
    let roomRoleType: Int?
    /// 头像装饰框（可能 SVGA / 静态图）
    let headFrame: String?
    let age: Int?
    let gender: Int?
    /// 服务端排名。普通榜单列表按顺序渲染时可省略，但 `myRank` 固定行必须消费该字段。
    let rankIndex: Int?
    /// 游戏任务榜的预计奖励。该字段是 Long，必须保留服务端字符串，不能先转成 `Int`。
    let rankValueText: String?
    /// 在线观众接口的游标。后端以分值排序，下一页请求需原样回传最后一项的 `score`。
    let score: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId, nickname, avatar
        case rankValue
        case roomRoleType
        case headFrame
        case age, gender
        // 常见 alias
        case id
        case icon
        case rankScore
        case cost
        case score
        case rankIndex
        case headSmallFrame
        // 游戏任务激励排行榜（marketing）字段
        case anchorId
        case avatarUrl
        case expectedReward
        case rank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // userId 兼容 String/Int（对齐 [ios-decode-userid-compat] rule）
        if let s = try? c.decode(String.self, forKey: .userId), !s.isEmpty {
            userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .userId) {
            userId = String(i)
        } else if let s = try? c.decode(String.self, forKey: .id), !s.isEmpty {
            userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .id) {
            userId = String(i)
        } else if let s = try? c.decode(String.self, forKey: .anchorId), !s.isEmpty {
            userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .anchorId) {
            userId = String(i)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .userId, in: c,
                debugDescription: "PartyRankEntry: missing userId")
        }

        nickname = try? c.decode(String.self, forKey: .nickname)
        avatar = (try? c.decode(String.self, forKey: .avatar))
            ?? (try? c.decode(String.self, forKey: .icon))
            ?? (try? c.decode(String.self, forKey: .avatarUrl))

        // rankValue: 兼容 rankValue / rankScore / cost / score / String Int 混发
        rankValue = Self.decodeInt(c, forKey: .rankValue)
            ?? Self.decodeInt(c, forKey: .rankScore)
            ?? Self.decodeInt(c, forKey: .cost)
            ?? Self.decodeInt(c, forKey: .score)

        roomRoleType = try? c.decode(Int.self, forKey: .roomRoleType)
        headFrame = (try? c.decode(String.self, forKey: .headFrame))
            ?? (try? c.decode(String.self, forKey: .headSmallFrame))
        age = try? c.decode(Int.self, forKey: .age)
        gender = try? c.decode(Int.self, forKey: .gender)
        rankIndex = Self.decodeInt(c, forKey: .rankIndex)
            ?? Self.decodeInt(c, forKey: .rank)
        rankValueText = Self.decodeString(c, forKey: .expectedReward)
        score = Self.decodeString(c, forKey: .score)
    }

    init(userId: String, nickname: String? = nil, avatar: String? = nil,
         rankValue: Int? = nil, roomRoleType: Int? = nil,
         headFrame: String? = nil, age: Int? = nil, gender: Int? = nil,
         rankIndex: Int? = nil, rankValueText: String? = nil, score: String? = nil) {
        self.userId = userId
        self.nickname = nickname
        self.avatar = avatar
        self.rankValue = rankValue
        self.roomRoleType = roomRoleType
        self.headFrame = headFrame
        self.age = age
        self.gender = gender
        self.rankIndex = rankIndex
        self.rankValueText = rankValueText
        self.score = score
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Int(value) }
        if let value = try? container.decode(Double.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key), !value.isEmpty { return value }
        if let value = try? container.decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Double.self, forKey: key) { return String(value) }
        return nil
    }
}

/// 游戏任务激励排行榜响应（安卓 `PartyRoomRankingFragment` 与主播端 H5 共用）。
///
/// `expectedReward` / `anchorId` 均可能是字符串化 Long；列表项复用 `PartyRankEntry` 的兼容解码，
/// 从而不在 Swift 侧损失精度。
struct PartyGameTaskRankingResponse: Decodable {
    let list: [PartyRankEntry]
    let myRanking: PartyRankEntry?
    let total: Int

    enum CodingKeys: String, CodingKey {
        case list, myRanking, total
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        list = (try? c.decodeIfPresent([PartyRankEntry].self, forKey: .list)) ?? []
        myRanking = try? c.decodeIfPresent(PartyRankEntry.self, forKey: .myRanking)
        total = c.decodeFlexibleInt(forKey: .total) ?? list.count
    }
}

/// 派对房榜单响应包装（贡献 / 荣誉榜返 `{rankList, myRank, duration}`）。
struct PartyRankResponse: Decodable {
    let rankList: [PartyRankEntry]
    let myRank: PartyRankEntry?
    /// 当前榜单周期的剩余秒数。`periodType=LAST` 时服务端通常不返回。
    let duration: Int?

    enum CodingKeys: String, CodingKey {
        case rankList
        case list
        case myRank
        case duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let arr = try? c.decode([PartyRankEntry].self, forKey: .rankList) {
            rankList = arr
        } else if let arr = try? c.decode([PartyRankEntry].self, forKey: .list) {
            rankList = arr
        } else {
            rankList = []
        }
        myRank = try? c.decode(PartyRankEntry.self, forKey: .myRank)
        if let value = try? c.decode(Int.self, forKey: .duration) {
            duration = value
        } else if let value = try? c.decode(String.self, forKey: .duration) {
            duration = Int(value)
        } else {
            duration = nil
        }
    }

    init(rankList: [PartyRankEntry], myRank: PartyRankEntry? = nil, duration: Int? = nil) {
        self.rankList = rankList
        self.myRank = myRank
        self.duration = duration
    }
}
