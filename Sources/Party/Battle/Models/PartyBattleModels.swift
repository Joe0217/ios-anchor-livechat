import Foundation

/// PartyBattle 主状态 model
///
/// 字段来源：H5 partyBattle.ts state 结构 + 安卓 PartyBattleController.kt 主态字段。
/// 首次真机 log 校对（F-1a milestone DoD）时按实际响应字段名与类型收敛。
///
/// 关键坑（对齐 spec §4.2）：
/// - `roomId=0` 是 onInitiateSuccess 时的占位；action 读 roomId 请用 PartyBattleStore.effectiveRoomId
///   fallback 到 PartyStore.shared.roomInfo?.id。
/// - `redScore/blueScore/redGems/blueGems` 后端可能返 Number / Long / BigDecimal 字符串，
///   iOS 用 DoubleOrString wrapper 三兼容。
/// - `uid/roomId/hostUid` 后端 Long 类型可能序列化为 String（对齐 ios-decode-userid-compat rule），
///   Codable 用 CodingKeys + 双 decode 兼容。
struct PartyBattleState: Codable, Equatable {
    var pkId: String
    var battleId: Int
    var roomId: Int64
    var status: PartyBattleStatus
    var templateId: Int?
    var templateName: String?
    var selectingDurationSec: Int
    var durationSec: Int
    var leftSec: Int
    var hostUid: Int64
    var hostRole: Int
    var currentUserTeam: Int?
    var redTeam: BattleTeam
    var blueTeam: BattleTeam
    var neutral: BattleTeam
    var redTop: [BattleTopMember]
    var blueTop: [BattleTopMember]
    var redCrownUid: Int64?
    var blueCrownUid: Int64?
    var redScore: DoubleOrString
    var blueScore: DoubleOrString
    var redGems: DoubleOrString?
    var blueGems: DoubleOrString?
    var winnerTeam: Int?
    var cooldownLeftSec: Int

    enum CodingKeys: String, CodingKey {
        case pkId, battleId, roomId, status, templateId, templateName
        case selectingDurationSec, durationSec, leftSec
        case hostUid, hostRole, currentUserTeam
        case redTeam, blueTeam, neutral, redTop, blueTop
        case redCrownUid, blueCrownUid
        case redScore, blueScore, redGems, blueGems
        case winnerTeam, cooldownLeftSec
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 字段级容错：对齐 H5 partyBattle.ts state 字段全 optional 消费（`?.` + `Number() || 0` 兜底）
        // 后端 partial payload（如 1103 RunningStart 可能缺 hostUid/hostRole；冷却态可能缺 leftSec）
        // 应能 decode 成部分可用 state，不能任一字段缺失导致整体 throw
        pkId = (try? c.decode(String.self, forKey: .pkId)) ?? ""
        battleId = (try? c.decode(Int.self, forKey: .battleId)) ?? 0
        roomId = (try? Self.decodeInt64OrString(from: c, key: .roomId)) ?? 0
        status = (try? c.decode(PartyBattleStatus.self, forKey: .status)) ?? .selecting
        templateId = Self.decodeOptionalIntOrString(from: c, key: .templateId)
        templateName = try c.decodeIfPresent(String.self, forKey: .templateName)
        selectingDurationSec = (try? c.decode(Int.self, forKey: .selectingDurationSec)) ?? 60
        durationSec = (try? c.decode(Int.self, forKey: .durationSec)) ?? 300
        leftSec = (try? c.decode(Int.self, forKey: .leftSec)) ?? 0
        hostUid = (try? Self.decodeInt64OrString(from: c, key: .hostUid)) ?? 0
        hostRole = (try? c.decode(Int.self, forKey: .hostRole)) ?? 1
        currentUserTeam = Self.decodeOptionalIntOrString(from: c, key: .currentUserTeam)
        // team 字段容错：后端 partial payload（如 1103 RunningStart 可能不带 team 快照）应能 decode
        // 对齐 H5 partyBattle.ts:308-319 `redTeam ?? { count: 0, members: [] }` 兜底空 team
        redTeam = (try? c.decode(BattleTeam.self, forKey: .redTeam)) ?? BattleTeam(count: 0, members: [])
        blueTeam = (try? c.decode(BattleTeam.self, forKey: .blueTeam)) ?? BattleTeam(count: 0, members: [])
        neutral = (try? c.decode(BattleTeam.self, forKey: .neutral)) ?? BattleTeam(count: 0, members: [])
        redTop = (try? c.decode([BattleTopMember].self, forKey: .redTop)) ?? []
        blueTop = (try? c.decode([BattleTopMember].self, forKey: .blueTop)) ?? []
        redCrownUid = try Self.decodeOptionalInt64OrString(from: c, key: .redCrownUid)
        blueCrownUid = try Self.decodeOptionalInt64OrString(from: c, key: .blueCrownUid)
        redScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .redScore) ?? .none
        blueScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .blueScore) ?? .none
        redGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .redGems)
        blueGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .blueGems)
        winnerTeam = Self.decodeOptionalIntOrString(from: c, key: .winnerTeam)
        cooldownLeftSec = Self.decodeOptionalIntOrString(from: c, key: .cooldownLeftSec) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pkId, forKey: .pkId)
        try c.encode(battleId, forKey: .battleId)
        try c.encode(roomId, forKey: .roomId)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(templateId, forKey: .templateId)
        try c.encodeIfPresent(templateName, forKey: .templateName)
        try c.encode(selectingDurationSec, forKey: .selectingDurationSec)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encode(leftSec, forKey: .leftSec)
        try c.encode(hostUid, forKey: .hostUid)
        try c.encode(hostRole, forKey: .hostRole)
        try c.encodeIfPresent(currentUserTeam, forKey: .currentUserTeam)
        try c.encode(redTeam, forKey: .redTeam)
        try c.encode(blueTeam, forKey: .blueTeam)
        try c.encode(neutral, forKey: .neutral)
        try c.encode(redTop, forKey: .redTop)
        try c.encode(blueTop, forKey: .blueTop)
        try c.encodeIfPresent(redCrownUid, forKey: .redCrownUid)
        try c.encodeIfPresent(blueCrownUid, forKey: .blueCrownUid)
        try c.encode(redScore, forKey: .redScore)
        try c.encode(blueScore, forKey: .blueScore)
        try c.encodeIfPresent(redGems, forKey: .redGems)
        try c.encodeIfPresent(blueGems, forKey: .blueGems)
        try c.encodeIfPresent(winnerTeam, forKey: .winnerTeam)
        try c.encode(cooldownLeftSec, forKey: .cooldownLeftSec)
    }

    private static func decodeInt64OrString(
        from c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int64 {
        if let i = try? c.decode(Int64.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let i = Int64(s) { return i }
        throw DecodingError.dataCorruptedError(
            forKey: key, in: c,
            debugDescription: "expected Int64 or numeric String")
    }

    private static func decodeOptionalInt64OrString(
        from c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int64? {
        if let i = try? c.decode(Int64.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), !s.isEmpty, let i = Int64(s) {
            return i
        }
        return nil
    }

    private static func decodeOptionalIntOrString(
        from c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), !s.isEmpty, let i = Int(s) {
            return i
        }
        return nil
    }
}

struct BattleTeam: Codable, Equatable {
    var count: Int
    var members: [BattleMember]

    enum CodingKeys: String, CodingKey { case count, members }

    init(count: Int, members: [BattleMember]) {
        self.count = count
        self.members = members
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        members = try c.decodeIfPresent([BattleMember].self, forKey: .members) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try c.encode(members, forKey: .members)
    }
}

struct BattleMember: Codable, Equatable, Identifiable {
    var id: String { String(uid) }
    let uid: Int64
    let nickname: String?
    let avatar: String?
    var personalScore: DoubleOrString?
    var personalGems: DoubleOrString?
    var isCrownHolder: Bool?

    enum CodingKeys: String, CodingKey {
        case uid, nickname, avatar, personalScore, personalGems, isCrownHolder
    }

    init(
        uid: Int64,
        nickname: String? = nil,
        avatar: String? = nil,
        personalScore: DoubleOrString? = nil,
        personalGems: DoubleOrString? = nil,
        isCrownHolder: Bool? = nil
    ) {
        self.uid = uid
        self.nickname = nickname
        self.avatar = avatar
        self.personalScore = personalScore
        self.personalGems = personalGems
        self.isCrownHolder = isCrownHolder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int64.self, forKey: .uid) {
            uid = i
        } else if let s = try? c.decode(String.self, forKey: .uid), let i = Int64(s) {
            uid = i
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .uid, in: c,
                debugDescription: "uid neither Int64 nor numeric String")
        }
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        personalScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .personalScore)
        personalGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .personalGems)
        isCrownHolder = try c.decodeIfPresent(Bool.self, forKey: .isCrownHolder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encodeIfPresent(personalScore, forKey: .personalScore)
        try c.encodeIfPresent(personalGems, forKey: .personalGems)
        try c.encodeIfPresent(isCrownHolder, forKey: .isCrownHolder)
    }
}

/// PK 送礼榜 Top3 成员（对齐 H5 LeaderboardItem 契约）
///
/// H5 后端字段命名（endedSettlement.vue + hostBottomMarquee.vue 消费）：
/// - `senderUid` 送礼者 uid（`uid` 是旧名兼容）
/// - `diamonds` 个人钻石数（`contribution` 是旧名兼容）
/// - `rank` 1-based 排名（hostBottomMarquee 用于 rankIdx = rank-1 派生边框色 + 角标）
struct BattleTopMember: Codable, Equatable {
    let uid: Int64
    let nickname: String?
    let avatar: String?
    let contribution: DoubleOrString?
    let rank: Int?

    /// H5 hostBottomMarquee.vue :29 · `Number(it?.diamonds)` 判非 0 才展示（否则视作 placeholder）
    var diamondsValue: Double { contribution?.doubleValue ?? 0 }

    /// H5 hostBottomMarquee.vue :32 · rank 1-based → 0-based 数组索引
    var rankIdx: Int { max(0, (rank ?? 1) - 1) }

    enum CodingKeys: String, CodingKey {
        case uid, nickname, avatar, contribution, rank
        case senderUid   // H5 别名（LeaderboardItem 用 senderUid）
        case diamonds    // H5 别名（LeaderboardItem 用 diamonds）
    }

    init(uid: Int64, nickname: String? = nil, avatar: String? = nil, contribution: DoubleOrString? = nil, rank: Int? = nil) {
        self.uid = uid
        self.nickname = nickname
        self.avatar = avatar
        self.contribution = contribution
        self.rank = rank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // uid: uid > senderUid 双 alias（H5 后端 LeaderboardItem 返 senderUid）
        if let i = try? c.decode(Int64.self, forKey: .uid) {
            uid = i
        } else if let s = try? c.decode(String.self, forKey: .uid), let i = Int64(s) {
            uid = i
        } else if let i = try? c.decode(Int64.self, forKey: .senderUid) {
            uid = i
        } else if let s = try? c.decode(String.self, forKey: .senderUid), let i = Int64(s) {
            uid = i
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .uid, in: c,
                debugDescription: "uid/senderUid neither Int64 nor numeric String")
        }
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        // contribution: contribution > diamonds 双 alias
        contribution = try (c.decodeIfPresent(DoubleOrString.self, forKey: .contribution))
            ?? c.decodeIfPresent(DoubleOrString.self, forKey: .diamonds)
        // H5 直接消费 `rank`，不限制 JSON 数值类型；服务端灰度会把排名序列化成字符串。
        // 不能因单个榜单项 rank="1" 让整个 Top3 数组 decode 失败并被 state 回退为空。
        if let value = try? c.decode(Int.self, forKey: .rank) {
            rank = value
        } else if let value = try? c.decode(String.self, forKey: .rank), let parsed = Int(value) {
            rank = parsed
        } else {
            rank = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encodeIfPresent(contribution, forKey: .contribution)
        try c.encodeIfPresent(rank, forKey: .rank)
    }
}
