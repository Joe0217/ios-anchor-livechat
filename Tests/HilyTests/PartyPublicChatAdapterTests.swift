import XCTest

/// PartyPublicChatAdapter 单测（v3 通知基建 · 2026-07-15）。
///
/// 覆盖：
/// 1. 系统消息 4 类 kind（mode / application / authUpdate / videoSeatInvite）→ `.partyModeSwitch`
/// 2. announcement / gift / luckyGiftDerived / gameWinNotify / winnerBroadcast payload 派生
/// 3. medalList 兼容三态（Array / JSON string / nil）
/// 4. sender 富字段派生（userId 兼容 String/Int / medals / role / isVip / isPlatformAdmin）
///
/// **不覆盖** `adaptText(nim:)` —— 依赖 NIMMessage，属 +NIM.swift 层，走真机集成测试。
final class PartyPublicChatAdapterTests: XCTestCase {

    // MARK: - 系统消息 4 类 kind

    func test_systemMode_producesPartyModeSwitchVariant() {
        let msg = PartyPublicChatAdapter.systemMode(text: "Room mode changed")
        XCTAssertNil(msg.sender)
        guard case .partyModeSwitch(let text, let kind) = msg.variant else {
            XCTFail("expected .partyModeSwitch"); return
        }
        XCTAssertEqual(text, "Room mode changed")
        XCTAssertEqual(kind, .mode)
    }

    func test_systemApplication_kindIsApplication() {
        let msg = PartyPublicChatAdapter.systemApplication(text: "Mic app on")
        guard case .partyModeSwitch(_, let kind) = msg.variant else {
            XCTFail("expected .partyModeSwitch"); return
        }
        XCTAssertEqual(kind, .application)
    }

    func test_systemAuthUpdate_kindIsAuthUpdate() {
        let msg = PartyPublicChatAdapter.systemAuthUpdate(text: "You are admin now")
        guard case .partyModeSwitch(_, let kind) = msg.variant else {
            XCTFail("expected .partyModeSwitch"); return
        }
        XCTAssertEqual(kind, .authUpdate)
    }

    func test_systemVideoSeatInvite_kindIsVideoSeatInvite() {
        let msg = PartyPublicChatAdapter.systemVideoSeatInvite(text: "Alice joined")
        guard case .partyModeSwitch(_, let kind) = msg.variant else {
            XCTFail("expected .partyModeSwitch"); return
        }
        XCTAssertEqual(kind, .videoSeatInvite)
    }

    // MARK: - Announcement

    func test_announcement_kindIsPartyRoom() {
        let msg = PartyPublicChatAdapter.announcement(text: "Room policy")
        guard case .announcement(let text, let kind) = msg.variant else {
            XCTFail("expected .announcement"); return
        }
        XCTAssertEqual(text, "Room policy")
        XCTAssertEqual(kind, .partyRoom)
    }

    // MARK: - Gift + LuckyGift 派生

    func test_gift_carriesEventFields() {
        let event = PartyGiftEvent(
            giftId: 100, giftName: "Rose", num: 5,
            senderUserId: "u1", senderNickname: "Alice",
            receiverUserIds: ["u2"], timestamp: 1_000
        )
        let msg = PartyPublicChatAdapter.gift(event: event, iconURL: "https://cdn/gift.png")
        XCTAssertEqual(msg.sender?.userId, "u1")
        XCTAssertEqual(msg.sender?.nickname, "Alice")
        guard case .gift(let icon, let name, let count) = msg.variant else {
            XCTFail("expected .gift"); return
        }
        XCTAssertEqual(icon, "https://cdn/gift.png")
        XCTAssertEqual(name, "Rose")
        XCTAssertEqual(count, 5)
    }

    func test_luckyGiftDerived_carriesTotalReward() {
        let event = PartyGiftEvent(
            giftId: 200, giftName: "LuckyBox", num: 3,
            senderUserId: "u3", senderNickname: "Bob",
            receiverUserIds: [], timestamp: 2_000
        )
        let msg = PartyPublicChatAdapter.luckyGiftDerived(
            event: event, iconURL: "https://cdn/lucky.png", totalReward: 8888
        )
        guard case .luckyGift(let icon, let count, let total) = msg.variant else {
            XCTFail("expected .luckyGift"); return
        }
        XCTAssertEqual(icon, "https://cdn/lucky.png")
        XCTAssertEqual(count, 3)
        XCTAssertEqual(total, 8888)
    }

    // MARK: - gameWinNotify

    func test_gameWinNotify_decodesFullPayload() {
        let payload: [String: Any] = [
            "avatar": "https://cdn/av.png",
            "nickname": "Alice",
            "winAmount": "1000",
            "gameName": "Dice",
            "gameIcon": "https://cdn/dice.png",
        ]
        guard let msg = PartyPublicChatAdapter.gameWinNotify(payload: payload) else {
            XCTFail("expected non-nil"); return
        }
        guard case .gameWinNotify(let gp) = msg.variant else {
            XCTFail("expected .gameWinNotify"); return
        }
        XCTAssertEqual(gp.nickname, "Alice")
        XCTAssertEqual(gp.winAmount, "1000")
        XCTAssertEqual(gp.gameName, "Dice")
    }

    func test_gameWinNotify_winAmountAsNumber_convertedToString() {
        let payload: [String: Any] = [
            "nickname": "Carol",
            "winAmount": 500,   // 后端可能是 Number
            "gameName": "Slots",
        ]
        guard let msg = PartyPublicChatAdapter.gameWinNotify(payload: payload),
              case .gameWinNotify(let gp) = msg.variant else {
            XCTFail("expected gameWinNotify"); return
        }
        XCTAssertEqual(gp.winAmount, "500")
    }

    func test_gameWinNotify_dropWhenNicknameAndGameNameEmpty() {
        let payload: [String: Any] = ["winAmount": "100"]
        XCTAssertNil(PartyPublicChatAdapter.gameWinNotify(payload: payload))
    }

    // MARK: - winnerBroadcast

    func test_winnerBroadcast_decodesFullPayload() {
        let payload: [String: Any] = [
            "activityName": "World Cup",
            "quantity": 999,
            "imageURL": "https://cdn/wc.png",
            "joinCTA": "https://cdn/join.png",
            "avatar": "https://cdn/av.png",
        ]
        guard let msg = PartyPublicChatAdapter.winnerBroadcast(payload: payload),
              case .winnerBroadcast(let name, let qty, let img, let cta, let av) = msg.variant else {
            XCTFail("expected winnerBroadcast"); return
        }
        XCTAssertEqual(name, "World Cup")
        XCTAssertEqual(qty, 999)
        XCTAssertEqual(img, "https://cdn/wc.png")
        XCTAssertEqual(cta, "https://cdn/join.png")
        XCTAssertEqual(av, "https://cdn/av.png")
    }

    func test_winnerBroadcast_fallbackFieldNames() {
        // H5 用 messageImage / messageJoin，兼容 imageURL / joinCTA 优先
        let payload: [String: Any] = [
            "activityName": "Xmas",
            "messageImage": "https://cdn/xmas.png",
            "messageJoin": "https://cdn/xjoin.png",
        ]
        guard let msg = PartyPublicChatAdapter.winnerBroadcast(payload: payload),
              case .winnerBroadcast(_, _, let img, let cta, _) = msg.variant else {
            XCTFail("expected winnerBroadcast"); return
        }
        XCTAssertEqual(img, "https://cdn/xmas.png")
        XCTAssertEqual(cta, "https://cdn/xjoin.png")
    }

    func test_winnerBroadcast_dropWhenActivityNameEmpty() {
        XCTAssertNil(PartyPublicChatAdapter.winnerBroadcast(payload: [:]))
    }

    // MARK: - medalList 三态兼容

    func test_parseMedals_arrayOfStrings() {
        let medals = PartyPublicChatAdapter.parseMedals(["url1", "url2"])
        XCTAssertEqual(medals, ["url1", "url2"])
    }

    func test_parseMedals_jsonStringOfArray() {
        let json = #"["a","b","c"]"#
        let medals = PartyPublicChatAdapter.parseMedals(json)
        XCTAssertEqual(medals, ["a", "b", "c"])
    }

    func test_parseMedals_nilYieldsEmpty() {
        XCTAssertEqual(PartyPublicChatAdapter.parseMedals(nil), [])
    }

    func test_parseMedals_invalidStringYieldsEmpty() {
        XCTAssertEqual(PartyPublicChatAdapter.parseMedals("not-json"), [])
    }

    // MARK: - makeSender 富字段派生

    func test_makeSender_ownerRoleAndPlatformAdmin() {
        let ext: [String: Any] = [
            "userId": "1000",
            "nickname": "Host",
            "userAvatar": "https://cdn/host.png",
            "userLevel": 30,
            "isVip": true,
            "role": 1,   // owner
            "isPlatformAdmin": 1,
            "chatBubble": "https://cdn/bubble.png",
        ]
        let sender = PartyPublicChatAdapter.makeSender(from: ext, fallbackNickname: nil, isSelf: false)
        XCTAssertEqual(sender.userId, "1000")
        XCTAssertEqual(sender.nickname, "Host")
        XCTAssertEqual(sender.avatarURL, "https://cdn/host.png")
        XCTAssertEqual(sender.userLevel, 30)
        XCTAssertTrue(sender.isVip)
        XCTAssertTrue(sender.isHost)
        XCTAssertEqual(sender.role, .owner)
        XCTAssertTrue(sender.isPlatformAdmin)
        XCTAssertEqual(sender.chatBubble, "https://cdn/bubble.png")
    }

    func test_makeSender_userIdAsIntCompat() {
        // 对齐 ios-decode-userid-compat：String/Int 双兼容
        let ext: [String: Any] = ["userId": 12345, "nickname": "N"]
        let sender = PartyPublicChatAdapter.makeSender(from: ext, fallbackNickname: nil, isSelf: false)
        XCTAssertEqual(sender.userId, "12345")
    }

    func test_makeSender_fallbackNicknameWhenMissing() {
        let ext: [String: Any] = ["userId": "1"]
        let sender = PartyPublicChatAdapter.makeSender(from: ext, fallbackNickname: "SDKName", isSelf: true)
        XCTAssertEqual(sender.nickname, "SDKName")
        XCTAssertTrue(sender.isSelf)
    }
}
