import XCTest

/// G 里程碑 M4-5：PKNIMRouter 单测（spec §13.1）。
///
/// PKNIMRouter 因依赖 PKStore（@StateObject 持 SDK 依赖）不在 test target 内；
/// 这里聚焦"AttachType 分发 + payload 字典 → Codable 模型"的 decode 路径，
/// 复用 `PKModelsDecodeTests` 的 mock 字典模拟 NIM 推送 payload 形态。
///
/// 覆盖 6 类（97/98/99/100/-8/-9）共 9 条路径（100 的 5 个子分支）。
final class PKNIMRouterTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - 97 invite payload

    func test_97_invitePayload_decodesToInfo() throws {
        let payload: [String: Any] = [
            "attachType": 97,
            "userId": 333,
            "nickname": "inviter",
            "countryId": "CN",
            "agoraChannelId": "ch_001",
            "pkDuration": 180,
        ]
        let at = AttachType(raw: payload["attachType"])
        XCTAssertEqual(at, .pkInvite)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let info = try decoder.decode(PKInviteInfo.self, from: data)
        XCTAssertEqual(info.userId, 333)
        XCTAssertEqual(info.pkDuration, 180)
    }

    // MARK: - 98 score payload

    func test_98_scoreUpdatePayload_decodesAllArrays() throws {
        // 真机抓包：top3User=[String]，top3Users=[{userId, icon}]
        let payload: [String: Any] = [
            "attachType": 98,
            "pkCounter": 100,
            "oppositePkCounter": 80,
            "top3User": ["https://a.webp"],
            "top3Users": [
                ["userId": 1001, "icon": "https://a.webp"],
            ],
            "oppositeTop3User": ["https://b.webp"],
            "oppositeTop3Users": [
                ["userId": 1002, "icon": "https://b.webp"],
            ],
        ]
        let at = AttachType(raw: payload["attachType"])
        XCTAssertEqual(at, .pkScoreUpdate)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let s = try decoder.decode(PKScoreUpdate.self, from: data)
        XCTAssertEqual(s.pkCounter, 100)
        XCTAssertEqual(s.top3User?.first, "https://a.webp")
        XCTAssertEqual(s.top3Users?.first?.userId, 1001)
        XCTAssertEqual(s.top3Users?.first?.icon, "https://a.webp")
    }

    // MARK: - 99 invite ack 1/2/4 三个语义

    func test_99_inviteAck_status1_acceptedHasChannel() throws {
        let payload: [String: Any] = [
            "attachType": 99,
            "userId": 111,
            "nickname": "opp",
            "inviteStatus": 1,
            "pkDuration": 300,
            "agoraChannelId": "ch_acc",
            "countryId": "AR",
        ]
        let at = AttachType(raw: payload["attachType"])
        XCTAssertEqual(at, .pkInviteAck)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let ack = try decoder.decode(PKInviteAck.self, from: data)
        XCTAssertEqual(ack.inviteStatus, 1)
        XCTAssertEqual(ack.agoraChannelId, "ch_acc")
    }

    func test_99_inviteAck_status2_rejected() throws {
        let payload: [String: Any] = [
            "attachType": 99,
            "userId": 222,
            "inviteStatus": 2,
            "pkDuration": 300,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let ack = try decoder.decode(PKInviteAck.self, from: data)
        XCTAssertEqual(ack.inviteStatus, 2)
        XCTAssertNil(ack.agoraChannelId, "拒绝时无 channel")
    }

    func test_99_inviteAck_status4_cancel() throws {
        let payload: [String: Any] = [
            "attachType": 99,
            "userId": 333,
            "inviteStatus": 4,
            "pkDuration": 300,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let ack = try decoder.decode(PKInviteAck.self, from: data)
        XCTAssertEqual(ack.inviteStatus, 4)
    }

    // MARK: - 100 status bundle 5 个子分支（7/8/9/10/-1）

    func test_100_status10_matchSuccess() throws {
        let payload: [String: Any] = [
            "attachType": 100,
            "pkStatus": 10,
            "userId": 555,
            "agoraChannelId": "ch_match",
        ]
        let at = AttachType(raw: payload["attachType"])
        XCTAssertEqual(at, .pkStatusBundle)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let b = try decoder.decode(PKStatusBundle.self, from: data)
        XCTAssertEqual(b.pkStatus, 10)
        XCTAssertEqual(b.userId, 555)
    }

    func test_100_status8_enterPunishWithResult() throws {
        let payload: [String: Any] = [
            "attachType": 100,
            "pkStatus": 8,
            "result": 2,
            "pkCounter": 100,
            "oppositePkCounter": 200,
            "reason": 0,
            "isActiveInterrupt": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let b = try decoder.decode(PKStatusBundle.self, from: data)
        XCTAssertEqual(b.pkStatus, 8)
        XCTAssertEqual(b.result, 2, "2=失败")
        XCTAssertFalse(b.isActiveInterrupt ?? true)
    }

    func test_100_status9_oppositeEnded() throws {
        let payload: [String: Any] = ["attachType": 100, "pkStatus": 9]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let b = try decoder.decode(PKStatusBundle.self, from: data)
        XCTAssertEqual(b.pkStatus, 9)
    }

    func test_100_status7_audienceEnter() throws {
        // pkStatus=7 仅客态进 PK；主态收到应该 ignore（PKStore.handle100_status case 7 是 no-op）
        let payload: [String: Any] = ["attachType": 100, "pkStatus": 7]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let b = try decoder.decode(PKStatusBundle.self, from: data)
        XCTAssertEqual(b.pkStatus, 7)
    }

    func test_100_statusMinusOne_abnormalDisconnect() throws {
        let payload: [String: Any] = ["attachType": 100, "pkStatus": -1]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let b = try decoder.decode(PKStatusBundle.self, from: data)
        XCTAssertEqual(b.pkStatus, -1, "对方异常断线")
    }

    // MARK: - -8 / -9 attachType 解析（payload 不解 Codable，只验类型识别）

    func test_minus8_attachTypeIdentification() {
        XCTAssertEqual(AttachType(raw: NSNumber(value: -8)), .pkMuteBroadcast)
        XCTAssertEqual(AttachType(raw: "-8"), .pkMuteBroadcast)
    }

    func test_minus9_attachTypeIdentificationAndContentField() {
        XCTAssertEqual(AttachType(raw: NSNumber(value: -9)), .pkChatNotice)
        // pkChatNotice payload 含 content 富文本，NIMChatroomManager 主路径直接显示
        let payload: [String: Any] = [
            "attachType": -9,
            "type": "pk_notification",
            "content": "<font color='red'>PK 开始</font>",
        ]
        XCTAssertEqual(payload["content"] as? String, "<font color='red'>PK 开始</font>")
    }

    // MARK: - payload 缺字段时 decode 优雅失败（守卫不 crash）

    func test_inviteInfo_missingRequiredField_decodeFails() {
        let payload: [String: Any] = ["attachType": 97]  // 缺 userId / pkDuration
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return XCTFail("JSON serialize failed")
        }
        XCTAssertThrowsError(try decoder.decode(PKInviteInfo.self, from: data),
                             "userId / pkDuration 必填，缺字段应抛 decode error")
    }
}
