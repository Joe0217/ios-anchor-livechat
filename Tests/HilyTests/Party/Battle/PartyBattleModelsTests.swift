import XCTest

final class PartyBattleModelsTests: XCTestCase {

    // MARK: - PartyBattleState decode fixture（H5 partyBattle.ts state 结构派生）
    func testBattleStateDecode_fixtureFromH5State() throws {
        let json = """
        {
          "pkId":"pk_1001",
          "battleId":1,
          "roomId":1234567890123456,
          "status":2,
          "templateId":1,
          "templateName":"3v3",
          "selectingDurationSec":60,
          "durationSec":300,
          "leftSec":180,
          "hostUid":1000001,
          "hostRole":1,
          "currentUserTeam":1,
          "redTeam":{"count":3,"members":[{"uid":10001,"nickname":"A","avatar":"a.png","personalScore":100.5,"personalGems":90}]},
          "blueTeam":{"count":3,"members":[]},
          "neutral":{"count":0,"members":[]},
          "redTop":[{"uid":10001,"nickname":"A","avatar":"a.png","contribution":"999.5"}],
          "blueTop":[],
          "redCrownUid":10001,
          "blueCrownUid":null,
          "redScore":1200.5,
          "blueScore":"800",
          "redGems":1000,
          "blueGems":700,
          "winnerTeam":null,
          "cooldownLeftSec":0
        }
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(PartyBattleState.self, from: json)
        XCTAssertEqual(state.pkId, "pk_1001")
        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.roomId, 1234567890123456)
        XCTAssertEqual(state.redScore.doubleValue, 1200.5)
        XCTAssertEqual(state.blueScore.doubleValue, 800)
        XCTAssertEqual(state.redGems?.doubleValue, 1000)
        XCTAssertEqual(state.redTeam.members.count, 1)
        XCTAssertEqual(state.redTop.first?.contribution?.doubleValue, 999.5)
        XCTAssertNil(state.blueCrownUid)
        XCTAssertNil(state.winnerTeam)
    }

    // MARK: - roomId Int64/String 双兼容
    func testBattleStateDecode_roomIdAsString() throws {
        let json = """
        {
          "pkId":"pk_2","battleId":2,"roomId":"9007199254740993",
          "status":1,"selectingDurationSec":60,"durationSec":300,"leftSec":60,
          "hostUid":"1000001","hostRole":1,
          "redTeam":{"count":0,"members":[]},"blueTeam":{"count":0,"members":[]},"neutral":{"count":0,"members":[]},
          "redTop":[],"blueTop":[],
          "redScore":0,"blueScore":0,"cooldownLeftSec":0
        }
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(PartyBattleState.self, from: json)
        XCTAssertEqual(state.roomId, 9007199254740993)  // 超 Double 精度的 Long 走 String 分支
        XCTAssertEqual(state.hostUid, 1000001)
    }

    // MARK: - BattleMember uid String/Int64 双兼容
    func testBattleMemberUidStringInt64Compat() throws {
        let jsonStr = "{\"uid\":\"10001\",\"nickname\":\"A\"}".data(using: .utf8)!
        let jsonInt = "{\"uid\":10001,\"nickname\":\"A\"}".data(using: .utf8)!
        let mStr = try JSONDecoder().decode(BattleMember.self, from: jsonStr)
        let mInt = try JSONDecoder().decode(BattleMember.self, from: jsonInt)
        XCTAssertEqual(mStr.uid, 10001)
        XCTAssertEqual(mInt.uid, 10001)
        XCTAssertEqual(mStr.id, "10001")
    }

    // MARK: - BattleMember 缺可选字段解码兼容
    func testBattleMemberDecode_partialFields() throws {
        let json = "{\"uid\":123}".data(using: .utf8)!
        let m = try JSONDecoder().decode(BattleMember.self, from: json)
        XCTAssertEqual(m.uid, 123)
        XCTAssertNil(m.nickname)
        XCTAssertNil(m.personalScore)
        XCTAssertNil(m.isCrownHolder)
    }

    // MARK: - BattleTeam 空数组兼容
    func testBattleTeamDecode_emptyMembers() throws {
        let json = "{\"count\":0,\"members\":[]}".data(using: .utf8)!
        let t = try JSONDecoder().decode(BattleTeam.self, from: json)
        XCTAssertEqual(t.count, 0)
        XCTAssertTrue(t.members.isEmpty)
    }

    // MARK: - Encode round-trip 稳定
    func testBattleMemberEncode_roundTrip() throws {
        let orig = BattleMember(
            uid: 10001,
            nickname: "Alice",
            avatar: "a.png",
            personalScore: .double(100.5),
            personalGems: .double(90),
            isCrownHolder: true
        )
        let encoded = try JSONEncoder().encode(orig)
        let decoded = try JSONDecoder().decode(BattleMember.self, from: encoded)
        XCTAssertEqual(decoded, orig)
    }
}
