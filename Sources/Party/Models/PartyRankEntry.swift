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
    /// 大厅 Room 榜点击后进入的房间 ID；PartyRich 榜该字段为空。
    let roomId: String?
    /// 大厅榜使用：1=用户，2=主播；决定默认头像和奖励配置。
    let userType: Int?
    let countryId: String?
    let rewardConfig: [PartyLobbyRankReward]

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
        case roomId, userType, countryId, rewardConfig
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
        } else if let s = Self.decodeString(c, forKey: .roomId), !s.isEmpty {
            // Room 榜个别后端版本只返回 roomId；仍需稳定 Identifiable 供列表渲染。
            userId = s
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
        roomId = Self.decodeString(c, forKey: .roomId)
        userType = Self.decodeInt(c, forKey: .userType)
        countryId = Self.decodeString(c, forKey: .countryId)
        rewardConfig = (try? c.decode([PartyLobbyRankReward].self, forKey: .rewardConfig)) ?? []
    }

    init(userId: String, nickname: String? = nil, avatar: String? = nil,
         rankValue: Int? = nil, roomRoleType: Int? = nil,
         headFrame: String? = nil, age: Int? = nil, gender: Int? = nil,
         rankIndex: Int? = nil, rankValueText: String? = nil, score: String? = nil,
         roomId: String? = nil, userType: Int? = nil, countryId: String? = nil,
         rewardConfig: [PartyLobbyRankReward] = []) {
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
        self.roomId = roomId
        self.userType = userType
        self.countryId = countryId
        self.rewardConfig = rewardConfig
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

extension PartyRankEntry {
    /// 大厅/房内榜单已有的用户资料，避免点名片卡后等待详情接口才出现身份信息。
    var userCardPreview: UserCardPreview {
        let countryEmoji = countryId.flatMap { code in
            let flag = AnchorInfoStore.flagEmoji(from: code)
            return flag == "🌐" ? nil : flag
        }
        let genderValue: UserCardInfo.Gender? = switch gender {
        case 1: .male
        case 2: .female
        case .some: .unknown
        case nil: nil
        }
        return UserCardPreview(
            userId: userId,
            nickname: nickname,
            avatarUrl: avatar,
            headwearUrl: headFrame,
            gender: genderValue,
            age: age,
            countryEmoji: countryEmoji,
            userType: userType
        )
    }
}

/// Party Rich / Room 周月榜奖励。H5 同时用它渲染已上榜用户和空名次的奖励预览。
struct PartyLobbyRankReward: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let rankingPosition: Int?
    let userType: Int?
    let rewardType: Int?
    let itemSmallImg: String?
    let itemName: String?
    let validDay: Int?

    private enum CodingKeys: String, CodingKey {
        case id, itemId, rankingPosition, userType, rewardType, itemSmallImg, itemName, validDay, durationDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id)
            ?? c.decodeFlexibleString(forKey: .itemId)
            ?? UUID().uuidString
        rankingPosition = c.decodeFlexibleInt(forKey: .rankingPosition)
        userType = c.decodeFlexibleInt(forKey: .userType)
        rewardType = c.decodeFlexibleInt(forKey: .rewardType)
        itemSmallImg = c.decodeFlexibleString(forKey: .itemSmallImg)
        itemName = c.decodeFlexibleString(forKey: .itemName)
        validDay = c.decodeFlexibleInt(forKey: .validDay) ?? c.decodeFlexibleInt(forKey: .durationDays)
    }
}

/// 大厅 Party Rich / Room 榜接口响应。
struct PartyLobbyRankResponse: Decodable, Equatable {
    let rankList: [PartyRankEntry]
    let myRank: PartyRankEntry?
    let rewardConfigs: [PartyLobbyRankReward]
    let duration: Int?

    private enum CodingKeys: String, CodingKey { case rankList, list, myRank, rewardConfigs, duration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rankList = (try? c.decode([PartyRankEntry].self, forKey: .rankList))
            ?? (try? c.decode([PartyRankEntry].self, forKey: .list))
            ?? []
        myRank = try? c.decodeIfPresent(PartyRankEntry.self, forKey: .myRank)
        rewardConfigs = (try? c.decode([PartyLobbyRankReward].self, forKey: .rewardConfigs)) ?? []
        duration = c.decodeFlexibleInt(forKey: .duration)
    }
}

/// 大厅卡片 Top3 头像响应。
struct PartyLobbyTop3Response: Decodable, Equatable {
    let partyRichTop3Avatar: [String]
    let roomTop3Avatar: [String]

    private enum CodingKeys: String, CodingKey { case partyRichTop3Avatar, roomTop3Avatar }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partyRichTop3Avatar = (try? c.decode([String].self, forKey: .partyRichTop3Avatar)) ?? []
        roomTop3Avatar = (try? c.decode([String].self, forKey: .roomTop3Avatar)) ?? []
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
