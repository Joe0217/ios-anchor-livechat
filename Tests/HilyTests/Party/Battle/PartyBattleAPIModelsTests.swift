import XCTest

final class PartyBattleAPIModelsTests: XCTestCase {

    // MARK: - Requests encode
    func testStartRequestEncode() throws {
        let req = PartyBattleStartRequest(roomId: "1234567890", templateId: "1", durationSec: 300, hostInitialTeam: 1)
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["roomId"] as? String, "1234567890")
        XCTAssertEqual(dict["templateId"] as? String, "1")
        XCTAssertEqual(dict["durationSec"] as? Int, 300)
        XCTAssertEqual(dict["hostInitialTeam"] as? Int, 1)
    }

    func testStartRequestEncode_nilTeamIsAbsent() throws {
        let req = PartyBattleStartRequest(roomId: "1", templateId: "1", durationSec: 300, hostInitialTeam: nil)
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(dict["hostInitialTeam"])
    }

    func testSwitchTeamRequestEncode() throws {
        let req = PartyBattleSwitchTeamRequest(pkId: "pk_1", targetTeam: 2)
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["pkId"] as? String, "pk_1")
        XCTAssertEqual(dict["targetTeam"] as? Int, 2)
    }

    func testApplyMicRequestEncode() throws {
        let req = PartyBattleApplyMicRequest(pkId: "pk_1", desiredTeam: 1, desiredMicId: 5)
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["pkId"] as? String, "pk_1")
        XCTAssertEqual(dict["desiredTeam"] as? Int, 1)
        XCTAssertEqual(dict["desiredMicId"] as? Int, 5)
    }

    func testStartNowRequestEncode() throws {
        let req = PartyBattleStartNowRequest(pkId: "pk_1")
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["pkId"] as? String, "pk_1")
    }

    func testForceEndRequestEncode() throws {
        let req = PartyBattleForceEndRequest(pkId: "pk_1")
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["pkId"] as? String, "pk_1")
    }

    func testApproveApplyRequestEncode() throws {
        let req = PartyBattleApproveApplyRequest(pkId: "pk_1", applyId: 42, approve: true)
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["pkId"] as? String, "pk_1")
        XCTAssertEqual(dict["applyId"] as? Int, 42)
        XCTAssertEqual(dict["approve"] as? Bool, true)
    }

    // MARK: - Responses decode
    func testTemplatesResponseDecode() throws {
        let json = "[{\"id\":\"1\",\"name\":\"3v3\",\"durationSec\":300},{\"id\":\"2\",\"name\":\"5v5\",\"durationSec\":600}]".data(using: .utf8)!
        let arr = try JSONDecoder().decode([PartyBattleTemplate].self, from: json)
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0].name, "3v3")
        XCTAssertEqual(arr[1].durationSec, 600)
    }

    func testStartResponseDecode_partialFields() throws {
        let json = "{\"pkId\":\"pk_1\"}".data(using: .utf8)!
        let r = try JSONDecoder().decode(PartyBattleStartResponse.self, from: json)
        XCTAssertEqual(r.pkId, "pk_1")
        XCTAssertNil(r.battleId)
    }

    func testApplyMicResponseDecode() throws {
        let json = "{\"applyId\":42,\"desiredTeam\":1,\"desiredMicId\":5}".data(using: .utf8)!
        let r = try JSONDecoder().decode(PartyBattleApplyMicResponse.self, from: json)
        XCTAssertEqual(r.applyId, 42)
        XCTAssertEqual(r.desiredTeam, 1)
        XCTAssertEqual(r.desiredMicId, 5)
    }

    func testSettlementResponseDecode_fullPayload() throws {
        let json = """
        {
          "pkId":"pk_1","durationSec":300,"winnerTeam":1,
          "redScore":1200,"blueScore":"800","redGems":1000,"blueGems":700,
          "mvpSender":{"uid":10001,"nickname":"Alice","avatar":"a.png","value":500},
          "mvpReceiver":{"uid":10002,"nickname":"Bob","avatar":"b.png","value":300},
          "endedEarly":false,"cooldownLeftSec":60
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(PartyBattleSettlementResponse.self, from: json)
        XCTAssertEqual(r.pkId, "pk_1")
        XCTAssertEqual(r.durationSec, 300)
        XCTAssertEqual(r.winnerTeam, 1)
        XCTAssertEqual(r.redScore?.doubleValue, 1200)
        XCTAssertEqual(r.blueScore?.doubleValue, 800)
        XCTAssertEqual(r.mvpSender?.uid, 10001)
        XCTAssertEqual(r.mvpReceiver?.value?.doubleValue, 300)
        XCTAssertEqual(r.endedEarly, false)
    }

    func testSettlementResponseDecode_forceEndPayload() throws {
        // A6 待验证：forceEnd 场景 durationSec 可能缺失，endedEarly=true
        let json = "{\"pkId\":\"pk_1\",\"endedEarly\":true,\"cooldownLeftSec\":60}".data(using: .utf8)!
        let r = try JSONDecoder().decode(PartyBattleSettlementResponse.self, from: json)
        XCTAssertEqual(r.endedEarly, true)
        XCTAssertNil(r.durationSec)
    }

    func testApplicationsResponseDecode() throws {
        let json = """
        {
          "list":[
            {"applyId":42,"uid":10001,"nickname":"Alice","desiredTeam":1,"desiredMicId":5,"createdAt":1720000000000},
            {"applyId":43,"uid":"10002","nickname":"Bob"}
          ]
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(PartyBattleApplicationsResponse.self, from: json)
        XCTAssertEqual(r.list.count, 2)
        XCTAssertEqual(r.list[0].applyId, 42)
        XCTAssertEqual(r.list[0].uid, 10001)
        XCTAssertEqual(r.list[1].uid, 10002)  // String → Int64 兼容
        XCTAssertNil(r.list[1].desiredTeam)
    }

    func testApplicationsResponseDecode_h5CurrentSchema() throws {
        let json = """
        {
          "roomId": 123,
          "applications": [
            {"applyId":42,"uid":"10001","nickname":"Alice","desiredTeam":1,"createTimeMs":1720000000000}
          ]
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(PartyBattleApplicationsResponse.self, from: json)
        XCTAssertEqual(response.list.count, 1)
        XCTAssertEqual(response.list[0].uid, 10001)
        XCTAssertEqual(response.list[0].createdAt, 1_720_000_000_000)
    }
}
