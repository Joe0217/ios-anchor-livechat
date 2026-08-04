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
        guard case .gift(let icon, let name, let count, let recipients) = msg.variant else {
            XCTFail("expected .gift"); return
        }
        XCTAssertEqual(icon, "https://cdn/gift.png")
        XCTAssertEqual(name, "Rose")
        XCTAssertEqual(count, 5)
        XCTAssertEqual(recipients, [])
    }

    func test_gift_carriesRecipientsForPartyPublicChat() {
        let event = PartyGiftEvent(
            giftId: 100, giftName: "Rose", num: 5,
            senderUserId: "u1", senderNickname: "Alice",
            receiverUserIds: ["u2", "u3"],
            recipients: [
                PartyGiftRecipient(userId: "u2", nickname: "Bella", avatarURL: "https://cdn/bella.png"),
                PartyGiftRecipient(userId: "u3", nickname: "Cara", avatarURL: "https://cdn/cara.png")
            ],
            timestamp: 1_000
        )
        let msg = PartyPublicChatAdapter.gift(event: event, iconURL: nil)
        guard case .gift(_, _, let count, let recipients) = msg.variant else {
            XCTFail("expected .gift"); return
        }
        XCTAssertEqual(count * recipients.count, 10)
        XCTAssertEqual(recipients, [
            PublicChatGiftRecipient(userId: "u2", nickname: "Bella", avatarURL: "https://cdn/bella.png"),
            PublicChatGiftRecipient(userId: "u3", nickname: "Cara", avatarURL: "https://cdn/cara.png")
        ])
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

    /// v3+ (2026-07-16)：event.senderAvatar 应透传到 sender.avatarURL
    func test_gift_senderAvatar_flowsToSenderProfile() {
        let event = PartyGiftEvent(
            giftId: 100, giftName: "Rose", num: 1,
            senderUserId: "u1", senderNickname: "Alice",
            senderAvatar: "https://cdn/alice.png",
            receiverUserIds: [], timestamp: 1_000
        )
        let msg = PartyPublicChatAdapter.gift(event: event, iconURL: nil)
        XCTAssertEqual(msg.sender?.avatarURL, "https://cdn/alice.png")
    }

    /// v3+ (2026-07-16)：event.senderUserId == myUserId 时 sender.isSelf = true
    func test_gift_isSelf_whenSenderUserIdMatchesMine() {
        let event = PartyGiftEvent(
            giftId: 100, giftName: nil, num: 1,
            senderUserId: "1000", senderNickname: "Me",
            senderAvatar: "https://cdn/me.png",
            receiverUserIds: [], timestamp: 1_000
        )
        let msg = PartyPublicChatAdapter.gift(event: event, iconURL: nil, myUserId: "1000")
        XCTAssertTrue(msg.sender?.isSelf ?? false)
    }

    /// v3+ (2026-07-16)：senderUserId != myUserId 时 isSelf = false
    func test_gift_isSelf_falseWhenSenderMismatchesMine() {
        let event = PartyGiftEvent(
            giftId: 100, giftName: nil, num: 1,
            senderUserId: "1000", senderNickname: "Other",
            senderAvatar: nil,
            receiverUserIds: [], timestamp: 1_000
        )
        let msg = PartyPublicChatAdapter.gift(event: event, iconURL: nil, myUserId: "2000")
        XCTAssertFalse(msg.sender?.isSelf ?? true)
    }

    /// v3+ (2026-07-16)：主播本人送礼 payload 缺 sendUser.avatar 时走 myAvatarFallback
    func test_gift_selfFallbackAvatar_whenPayloadMissingAndIsSelf() {
        let event = PartyGiftEvent(
            giftId: 100, giftName: nil, num: 1,
            senderUserId: "1000", senderNickname: "Me",
            senderAvatar: nil,        // payload 未带
            receiverUserIds: [], timestamp: 1_000
        )
        let msg = PartyPublicChatAdapter.gift(
            event: event, iconURL: nil,
            myUserId: "1000", myAvatarFallback: "https://cdn/local-mine.png"
        )
        XCTAssertEqual(msg.sender?.avatarURL, "https://cdn/local-mine.png")
        XCTAssertTrue(msg.sender?.isSelf ?? false)
    }

    /// v3+ (2026-07-16)：非 self + payload 缺 avatar → 不走 fallback（fallback 仅 self 生效）
    func test_gift_fallback_notAppliedWhenNotSelf() {
        let event = PartyGiftEvent(
            giftId: 100, giftName: nil, num: 1,
            senderUserId: "2000", senderNickname: "Other",
            senderAvatar: nil,
            receiverUserIds: [], timestamp: 1_000
        )
        let msg = PartyPublicChatAdapter.gift(
            event: event, iconURL: nil,
            myUserId: "1000", myAvatarFallback: "https://cdn/local-mine.png"
        )
        XCTAssertNil(msg.sender?.avatarURL)   // 别人送礼 payload 缺 avatar → 显示默认头像，不错拿 self fallback
    }

    /// v3+ (2026-07-16)：PartyGiftEvent.from 解析 `sendUser.avatar` 字段
    func test_partyGiftEvent_from_extractsAvatarFromPayload() {
        let payload: [String: Any] = [
            "giftId": 42, "giftNum": 3,
            "sendUser": [
                "userId": "1234",
                "nickname": "Anchor",
                "avatar": "https://cdn/anchor.png"
            ]
        ]
        let event = PartyGiftEvent.from(payload: payload, timestampMs: 999)
        XCTAssertEqual(event.senderUserId, "1234")
        XCTAssertEqual(event.senderNickname, "Anchor")
        XCTAssertEqual(event.senderAvatar, "https://cdn/anchor.png")
    }

    /// v3+ (2026-07-16)：sendUser 缺 avatar 字段时用 icon / userAvatar fallback
    func test_partyGiftEvent_from_avatarFallbackFieldNames() {
        // 缺 avatar，走 icon
        let payload1: [String: Any] = [
            "giftId": 42, "giftNum": 1,
            "sendUser": ["userId": "1", "icon": "https://cdn/via-icon.png"]
        ]
        let e1 = PartyGiftEvent.from(payload: payload1, timestampMs: 1)
        XCTAssertEqual(e1.senderAvatar, "https://cdn/via-icon.png")

        // 缺 avatar/icon，走 userAvatar
        let payload2: [String: Any] = [
            "giftId": 42, "giftNum": 1,
            "sendUser": ["userId": "1", "userAvatar": "https://cdn/via-userAvatar.png"]
        ]
        let e2 = PartyGiftEvent.from(payload: payload2, timestampMs: 1)
        XCTAssertEqual(e2.senderAvatar, "https://cdn/via-userAvatar.png")

        // 三个都缺 → nil
        let payload3: [String: Any] = [
            "giftId": 42, "giftNum": 1,
            "sendUser": ["userId": "1", "nickname": "X"]
        ]
        let e3 = PartyGiftEvent.from(payload: payload3, timestampMs: 1)
        XCTAssertNil(e3.senderAvatar)
    }

    // MARK: - gameWinNotify

    func test_gameWinNotify_decodesFullPayload() {
        let payload: [String: Any] = [
            "avatar": "https://cdn/av.png",
            "nickname": "Alice",
            "winAmount": "1000",
            "gameId": "dice",
            "gameName": "Dice",
            "gameType": "dice",
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
        XCTAssertEqual(gp.gameId, "dice")
        XCTAssertEqual(gp.gameName, "Dice")
        XCTAssertEqual(gp.gameType, "dice")
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

    // MARK: - Lucky Number (1050 / 1051 / 1052)

    func test_luckyNumberPublic_usesDataWrapperAndPreservesUserHeader() {
        let payload: [String: Any] = [
            "attachType": 1050,
            "data": [
                "userId": 1001,
                "nickname": "Lucky Alice",
                "avatar": "https://cdn/alice.png",
                "userLevel": 30,
                "isVip": 1,
                "medalList": #"["https://cdn/medal.png"]"#,
                "role": 2,
                "isPlatformAdmin": 1,
                "headFrame": "https://cdn/frame.png",
                "luckyNumber": "88",
            ],
        ]

        guard let message = PartyPublicChatAdapter.luckyNumberPublic(payload: payload, didWin: false),
              case .partyLuckyNumber(let number, let didWin) = message.variant else {
            XCTFail("expected .partyLuckyNumber"); return
        }
        XCTAssertEqual(number, 88)
        XCTAssertFalse(didWin)
        XCTAssertEqual(message.sender?.userId, "1001")
        XCTAssertEqual(message.sender?.nickname, "Lucky Alice")
        XCTAssertEqual(message.sender?.avatarURL, "https://cdn/alice.png")
        XCTAssertEqual(message.sender?.userLevel, 30)
        XCTAssertTrue(message.sender?.isVip ?? false)
        XCTAssertEqual(message.sender?.medals, ["https://cdn/medal.png"])
        XCTAssertEqual(message.sender?.role, .manager)
        XCTAssertTrue(message.sender?.isPlatformAdmin ?? false)
        XCTAssertEqual(message.sender?.headFrame, "https://cdn/frame.png")
    }

    func test_luckyNumberPublic_acceptsH5TopLevelFallbackAndAliases() {
        let payload: [String: Any] = [
            "userId": "1002",
            "fromNick": "Bob",
            "userAvatar": "https://cdn/bob.png",
            "luckyNumber": 9,
        ]
        guard let message = PartyPublicChatAdapter.luckyNumberPublic(payload: payload, didWin: true),
              case .partyLuckyNumber(let number, let didWin) = message.variant else {
            XCTFail("expected .partyLuckyNumber"); return
        }
        XCTAssertEqual(number, 9)
        XCTAssertTrue(didWin)
        XCTAssertEqual(message.sender?.nickname, "Bob")
        XCTAssertEqual(message.sender?.avatarURL, "https://cdn/bob.png")
    }

    func test_luckyNumberPublic_rejectsOutOfRangeNumber() {
        XCTAssertNil(PartyPublicChatAdapter.luckyNumberPublic(payload: ["luckyNumber": 1000], didWin: false))
        XCTAssertNil(PartyPublicChatAdapter.luckyNumberPublic(payload: ["luckyNumber": -1], didWin: true))
    }

    func test_luckyNumberPersonalWin_parsesJSONStringDataAndStableNotificationId() {
        let payload: [String: Any] = [
            "_nimCustomNotificationId": "notification-1",
            "data": #"{"roomId":"room-1","nickname":"Winner","avatar":"https://cdn/winner.png","luckyNumber":"99","text":"You won"}"#,
        ]
        let win = PartyLuckyNumberWinPayload.from(payload: payload)
        XCTAssertEqual(win?.id, "notification-1")
        XCTAssertEqual(win?.roomId, "room-1")
        XCTAssertEqual(win?.nickname, "Winner")
        XCTAssertEqual(win?.avatar, "https://cdn/winner.png")
        XCTAssertEqual(win?.luckyNumber, 99)
        XCTAssertEqual(win?.text, "You won")
    }

    func test_luckyNumberPersonalWin_rejectsMissingOrInvalidNumber() {
        XCTAssertNil(PartyLuckyNumberWinPayload.from(payload: ["luckyNumber": -1]))
        XCTAssertNil(PartyLuckyNumberWinPayload.from(payload: ["luckyNumber": 1000]))
        XCTAssertNil(PartyLuckyNumberWinPayload.from(payload: [:]))
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
