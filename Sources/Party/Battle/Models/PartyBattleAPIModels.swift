import Foundation

// MARK: - Requests
//
// 严格按 spec 附录 C 定义。api-http-method-strict rule：POST/GET method + path 追 H5 store 层实际调用点，
// 不可从 H5 `src/api/*/index.ts` 第一个导出反推；本 F-1a 首次真机 log 校对时确认。

struct PartyBattleStartRequest: Encodable {
    let roomId: String
    let templateId: String
    let durationSec: Int
    let hostInitialTeam: Int?
}

struct PartyBattleStateRequest: Encodable {
    let roomId: String
}

struct PartyBattleSwitchTeamRequest: Encodable {
    let pkId: String
    let targetTeam: Int
}

struct PartyBattleApplyMicRequest: Encodable {
    let pkId: String
    let desiredTeam: Int?
    let desiredMicId: Int?
}

struct PartyBattleStartNowRequest: Encodable {
    let pkId: String
}

struct PartyBattleForceEndRequest: Encodable {
    let pkId: String
}

struct PartyBattleSettlementRequest: Encodable {
    let pkId: String
}

struct PartyBattleApproveApplyRequest: Encodable {
    let pkId: String
    let applyId: Int
    let approve: Bool
}

// MARK: - Responses

/// PartyBattle 模板（对齐 H5 partyBattle/index.ts PartyBattleTemplate）
///
/// 字段来源：/party/battle/templates GET response
/// - `defaultDuration` H5 侧字段名，对应我们 `durationSec`
/// - `selectingDuration` SELECTING 阶段秒数（服务端可配置，默认 60）
/// - `cooldownDuration` PK 结束冷却期秒数（服务端可配置，默认 60）
struct PartyBattleTemplate: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
    let durationSec: Int?
    let selectingDuration: Int?
    let cooldownDuration: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case durationSec
        case defaultDuration  // H5 字段名 alias
        case selectingDuration, cooldownDuration
    }

    init(id: String, name: String? = nil, durationSec: Int? = nil,
         selectingDuration: Int? = nil, cooldownDuration: Int? = nil) {
        self.id = id
        self.name = name
        self.durationSec = durationSec
        self.selectingDuration = selectingDuration
        self.cooldownDuration = cooldownDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id String/Int 兼容
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else if let i = try? c.decode(Int.self, forKey: .id) { id = String(i) }
        else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "id") }
        name = try c.decodeIfPresent(String.self, forKey: .name)
        // durationSec / defaultDuration 二选一（H5 用 defaultDuration，我们兼容两名）
        durationSec = try c.decodeIfPresent(Int.self, forKey: .durationSec)
            ?? c.decodeIfPresent(Int.self, forKey: .defaultDuration)
        selectingDuration = try c.decodeIfPresent(Int.self, forKey: .selectingDuration)
        cooldownDuration = try c.decodeIfPresent(Int.self, forKey: .cooldownDuration)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(durationSec, forKey: .durationSec)
        try c.encodeIfPresent(selectingDuration, forKey: .selectingDuration)
        try c.encodeIfPresent(cooldownDuration, forKey: .cooldownDuration)
    }
}

/// 房主 apiPartyBattleStart response（对齐 H5 PartyBattleStartResp · partyBattle.ts:120-142 消费字段）
///
/// H5 line 122-126 consume:
/// - `pkId`：新一场 PK 主键（后续所有 action 依赖）
/// - `selectingDurationSec`：SELECTING 阶段时长（服务端配置的默认 60）
/// - `durationSec`：RUNNING 阶段时长（服务端可能 override 用户选值）
/// - `templateName`：模板名（H5 顶部 HUD title 展示）
struct PartyBattleStartResponse: Decodable {
    let pkId: String?
    let battleId: Int?
    let selectingDurationSec: Int?
    let durationSec: Int?
    let templateName: String?

    enum CodingKeys: String, CodingKey {
        case pkId, battlePkId, id
        case battleId, selectingDurationSec, durationSec, templateName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // sapi 灰度环境会把 Long 序列化为 Number；同时兼容历史的 battlePkId / id。
        pkId = Self.decodeString(from: c, key: .pkId)
            ?? Self.decodeString(from: c, key: .battlePkId)
            ?? Self.decodeString(from: c, key: .id)
        battleId = Self.decodeInt(from: c, key: .battleId)
        selectingDurationSec = Self.decodeInt(from: c, key: .selectingDurationSec)
        durationSec = Self.decodeInt(from: c, key: .durationSec)
        templateName = try c.decodeIfPresent(String.self, forKey: .templateName)
    }

    private static func decodeString(
        from c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) -> String? {
        if let value = try? c.decode(String.self, forKey: key), !value.isEmpty { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return String(value) }
        return nil
    }

    private static func decodeInt(
        from c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(String.self, forKey: key), let value = Int(value) { return value }
        return nil
    }
}

struct PartyBattleApplyMicResponse: Codable {
    let applyId: Int
    let desiredTeam: Int?
    let desiredMicId: Int?
}

/// 战报结算 response。
/// - `durationSec` A6 待真机验证：自然结束必有；forceEnd 是否有？
/// - `endedEarly` 为 true 表示强制结束；spec §12 A6 归 F-1a milestone 收敛必答项
/// 战报结算 response（对齐 H5 endedSettlement.vue 消费字段）
///
/// H5 字段命名（服务端契约）：
/// - `giftSendMvp / giftReceiveMvp` MVP 送礼/收礼（BattleMvp with team + diamonds/gems）
/// - `redTop3 / blueTop3` 双队 Top3 送礼榜（每项含 diamonds）
/// - `redCrownUid / blueCrownUid` 双队皇冠归属（fallback MVP 用）
///
/// 保留 `mvpSender / mvpReceiver` 作为旧字段别名（若旧后端返旧名也能 decode）
struct PartyBattleSettlementResponse: Codable {
    let pkId: String
    let durationSec: Int?
    let winnerTeam: Int?
    let redScore: DoubleOrString?
    let blueScore: DoubleOrString?
    let redGems: DoubleOrString?
    let blueGems: DoubleOrString?
    let giftSendMvp: BattleMvp?
    let giftReceiveMvp: BattleMvp?
    let redTop3: [BattleTopMember]?
    let blueTop3: [BattleTopMember]?
    let redCrownUid: Int64?
    let blueCrownUid: Int64?
    let endedEarly: Bool?
    let cooldownLeftSec: Int?

    // 旧字段别名（保持向后兼容旧后端）
    var mvpSender: BattleMvp? { giftSendMvp }
    var mvpReceiver: BattleMvp? { giftReceiveMvp }

    enum CodingKeys: String, CodingKey {
        case pkId, durationSec, winnerTeam
        case redScore, blueScore, redGems, blueGems
        case giftSendMvp, giftReceiveMvp
        case mvpSender, mvpReceiver  // 旧名别名（decode 时也接受）
        case redTop3, blueTop3, redCrownUid, blueCrownUid
        case endedEarly, cooldownLeftSec
    }

    init(
        pkId: String,
        durationSec: Int? = nil,
        winnerTeam: Int? = nil,
        redScore: DoubleOrString? = nil,
        blueScore: DoubleOrString? = nil,
        redGems: DoubleOrString? = nil,
        blueGems: DoubleOrString? = nil,
        giftSendMvp: BattleMvp? = nil,
        giftReceiveMvp: BattleMvp? = nil,
        redTop3: [BattleTopMember]? = nil,
        blueTop3: [BattleTopMember]? = nil,
        redCrownUid: Int64? = nil,
        blueCrownUid: Int64? = nil,
        endedEarly: Bool? = nil,
        cooldownLeftSec: Int? = nil
    ) {
        self.pkId = pkId
        self.durationSec = durationSec
        self.winnerTeam = winnerTeam
        self.redScore = redScore
        self.blueScore = blueScore
        self.redGems = redGems
        self.blueGems = blueGems
        self.giftSendMvp = giftSendMvp
        self.giftReceiveMvp = giftReceiveMvp
        self.redTop3 = redTop3
        self.blueTop3 = blueTop3
        self.redCrownUid = redCrownUid
        self.blueCrownUid = blueCrownUid
        self.endedEarly = endedEarly
        self.cooldownLeftSec = cooldownLeftSec
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pkId = try c.decode(String.self, forKey: .pkId)
        durationSec = try c.decodeIfPresent(Int.self, forKey: .durationSec)
        winnerTeam = try c.decodeIfPresent(Int.self, forKey: .winnerTeam)
        redScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .redScore)
        blueScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .blueScore)
        redGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .redGems)
        blueGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .blueGems)
        // 新旧字段双 alias decode（H5 用 giftSendMvp/giftReceiveMvp；旧后端可能返 mvpSender/mvpReceiver）
        giftSendMvp = try (c.decodeIfPresent(BattleMvp.self, forKey: .giftSendMvp))
            ?? c.decodeIfPresent(BattleMvp.self, forKey: .mvpSender)
        giftReceiveMvp = try (c.decodeIfPresent(BattleMvp.self, forKey: .giftReceiveMvp))
            ?? c.decodeIfPresent(BattleMvp.self, forKey: .mvpReceiver)
        redTop3 = try c.decodeIfPresent([BattleTopMember].self, forKey: .redTop3)
        blueTop3 = try c.decodeIfPresent([BattleTopMember].self, forKey: .blueTop3)
        redCrownUid = try Self.decodeOptionalInt64OrString(from: c, key: .redCrownUid)
        blueCrownUid = try Self.decodeOptionalInt64OrString(from: c, key: .blueCrownUid)
        endedEarly = try c.decodeIfPresent(Bool.self, forKey: .endedEarly)
        cooldownLeftSec = try c.decodeIfPresent(Int.self, forKey: .cooldownLeftSec)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pkId, forKey: .pkId)
        try c.encodeIfPresent(durationSec, forKey: .durationSec)
        try c.encodeIfPresent(winnerTeam, forKey: .winnerTeam)
        try c.encodeIfPresent(redScore, forKey: .redScore)
        try c.encodeIfPresent(blueScore, forKey: .blueScore)
        try c.encodeIfPresent(redGems, forKey: .redGems)
        try c.encodeIfPresent(blueGems, forKey: .blueGems)
        try c.encodeIfPresent(giftSendMvp, forKey: .giftSendMvp)
        try c.encodeIfPresent(giftReceiveMvp, forKey: .giftReceiveMvp)
        try c.encodeIfPresent(redTop3, forKey: .redTop3)
        try c.encodeIfPresent(blueTop3, forKey: .blueTop3)
        try c.encodeIfPresent(redCrownUid, forKey: .redCrownUid)
        try c.encodeIfPresent(blueCrownUid, forKey: .blueCrownUid)
        try c.encodeIfPresent(endedEarly, forKey: .endedEarly)
        try c.encodeIfPresent(cooldownLeftSec, forKey: .cooldownLeftSec)
    }

    private static func decodeOptionalInt64OrString(
        from c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) throws -> Int64? {
        if let i = try? c.decode(Int64.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), !s.isEmpty, let i = Int64(s) { return i }
        return nil
    }
}

/// MVP 卡数据（对齐 H5 giftSendMvp / giftReceiveMvp payload）
///
/// H5 字段：uid, nickname, avatar, team, diamonds, gems（后两字段任一存在即可展示金额；gems 优先展示）
struct BattleMvp: Codable, Equatable {
    let uid: Int64
    let nickname: String?
    let avatar: String?
    let team: Int?                  // 1=红 2=蓝
    let diamonds: DoubleOrString?
    let gems: DoubleOrString?

    /// 展示金额（gems 优先，回落 diamonds，最后 0）
    var displayValue: Double {
        gems?.doubleValue ?? diamonds?.doubleValue ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case uid, nickname, avatar, team, diamonds, gems
        case value  // 旧字段别名
    }

    init(
        uid: Int64,
        nickname: String? = nil,
        avatar: String? = nil,
        team: Int? = nil,
        diamonds: DoubleOrString? = nil,
        gems: DoubleOrString? = nil
    ) {
        self.uid = uid
        self.nickname = nickname
        self.avatar = avatar
        self.team = team
        self.diamonds = diamonds
        self.gems = gems
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
        team = try c.decodeIfPresent(Int.self, forKey: .team)
        // 新旧字段双 alias：H5 用 diamonds/gems；旧后端可能返 value
        diamonds = try (c.decodeIfPresent(DoubleOrString.self, forKey: .diamonds))
            ?? c.decodeIfPresent(DoubleOrString.self, forKey: .value)
        gems = try c.decodeIfPresent(DoubleOrString.self, forKey: .gems)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encodeIfPresent(team, forKey: .team)
        try c.encodeIfPresent(diamonds, forKey: .diamonds)
        try c.encodeIfPresent(gems, forKey: .gems)
    }
}

/// PK 上麦待审核列表 response。
///
/// H5 当前接口契约使用 `applications`；早期 iOS 实现曾假定为 `list`。
/// 两者同时兼容，避免灰度期间因字段名不同而使房主/房管看到空申请列表。
struct PartyBattleApplicationsResponse: Codable {
    let list: [PartyBattleApplication]

    enum CodingKeys: String, CodingKey {
        case applications, list
    }

    init(list: [PartyBattleApplication]) {
        self.list = list
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        list = try c.decodeIfPresent([PartyBattleApplication].self, forKey: .applications)
            ?? c.decodeIfPresent([PartyBattleApplication].self, forKey: .list)
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(list, forKey: .applications)
    }
}

struct PartyBattleApplication: Codable, Identifiable, Equatable {
    var id: Int { applyId }
    let applyId: Int
    let uid: Int64
    let nickname: String?
    let avatar: String?
    let desiredTeam: Int?
    let desiredMicId: Int?
    let createdAt: Int64?

    enum CodingKeys: String, CodingKey {
        case applyId, uid, nickname, avatar, desiredTeam, desiredMicId
        case createdAt, createTimeMs
    }

    init(
        applyId: Int,
        uid: Int64,
        nickname: String? = nil,
        avatar: String? = nil,
        desiredTeam: Int? = nil,
        desiredMicId: Int? = nil,
        createdAt: Int64? = nil
    ) {
        self.applyId = applyId
        self.uid = uid
        self.nickname = nickname
        self.avatar = avatar
        self.desiredTeam = desiredTeam
        self.desiredMicId = desiredMicId
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applyId = try c.decode(Int.self, forKey: .applyId)
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
        desiredTeam = try c.decodeIfPresent(Int.self, forKey: .desiredTeam)
        desiredMicId = try c.decodeIfPresent(Int.self, forKey: .desiredMicId)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt)
            ?? c.decodeIfPresent(Int64.self, forKey: .createTimeMs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(applyId, forKey: .applyId)
        try c.encode(uid, forKey: .uid)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encodeIfPresent(desiredTeam, forKey: .desiredTeam)
        try c.encodeIfPresent(desiredMicId, forKey: .desiredMicId)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}
