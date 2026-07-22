import Foundation

// MARK: - 12 attachType payload Codable
//
// spec §4.6 + §5.1 字段映射；对齐 im-payload-real-log-over-code-assumption rule：
// 字段名首次真机 log 校对（F-1a milestone R-16）后按实际 payload 补 CodingKeys 别名。
// 全部字段用 decodeIfPresent 兼容后端 partial payload。

// MARK: - 1100 SelectingStart

/// 1100 SELECTING 开始（房主发起 PK 时服务端广播）
struct BattleSelectingStartPayload: Codable, Equatable {
    let pkId: String?
    let battleId: Int?
    let roomId: Int64?
    let hostUid: Int64?
    let hostRole: Int?
    let templateId: Int?
    let templateName: String?
    let selectingDurationSec: Int?
    let durationSec: Int?
    let leftSec: Int?
    let redTeam: BattleTeam?
    let blueTeam: BattleTeam?
    let neutral: BattleTeam?
    let redTop: [BattleTopMember]?
    let blueTop: [BattleTopMember]?

    enum CodingKeys: String, CodingKey {
        case pkId, battleId, roomId, hostUid, hostRole
        case templateId, templateName
        case selectingDurationSec, durationSec, leftSec
        case redTeam, blueTeam, neutral, redTop, blueTop
    }

    init(
        pkId: String? = nil,
        battleId: Int? = nil,
        roomId: Int64? = nil,
        hostUid: Int64? = nil,
        hostRole: Int? = nil,
        templateId: Int? = nil,
        templateName: String? = nil,
        selectingDurationSec: Int? = nil,
        durationSec: Int? = nil,
        leftSec: Int? = nil,
        redTeam: BattleTeam? = nil,
        blueTeam: BattleTeam? = nil,
        neutral: BattleTeam? = nil,
        redTop: [BattleTopMember]? = nil,
        blueTop: [BattleTopMember]? = nil
    ) {
        self.pkId = pkId
        self.battleId = battleId
        self.roomId = roomId
        self.hostUid = hostUid
        self.hostRole = hostRole
        self.templateId = templateId
        self.templateName = templateName
        self.selectingDurationSec = selectingDurationSec
        self.durationSec = durationSec
        self.leftSec = leftSec
        self.redTeam = redTeam
        self.blueTeam = blueTeam
        self.neutral = neutral
        self.redTop = redTop
        self.blueTop = blueTop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pkId = try c.decodeIfPresent(String.self, forKey: .pkId)
        battleId = try c.decodeIfPresent(Int.self, forKey: .battleId)
        roomId = try Self.decodeOptionalInt64OrString(from: c, key: .roomId)
        hostUid = try Self.decodeOptionalInt64OrString(from: c, key: .hostUid)
        hostRole = try c.decodeIfPresent(Int.self, forKey: .hostRole)
        templateId = try c.decodeIfPresent(Int.self, forKey: .templateId)
        templateName = try c.decodeIfPresent(String.self, forKey: .templateName)
        selectingDurationSec = try c.decodeIfPresent(Int.self, forKey: .selectingDurationSec)
        durationSec = try c.decodeIfPresent(Int.self, forKey: .durationSec)
        leftSec = try c.decodeIfPresent(Int.self, forKey: .leftSec)
        redTeam = try c.decodeIfPresent(BattleTeam.self, forKey: .redTeam)
        blueTeam = try c.decodeIfPresent(BattleTeam.self, forKey: .blueTeam)
        neutral = try c.decodeIfPresent(BattleTeam.self, forKey: .neutral)
        redTop = try c.decodeIfPresent([BattleTopMember].self, forKey: .redTop)
        blueTop = try c.decodeIfPresent([BattleTopMember].self, forKey: .blueTop)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pkId, forKey: .pkId)
        try c.encodeIfPresent(battleId, forKey: .battleId)
        try c.encodeIfPresent(roomId, forKey: .roomId)
        try c.encodeIfPresent(hostUid, forKey: .hostUid)
        try c.encodeIfPresent(hostRole, forKey: .hostRole)
        try c.encodeIfPresent(templateId, forKey: .templateId)
        try c.encodeIfPresent(templateName, forKey: .templateName)
        try c.encodeIfPresent(selectingDurationSec, forKey: .selectingDurationSec)
        try c.encodeIfPresent(durationSec, forKey: .durationSec)
        try c.encodeIfPresent(leftSec, forKey: .leftSec)
        try c.encodeIfPresent(redTeam, forKey: .redTeam)
        try c.encodeIfPresent(blueTeam, forKey: .blueTeam)
        try c.encodeIfPresent(neutral, forKey: .neutral)
        try c.encodeIfPresent(redTop, forKey: .redTop)
        try c.encodeIfPresent(blueTop, forKey: .blueTop)
    }

    fileprivate static func decodeOptionalInt64OrString<K: CodingKey>(
        from c: KeyedDecodingContainer<K>,
        key: K
    ) throws -> Int64? {
        if let i = try? c.decode(Int64.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), !s.isEmpty, let i = Int64(s) {
            return i
        }
        return nil
    }
}

// MARK: - 1101 TeamMemberChange

/// 1101 参战成员变化（切队、观众上麦、下麦等触发）
/// 关键（对齐 spec §3.4.2）：payload 中 personalScore/personalGems 缺失时 store 层 preservePersonal 按 uid 从旧 members 回填
struct BattleTeamMemberChangePayload: Codable, Equatable {
    let pkId: String?
    let redTeam: BattleTeam?
    let blueTeam: BattleTeam?
    let neutral: BattleTeam?
}

// MARK: - 1102 ApplyPushed

/// 1102 观众上麦申请推送到全房（H5 用户端 `pushApply` 无 role gating，UI 层由 role gate 显示）
struct BattleApplyPushedPayload: Codable, Equatable {
    let pkId: String?
    let applyId: Int?
    let uid: Int64?
    let nickname: String?
    let avatar: String?
    let desiredTeam: Int?
    let desiredMicId: Int?
    let createdAt: Int64?

    enum CodingKeys: String, CodingKey {
        case pkId, applyId, uid, nickname, avatar, desiredTeam, desiredMicId
        case createdAt, createTimeMs
    }

    init(
        pkId: String? = nil,
        applyId: Int? = nil,
        uid: Int64? = nil,
        nickname: String? = nil,
        avatar: String? = nil,
        desiredTeam: Int? = nil,
        desiredMicId: Int? = nil,
        createdAt: Int64? = nil
    ) {
        self.pkId = pkId
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
        pkId = try c.decodeIfPresent(String.self, forKey: .pkId)
        applyId = try c.decodeIfPresent(Int.self, forKey: .applyId)
        uid = try BattleSelectingStartPayload.decodeOptionalInt64OrString(from: c, key: .uid)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        desiredTeam = try c.decodeIfPresent(Int.self, forKey: .desiredTeam)
        desiredMicId = try c.decodeIfPresent(Int.self, forKey: .desiredMicId)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt)
            ?? c.decodeIfPresent(Int64.self, forKey: .createTimeMs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pkId, forKey: .pkId)
        try c.encodeIfPresent(applyId, forKey: .applyId)
        try c.encodeIfPresent(uid, forKey: .uid)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encodeIfPresent(desiredTeam, forKey: .desiredTeam)
        try c.encodeIfPresent(desiredMicId, forKey: .desiredMicId)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

// MARK: - 1103 RunningStart

/// 1103 RUNNING 阶段开始（SELECTING 期倒计时到 0 或房主主动 startNow）
struct BattleRunningStartPayload: Codable, Equatable {
    let pkId: String?
    let durationSec: Int?
    let leftSec: Int?
}

// MARK: - 1105 LeaderboardMerged

/// 1105 分数板更新（红蓝分数/gems/crown 增量；200ms trailing 聚合入口）
/// 关键（对齐 spec §3.4.4）：Router → store.enqueueLeaderboardPayload；首条 200ms 后 flush，中间到的合并字段
struct BattleLeaderboardMergedPayload: Codable, Equatable {
    let pkId: String?
    let redScore: DoubleOrString?
    let blueScore: DoubleOrString?
    let redGems: DoubleOrString?
    let blueGems: DoubleOrString?
    let redCrownUid: Int64?
    let blueCrownUid: Int64?
    let redTop: [BattleTopMember]?
    let blueTop: [BattleTopMember]?
    /// H5 老版兼容（partyBattle.ts:454-457）：单队推送时 `team=1|2 + teamScore` 派生 redScore/blueScore
    /// - team=1 → redScore = teamScore
    /// - team=2 → blueScore = teamScore
    /// 新版直接带 redScore + blueScore，team/teamScore 均 nil，不影响
    let team: Int?
    let teamScore: DoubleOrString?

    enum CodingKeys: String, CodingKey {
        case pkId, redScore, blueScore, redGems, blueGems, redCrownUid, blueCrownUid, redTop, blueTop
        case team, teamScore
    }

    init(
        pkId: String? = nil,
        redScore: DoubleOrString? = nil,
        blueScore: DoubleOrString? = nil,
        redGems: DoubleOrString? = nil,
        blueGems: DoubleOrString? = nil,
        redCrownUid: Int64? = nil,
        blueCrownUid: Int64? = nil,
        redTop: [BattleTopMember]? = nil,
        blueTop: [BattleTopMember]? = nil,
        team: Int? = nil,
        teamScore: DoubleOrString? = nil
    ) {
        self.pkId = pkId
        self.redScore = redScore
        self.blueScore = blueScore
        self.redGems = redGems
        self.blueGems = blueGems
        self.redCrownUid = redCrownUid
        self.blueCrownUid = blueCrownUid
        self.redTop = redTop
        self.blueTop = blueTop
        self.team = team
        self.teamScore = teamScore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pkId = try c.decodeIfPresent(String.self, forKey: .pkId)
        redScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .redScore)
        blueScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .blueScore)
        redGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .redGems)
        blueGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .blueGems)
        redCrownUid = try BattleSelectingStartPayload.decodeOptionalInt64OrString(from: c, key: .redCrownUid)
        blueCrownUid = try BattleSelectingStartPayload.decodeOptionalInt64OrString(from: c, key: .blueCrownUid)
        redTop = try c.decodeIfPresent([BattleTopMember].self, forKey: .redTop)
        blueTop = try c.decodeIfPresent([BattleTopMember].self, forKey: .blueTop)
        team = try c.decodeIfPresent(Int.self, forKey: .team)
        teamScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .teamScore)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pkId, forKey: .pkId)
        try c.encodeIfPresent(redScore, forKey: .redScore)
        try c.encodeIfPresent(blueScore, forKey: .blueScore)
        try c.encodeIfPresent(redGems, forKey: .redGems)
        try c.encodeIfPresent(blueGems, forKey: .blueGems)
        try c.encodeIfPresent(redCrownUid, forKey: .redCrownUid)
        try c.encodeIfPresent(blueCrownUid, forKey: .blueCrownUid)
        try c.encodeIfPresent(redTop, forKey: .redTop)
        try c.encodeIfPresent(blueTop, forKey: .blueTop)
    }
}

// MARK: - 1106 CrownHolderUpdate

/// 1106 皇冠归属变更（对齐 H5 partyBattle.ts:502-524 · payload 用 team+oldUid+newUid 精准更新单队 members isCrownHolder）
///
/// 后端字段（H5 消费）：
/// - `team`：1=红队 2=蓝队（用于定位 members 数组）
/// - `oldUid`：失去皇冠的 uid（该 member.isCrownHolder = false）
/// - `newUid`：获得皇冠的 uid（该 member.isCrownHolder = true）
///
/// 保留 `redCrownUid/blueCrownUid` 顶层字段作为旧后端兼容 alias（若老后端返顶层，也能解码）
struct BattleCrownHolderUpdatePayload: Codable, Equatable {
    let pkId: String?
    let team: Int?
    let oldUid: Int64?
    let newUid: Int64?
    /// 老后端兼容（顶层 crownUid 字段）
    let redCrownUid: Int64?
    let blueCrownUid: Int64?

    enum CodingKeys: String, CodingKey {
        case pkId, team, oldUid, newUid, redCrownUid, blueCrownUid
    }

    init(
        pkId: String? = nil,
        team: Int? = nil,
        oldUid: Int64? = nil,
        newUid: Int64? = nil,
        redCrownUid: Int64? = nil,
        blueCrownUid: Int64? = nil
    ) {
        self.pkId = pkId
        self.team = team
        self.oldUid = oldUid
        self.newUid = newUid
        self.redCrownUid = redCrownUid
        self.blueCrownUid = blueCrownUid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pkId = try c.decodeIfPresent(String.self, forKey: .pkId)
        team = try c.decodeIfPresent(Int.self, forKey: .team)
        oldUid = try BattleSelectingStartPayload.decodeOptionalInt64OrString(from: c, key: .oldUid)
        newUid = try BattleSelectingStartPayload.decodeOptionalInt64OrString(from: c, key: .newUid)
        redCrownUid = try BattleSelectingStartPayload.decodeOptionalInt64OrString(from: c, key: .redCrownUid)
        blueCrownUid = try BattleSelectingStartPayload.decodeOptionalInt64OrString(from: c, key: .blueCrownUid)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pkId, forKey: .pkId)
        try c.encodeIfPresent(team, forKey: .team)
        try c.encodeIfPresent(oldUid, forKey: .oldUid)
        try c.encodeIfPresent(newUid, forKey: .newUid)
        try c.encodeIfPresent(redCrownUid, forKey: .redCrownUid)
        try c.encodeIfPresent(blueCrownUid, forKey: .blueCrownUid)
    }
}

// MARK: - 1109 EndStub

/// 1109 PK 结束通知
/// 关键（对齐 spec §1.1 onEnd 分类字段）：
/// - stub：无 durationSec（IM 1109 stub），store 层 cooldownLeftSec fallback
/// - full：含 durationSec（后端补发完整 settlement 或 API 拉取），store 层 showSettlement=true
struct BattleEndPayload: Codable, Equatable {
    let pkId: String?
    let winnerTeam: Int?
    let endedEarly: Bool?
    let cooldownLeftSec: Int?
    let durationSec: Int?
    let redScore: DoubleOrString?
    let blueScore: DoubleOrString?
    let redGems: DoubleOrString?
    let blueGems: DoubleOrString?
}

// MARK: - 1110 Broadcast

/// 1110 公屏广播（走 `addPartyChatRecordsMsg` 按 kind 分公屏消息展示）
/// 已知 kind:
/// - `victory` 胜利播报
/// - `force_ended` 强制结束播报
/// - `mvp` MVP 播报
/// - `selecting_started` 选队开始（H5 端忽略，iOS 保留）
struct BattleBroadcastPayload: Codable, Equatable {
    let pkId: String?
    let kind: String?
    let title: String?
    let subtitle: String?
    let winnerTeam: Int?
    /// `kind=victory` 的原始分数与展示 gems（H5 party.js:550-555）。
    /// 1110 可能早于 1109 到达，公屏不能回退到尚未更新的 store 状态。
    let redScore: DoubleOrString?
    let blueScore: DoubleOrString?
    let redGems: DoubleOrString?
    let blueGems: DoubleOrString?
    /// `kind=mvp` 的实际字段（H5 party.js:569-573）。
    let mvpName: String?
    let team: Int?
    let total: DoubleOrString?
    // 旧字段保留兼容已存在的服务端灰度 payload。
    let mvpUid: Int64?
    let mvpNickname: String?
    let mvpAvatar: String?

    enum CodingKeys: String, CodingKey {
        case pkId, kind, title, subtitle, winnerTeam
        case redScore, blueScore, redGems, blueGems
        case mvpName, team, total, mvpUid, mvpNickname, mvpAvatar
    }

    init(
        pkId: String? = nil,
        kind: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        winnerTeam: Int? = nil,
        redScore: DoubleOrString? = nil,
        blueScore: DoubleOrString? = nil,
        redGems: DoubleOrString? = nil,
        blueGems: DoubleOrString? = nil,
        mvpName: String? = nil,
        team: Int? = nil,
        total: DoubleOrString? = nil,
        mvpUid: Int64? = nil,
        mvpNickname: String? = nil,
        mvpAvatar: String? = nil
    ) {
        self.pkId = pkId
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.winnerTeam = winnerTeam
        self.redScore = redScore
        self.blueScore = blueScore
        self.redGems = redGems
        self.blueGems = blueGems
        self.mvpName = mvpName
        self.team = team
        self.total = total
        self.mvpUid = mvpUid
        self.mvpNickname = mvpNickname
        self.mvpAvatar = mvpAvatar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pkId = try c.decodeIfPresent(String.self, forKey: .pkId)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        winnerTeam = try c.decodeIfPresent(Int.self, forKey: .winnerTeam)
        redScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .redScore)
        blueScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .blueScore)
        redGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .redGems)
        blueGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .blueGems)
        mvpName = try c.decodeIfPresent(String.self, forKey: .mvpName)
        team = try c.decodeIfPresent(Int.self, forKey: .team)
        total = try c.decodeIfPresent(DoubleOrString.self, forKey: .total)
        mvpUid = try BattleSelectingStartPayload.decodeOptionalInt64OrString(from: c, key: .mvpUid)
        mvpNickname = try c.decodeIfPresent(String.self, forKey: .mvpNickname)
        mvpAvatar = try c.decodeIfPresent(String.self, forKey: .mvpAvatar)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pkId, forKey: .pkId)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encodeIfPresent(winnerTeam, forKey: .winnerTeam)
        try c.encodeIfPresent(redScore, forKey: .redScore)
        try c.encodeIfPresent(blueScore, forKey: .blueScore)
        try c.encodeIfPresent(redGems, forKey: .redGems)
        try c.encodeIfPresent(blueGems, forKey: .blueGems)
        try c.encodeIfPresent(mvpName, forKey: .mvpName)
        try c.encodeIfPresent(team, forKey: .team)
        try c.encodeIfPresent(total, forKey: .total)
        try c.encodeIfPresent(mvpUid, forKey: .mvpUid)
        try c.encodeIfPresent(mvpNickname, forKey: .mvpNickname)
        try c.encodeIfPresent(mvpAvatar, forKey: .mvpAvatar)
    }
}

// MARK: - 1104 / 1107 / 1108 / 1111 / 1112 保留占位（无 payload struct）
//
// - 1104/1107/1108/1111：spec §5.1 目前 Router 走 fallback log（`AppLogger.party.warning("unhandled xxxx")`）
// - 1112：cooldownEnd 无 payload（Router 直接调 store.onCooldownEnd()）
// 未来若真机 log 抓到 payload 结构，回来补 struct + 迁到具体 case。
