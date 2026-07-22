import XCTest

final class PartyBattleIMPayloadsTests: XCTestCase {

    // MARK: - 1100 SelectingStart
    func test1100_selectingStart_fullPayload() throws {
        let json = """
        {
          "pkId":"pk_1","battleId":1,"roomId":1234567890,"hostUid":1000001,"hostRole":1,
          "templateId":1,"templateName":"3v3",
          "selectingDurationSec":60,"durationSec":300,"leftSec":60,
          "redTeam":{"count":1,"members":[{"uid":10001,"nickname":"A"}]},
          "blueTeam":{"count":0,"members":[]},
          "neutral":{"count":0,"members":[]},
          "redTop":[],"blueTop":[]
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleSelectingStartPayload.self, from: json)
        XCTAssertEqual(p.pkId, "pk_1")
        XCTAssertEqual(p.redTeam?.members.count, 1)
        XCTAssertEqual(p.templateName, "3v3")
    }

    func test1100_partialPayload_allOptionalNil() throws {
        let json = "{}".data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleSelectingStartPayload.self, from: json)
        XCTAssertNil(p.pkId)
        XCTAssertNil(p.redTeam)
    }

    // MARK: - 1101 TeamMemberChange preservePersonal 场景（payload 少 personalScore）
    func test1101_teamMemberChange_missingPersonalScore() throws {
        let json = """
        {"pkId":"pk_1","redTeam":{"count":1,"members":[{"uid":10001,"nickname":"A"}]}}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleTeamMemberChangePayload.self, from: json)
        XCTAssertEqual(p.pkId, "pk_1")
        // 关键：member 无 personalScore，store 层 preservePersonal 从旧 members 按 uid 回填
        XCTAssertNil(p.redTeam?.members.first?.personalScore)
    }

    // MARK: - 1102 ApplyPushed
    func test1102_applyPushed() throws {
        let json = """
        {"pkId":"pk_1","applyId":42,"uid":10001,"nickname":"A","desiredTeam":1,"desiredMicId":5}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleApplyPushedPayload.self, from: json)
        XCTAssertEqual(p.applyId, 42)
        XCTAssertEqual(p.uid, 10001)
        XCTAssertEqual(p.desiredTeam, 1)
    }

    func test1102_applyPushed_uidAsString() throws {
        let json = "{\"pkId\":\"pk_1\",\"applyId\":42,\"uid\":\"10001\"}".data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleApplyPushedPayload.self, from: json)
        XCTAssertEqual(p.uid, 10001)
    }

    func test1102_applyPushed_h5CreateTimeAlias() throws {
        let json = "{\"pkId\":\"pk_1\",\"applyId\":42,\"uid\":\"10001\",\"createTimeMs\":1720000000000}".data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleApplyPushedPayload.self, from: json)
        XCTAssertEqual(p.createdAt, 1_720_000_000_000)
    }

    // MARK: - 1103 RunningStart
    func test1103_runningStart() throws {
        let json = "{\"pkId\":\"pk_1\",\"durationSec\":300,\"leftSec\":300}".data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleRunningStartPayload.self, from: json)
        XCTAssertEqual(p.durationSec, 300)
        XCTAssertEqual(p.leftSec, 300)
    }

    // MARK: - 1105 LeaderboardMerged 200ms 聚合入口
    func test1105_leaderboardMerged_partialIncrement() throws {
        // 只带红队分数增量（蓝队 nil），store 层聚合器需合并字段
        let json = """
        {"pkId":"pk_1","redScore":1500,"redGems":1200}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleLeaderboardMergedPayload.self, from: json)
        XCTAssertEqual(p.redScore?.doubleValue, 1500)
        XCTAssertEqual(p.redGems?.doubleValue, 1200)
        XCTAssertNil(p.blueScore)
        XCTAssertNil(p.blueGems)
    }

    func test1105_leaderboardMerged_scoreAsString() throws {
        let json = "{\"pkId\":\"pk_1\",\"redScore\":\"1500.5\",\"blueScore\":\"800\"}".data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleLeaderboardMergedPayload.self, from: json)
        XCTAssertEqual(p.redScore?.doubleValue, 1500.5)
        XCTAssertEqual(p.blueScore?.doubleValue, 800)
    }

    // MARK: - 1106 CrownHolderUpdate
    func test1106_crownChanged() throws {
        let json = "{\"pkId\":\"pk_1\",\"redCrownUid\":10001,\"blueCrownUid\":20001}".data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleCrownHolderUpdatePayload.self, from: json)
        XCTAssertEqual(p.redCrownUid, 10001)
        XCTAssertEqual(p.blueCrownUid, 20001)
    }

    func test1106_crownChanged_blueNull() throws {
        let json = "{\"pkId\":\"pk_1\",\"redCrownUid\":10001,\"blueCrownUid\":null}".data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleCrownHolderUpdatePayload.self, from: json)
        XCTAssertEqual(p.redCrownUid, 10001)
        XCTAssertNil(p.blueCrownUid)
    }

    // MARK: - 1109 End stub vs full
    func test1109_end_stub_noDurationSec() throws {
        // stub：无 durationSec，store.onEnd 走 cooldown fallback 分支，不弹 settlement sheet
        let json = "{\"pkId\":\"pk_1\",\"winnerTeam\":1,\"endedEarly\":false}".data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleEndPayload.self, from: json)
        XCTAssertNil(p.durationSec)
        XCTAssertEqual(p.winnerTeam, 1)
        XCTAssertEqual(p.endedEarly, false)
    }

    func test1109_end_full_withDurationSec() throws {
        // full：含 durationSec，store.onEnd 走 showSettlement=true 分支
        let json = """
        {"pkId":"pk_1","winnerTeam":1,"endedEarly":false,"durationSec":300,"cooldownLeftSec":60,
         "redScore":1500,"blueScore":800}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleEndPayload.self, from: json)
        XCTAssertEqual(p.durationSec, 300)
        XCTAssertEqual(p.cooldownLeftSec, 60)
    }

    // MARK: - 1110 Broadcast kind 分发
    func test1110_broadcast_victoryKind() throws {
        let json = """
        {"pkId":"pk_1","kind":"victory","title":"Red Team Wins","winnerTeam":1,
         "redScore":100,"blueScore":80,"redGems":"12.5","blueGems":10}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleBroadcastPayload.self, from: json)
        XCTAssertEqual(p.kind, "victory")
        XCTAssertEqual(p.winnerTeam, 1)
        XCTAssertEqual(p.redGems?.doubleValue, 12.5)
        XCTAssertEqual(p.blueScore?.doubleValue, 80)
    }

    func test1110_broadcast_mvpKind() throws {
        let json = """
        {"pkId":"pk_1","kind":"mvp","mvpName":"Alice","team":2,"total":"88.5"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleBroadcastPayload.self, from: json)
        XCTAssertEqual(p.kind, "mvp")
        XCTAssertEqual(p.mvpName, "Alice")
        XCTAssertEqual(p.team, 2)
        XCTAssertEqual(p.total?.doubleValue, 88.5)
    }

    func test1110_broadcast_forceEndedKind() throws {
        let json = "{\"pkId\":\"pk_1\",\"kind\":\"force_ended\"}".data(using: .utf8)!
        let p = try JSONDecoder().decode(BattleBroadcastPayload.self, from: json)
        XCTAssertEqual(p.kind, "force_ended")
    }
}
