import XCTest

/// G 里程碑 M1 PKModels Codable decode 单测（spec §13.1）。
///
/// PKService 内部用 `APIClient.shared`（生产 singleton 难注入 mock），所以测 PKService HTTP 链路
/// 价值低；这里聚焦"接口响应字段映射到 PKModels"的 decode 路径——后端字段变更或拼写错时单测立刻挂。
///
/// 覆盖 3 个关键接口：joinPk / getPkTop3RankList / getPkStatus + 6 类 NIM payload（PKStatusBundle 等）。
final class PKModelsDecodeTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - joinPk 响应（R3 endTime 单位：Unix 毫秒戳预设；M1 联调若实际为秒在 PKCountdownController 单点改算）

    func test_joinPk_fullPayload_decodesAllFields() throws {
        // 后端 joinPk 响应示例（spec §A.3）：pkId / nickname / yxAccId / countryId / endTime / pkDuration
        let json = """
        {
            "pkId": "pk_abc_123",
            "nickname": "opponent_xxx",
            "avatar": "https://cdn.test/avatar.jpg",
            "yxAccId": "yx_999",
            "countryId": "CN",
            "endTime": 1750000000000,
            "pkDuration": 300
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(PKJoinResponse.self, from: json)
        XCTAssertEqual(resp.pkId, "pk_abc_123")
        XCTAssertEqual(resp.nickname, "opponent_xxx")
        XCTAssertEqual(resp.yxAccId, "yx_999")
        XCTAssertEqual(resp.countryId, "CN")
        XCTAssertEqual(resp.endTime, 1_750_000_000_000, "endTime 假设 Unix 毫秒；若后端实际为秒（如 1750000000）M3 联调时单点改算")
        XCTAssertEqual(resp.pkDuration, 300)
    }

    func test_joinPk_missingOptionalFields_decodesWithNil() throws {
        // 部分字段缺失：endTime / avatar 可能 nil（兜底字段缺时 PKStore 用 pkDuration 自算）
        let json = """
        {
            "pkId": "pk_only",
            "nickname": null,
            "avatar": null,
            "yxAccId": null,
            "countryId": null,
            "endTime": null,
            "pkDuration": null
        }
        """.data(using: .utf8)!
        let resp = try decoder.decode(PKJoinResponse.self, from: json)
        XCTAssertEqual(resp.pkId, "pk_only")
        XCTAssertNil(resp.endTime)
        XCTAssertNil(resp.pkDuration)
    }

    // MARK: - getPkTop3RankList 响应（spec §A.8：数组 + nickName 驼峰非对称）

    func test_getPkTop3RankList_arrayDecodesNickNameField() throws {
        // REST 接口格式（getPkTop3RankList）：userId Int + nickName + avatar + value
        let json = """
        [
            {"userId": 1001, "nickName": "fanA", "avatar": "https://a.png", "value": 10000},
            {"userId": 1002, "nickName": "fanB", "avatar": "https://b.png", "value": 5000},
            {"userId": 1003, "nickName": "fanC", "avatar": "https://c.png", "value": 2000}
        ]
        """.data(using: .utf8)!

        let list = try decoder.decode([PKTopUser].self, from: json)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].nickName, "fanA")
        XCTAssertEqual(list[0].value, 10000)
        XCTAssertEqual(list[2].userId, 1003)
        XCTAssertEqual(list[0].displayAvatar, "https://a.png", "displayAvatar 优先 icon fallback avatar")
    }

    func test_pkTopUser_98PushFormat_userIdIntPlusIcon() throws {
        // attachType=98 实时 push 格式：userId Int + icon（无 nickName/value）
        let json = """
        {"userId": 1000001861, "icon": "https://cdn.test/a.webp"}
        """.data(using: .utf8)!
        let u = try decoder.decode(PKTopUser.self, from: json)
        XCTAssertEqual(u.userId, 1000001861)
        XCTAssertEqual(u.icon, "https://cdn.test/a.webp")
        XCTAssertNil(u.nickName)
        XCTAssertNil(u.value)
        XCTAssertEqual(u.displayAvatar, "https://cdn.test/a.webp", "icon 字段填充 displayAvatar")
    }

    func test_getPkTop3RankList_emptyArrayDecodes() throws {
        let json = "[]".data(using: .utf8)!
        let list = try decoder.decode([PKTopUser].self, from: json)
        XCTAssertEqual(list.count, 0)
    }

    // MARK: - getPkStatus 响应（'INPK' / 'PUNISHING' / null 字符串）

    func test_pkRemoteStatus_rawValueMapping() {
        XCTAssertEqual(PKRemoteStatus(rawValue: "INPK"), .inPK)
        XCTAssertEqual(PKRemoteStatus(rawValue: "PUNISHING"), .punishing)
        XCTAssertNil(PKRemoteStatus(rawValue: "OTHER"))
        XCTAssertNil(PKRemoteStatus(rawValue: ""))
    }

    // MARK: - PKStatusBundle（attachType=100 子分发）

    func test_pkStatusBundle_status10_matchSuccess() throws {
        // pkStatus=10 匹配成功，主态拿到对手信息
        let json = """
        {
            "pkStatus": 10,
            "userId": 555,
            "nickname": "opp",
            "avatar": "https://a.png",
            "countryId": "TR",
            "agoraChannelId": "channel_xyz"
        }
        """.data(using: .utf8)!
        let b = try decoder.decode(PKStatusBundle.self, from: json)
        XCTAssertEqual(b.pkStatus, 10)
        XCTAssertEqual(b.userId, 555)
        XCTAssertEqual(b.agoraChannelId, "channel_xyz")
        XCTAssertNil(b.result, "result 仅 pkStatus=8 时才下发")
    }

    func test_pkStatusBundle_status8_enterPunish() throws {
        // pkStatus=8 进惩罚 + 输赢
        let json = """
        {
            "pkStatus": 8,
            "result": 1,
            "pkCounter": 1234,
            "oppositePkCounter": 999,
            "reason": 0,
            "isActiveInterrupt": false
        }
        """.data(using: .utf8)!
        let b = try decoder.decode(PKStatusBundle.self, from: json)
        XCTAssertEqual(b.pkStatus, 8)
        XCTAssertEqual(b.result, 1, "1=胜 / 2=负 / 3=平")
        XCTAssertEqual(b.pkCounter, 1234)
        XCTAssertEqual(b.isActiveInterrupt, false)
    }

    func test_pkStatusBundle_statusMinusOne_oppositeAbnormalDisconnect() throws {
        let json = """
        {"pkStatus": -1}
        """.data(using: .utf8)!
        let b = try decoder.decode(PKStatusBundle.self, from: json)
        XCTAssertEqual(b.pkStatus, -1, "pkStatus=-1 对方异常断线")
    }

    // MARK: - PKInviteAck（attachType=99）

    func test_pkInviteAck_status1_accept() throws {
        let json = """
        {
            "userId": 100,
            "nickname": "opp",
            "inviteStatus": 1,
            "pkDuration": 300,
            "agoraChannelId": "ch_999",
            "countryId": "AR"
        }
        """.data(using: .utf8)!
        let a = try decoder.decode(PKInviteAck.self, from: json)
        XCTAssertEqual(a.inviteStatus, 1, "1=接受")
        XCTAssertEqual(a.agoraChannelId, "ch_999", "inviteStatus=1 时下发 agoraChannelId")
    }

    func test_pkInviteAck_status2_reject_noChannel() throws {
        let json = """
        {"userId": 200, "nickname": "opp", "inviteStatus": 2, "pkDuration": 300}
        """.data(using: .utf8)!
        let a = try decoder.decode(PKInviteAck.self, from: json)
        XCTAssertEqual(a.inviteStatus, 2)
        XCTAssertNil(a.agoraChannelId, "inviteStatus≠1 时 agoraChannelId 缺")
    }

    // MARK: - PKScoreUpdate（attachType=98）

    func test_pkScoreUpdate_decodesRealBackendPayload() throws {
        // 2026-06-24 真机抓包格式：top3User/oppositeTop3User 是 [String] 头像 URL 数组（旧字段），
        // top3Users/oppositeTop3Users 才是 [{userId, icon}] 对象数组（新字段）
        let json = """
        {
            "pkCounter": 0,
            "oppositePkCounter": 1000,
            "top3User": [],
            "top3Users": [],
            "oppositeTop3User": ["https://cdn.test/a.webp"],
            "oppositeTop3Users": [
                {"userId": 1000001861, "icon": "https://cdn.test/a.webp"}
            ]
        }
        """.data(using: .utf8)!
        let s = try decoder.decode(PKScoreUpdate.self, from: json)
        XCTAssertEqual(s.pkCounter, 0)
        XCTAssertEqual(s.oppositePkCounter, 1000)
        XCTAssertEqual(s.oppositeTop3User?.count, 1, "头像 URL [String] 数组")
        XCTAssertEqual(s.oppositeTop3User?.first, "https://cdn.test/a.webp")
        XCTAssertEqual(s.oppositeTop3Users?.count, 1, "用户对象 [PKTopUser] 数组")
        XCTAssertEqual(s.oppositeTop3Users?.first?.userId, 1000001861)
        XCTAssertEqual(s.oppositeTop3Users?.first?.icon, "https://cdn.test/a.webp")
    }

    // MARK: - PKInviteInfo（attachType=97）

    func test_pkInviteInfo_basic() throws {
        let json = """
        {
            "userId": 777,
            "nickname": "inviter",
            "countryId": "CN",
            "agoraChannelId": "ch_001",
            "pkDuration": 600
        }
        """.data(using: .utf8)!
        let i = try decoder.decode(PKInviteInfo.self, from: json)
        XCTAssertEqual(i.userId, 777)
        XCTAssertEqual(i.pkDuration, 600, "10 分钟 PK = 600 秒")
    }

    // MARK: - PKMatchResult（startPkMatch）

    func test_pkMatchResult_minimalFields() throws {
        let json = """
        {"userId": 999, "nickname": "matched"}
        """.data(using: .utf8)!
        let m = try decoder.decode(PKMatchResult.self, from: json)
        XCTAssertEqual(m.userId, 999)
        XCTAssertEqual(m.nickname, "matched")
        XCTAssertNil(m.agoraChannelId)
    }

    // MARK: - PKServiceError 行为

    func test_pkServiceError_business_preservesCodeAndMessage() {
        let err = PKServiceError.business(code: "1080", message: "余额不足")
        XCTAssertEqual(err.errorDescription, "余额不足")
    }

    func test_pkServiceError_notImplemented_hasDescription() {
        let err = PKServiceError.notImplemented
        XCTAssertNotNil(err.errorDescription)
    }
}
