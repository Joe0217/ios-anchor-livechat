import Foundation

/// Party 派对房公屏消息适配器（v3 通知基建 · 2026-07-15 · pure 层无 NIMSDK 依赖）。
///
/// 将 attachType payload / PartyGiftEvent 转换为跨场景统一的
/// [`UnifiedPublicChatMessage`](../../PublicChat/Model/UnifiedPublicChatMessage.swift)。
///
/// 参照 [`LivePublicChatAdapter`](../../PublicChat/Adapters/LivePublicChatAdapter.swift) 结构。
///
/// **纯静态方法 + 无副作用**：单元测试直接注入 payload dict，不依赖 NIMSDK 实例。
/// **NIM 相关 API**（`adaptText(nim:)` 从 NIMMessage 构造）拆到 [`PartyPublicChatAdapter+NIM.swift`](PartyPublicChatAdapter+NIM.swift)
/// 避免 test target 拉入 NIMSDK 依赖（对齐 [hily-tests-target-whitelist-convention]）。
enum PartyPublicChatAdapter {

    // MARK: - 文本消息（本地回显）

    /// 本地回显（sendText 发出时立即插入）。字段从 SessionStore / AnchorInfoStore 拉。
    static func selfEchoText(
        text: String,
        myUserId: String?,
        myNickname: String,
        myAvatar: String?,
        myLevel: Int?,
        myIsVip: Bool,
        myChatBubble: String?,
        myRoleRaw: Int?,
        myHeadFrame: String? = nil
    ) -> UnifiedPublicChatMessage {
        let role = myRoleRaw.flatMap(PartyRole.init(rawValue:))
        let sender = SenderProfile(
            userId: myUserId,
            nickname: myNickname,
            avatarURL: myAvatar,
            userLevel: myLevel,
            isVip: myIsVip,
            isHost: role == .owner,
            role: role,
            medals: [],
            chatBubble: myChatBubble,
            isPlatformAdmin: false,
            isSelf: true,
            isNewUser: false,
            nicknameColor: .default,
            headFrame: myHeadFrame
        )
        return UnifiedPublicChatMessage(sender: sender, variant: .text(content: text))
    }

    // MARK: - 系统消息（4 类，对齐 H5 chat-list.vue msgType 分支）

    /// 1017 切换房间模板系统消息。text 由 caller 提供（L10n.Party.roomModeSystemMsg）。
    static func systemMode(text: String) -> UnifiedPublicChatMessage {
        UnifiedPublicChatMessage(
            sender: nil,
            variant: .partyModeSwitch(text: text, kind: .mode)
        )
    }

    /// 1021 排麦开关变更系统消息。
    static func systemApplication(text: String) -> UnifiedPublicChatMessage {
        UnifiedPublicChatMessage(
            sender: nil,
            variant: .partyModeSwitch(text: text, kind: .application)
        )
    }

    /// 1019 房管变更系统消息（仅本人被设/取消）。
    static func systemAuthUpdate(text: String) -> UnifiedPublicChatMessage {
        UnifiedPublicChatMessage(
            sender: nil,
            variant: .partyModeSwitch(text: text, kind: .authUpdate)
        )
    }

    /// 1047 视频位邀请接受公屏广播。
    static func systemVideoSeatInvite(text: String) -> UnifiedPublicChatMessage {
        UnifiedPublicChatMessage(
            sender: nil,
            variant: .partyModeSwitch(text: text, kind: .videoSeatInvite)
        )
    }

    // MARK: - 房间通告 / LuckyNumber（1049 / 1050 / 1051）

    /// 1049 房间通告公屏广播（也用于进房首次本地插入）。
    static func announcement(text: String) -> UnifiedPublicChatMessage {
        UnifiedPublicChatMessage(
            sender: nil,
            variant: .announcement(text: text, kind: .partyRoom)
        )
    }

    /// 1050 / 1051 幸运数字公屏：对齐 H5 `chat-list.vue`，使用普通 Party 用户头部而不是房间公告。
    /// payload 已在 `PartyLuckyNumberPayload` 中处理 `data` 包裹与别名字段。
    static func luckyNumberPublic(payload: [String: Any], didWin: Bool) -> UnifiedPublicChatMessage? {
        let data = PartyLuckyNumberPayload.publicMessagePayload(from: payload)
        guard let number = PartyValueNormalizer.intify(data["luckyNumber"]),
              (0...999).contains(number) else {
            return nil
        }
        return UnifiedPublicChatMessage(
            sender: makeSender(from: data, fallbackNickname: nil, isSelf: false),
            variant: .partyLuckyNumber(number: number, didWin: didWin)
        )
    }

    /// Party 房 Battle Team PK 系统消息（对齐 H5 chat-list.vue :333-392 · 4 kind 独立视觉）
    ///
    /// - parameter kind: PartyBattleSystemKind 4 kind
    /// - parameter text: 主文案（含 `{h}` 占位符时会用 highlight 替换）
    /// - parameter highlight: 黄色高亮片段（如分数/秒数/MVP 姓名）；nil 表示无高亮（forceEnd 场景）
    static func battleSystem(
        kind: PartyBattleSystemKind,
        text: String,
        highlight: String? = nil
    ) -> UnifiedPublicChatMessage {
        UnifiedPublicChatMessage(
            sender: nil,
            variant: .partyBattle(kind: kind, text: text, highlight: highlight)
        )
    }

    // MARK: - 送礼消息（2049）

    /// 2049 送礼 → `.gift` variant。iconURL/name 由 caller 从后端字段派生（`giftSmallImg / giftName`）。
    /// v3+（2026-07-16）:senderAvatar 透传到 SenderProfile.avatarURL；主播本人送礼时 payload 缺 avatar
    /// 可通过 `myAvatarFallback` 兜底（Store 层从 AnchorInfoStore/SessionStore 传入）
    static func gift(
        event: PartyGiftEvent,
        iconURL: String?,
        myUserId: String? = nil,
        myAvatarFallback: String? = nil
    ) -> UnifiedPublicChatMessage {
        return UnifiedPublicChatMessage(
            sender: makeGiftSender(event: event, myUserId: myUserId, myAvatarFallback: myAvatarFallback),
            variant: .gift(iconURL: iconURL, name: event.giftName ?? "", count: event.num)
        )
    }

    /// 2049 附带：totalReward>0 时派生 luckyGift 消息（对齐 H5 party.js:1167-1187 `newGiftMessage` 末尾）。
    static func luckyGiftDerived(
        event: PartyGiftEvent,
        iconURL: String?,
        totalReward: Int64,
        myUserId: String? = nil,
        myAvatarFallback: String? = nil
    ) -> UnifiedPublicChatMessage {
        return UnifiedPublicChatMessage(
            sender: makeGiftSender(event: event, myUserId: myUserId, myAvatarFallback: myAvatarFallback),
            variant: .luckyGift(iconURL: iconURL, count: event.num, totalReward: totalReward)
        )
    }

    /// 送礼消息 sender 构造（gift/luckyGift 共用）。
    /// - **isSelf** 由 `event.senderUserId == myUserId` 判定
    /// - **avatarURL** 优先取 `event.senderAvatar`（2049 payload 内 `sendUser.avatar`）；
    ///   若为 nil 且是 self，走 `myAvatarFallback`（AnchorInfoStore.mine.icon）兜底 —— 解决"主播本人送礼头像不显示"
    private static func makeGiftSender(
        event: PartyGiftEvent,
        myUserId: String?,
        myAvatarFallback: String?
    ) -> SenderProfile {
        let isSelf: Bool = {
            guard let mine = myUserId, let sid = event.senderUserId else { return false }
            return sid == mine
        }()
        let avatar: String? = event.senderAvatar
                           ?? (isSelf ? myAvatarFallback : nil)
        return SenderProfile(
            userId: event.senderUserId,
            nickname: event.senderNickname ?? "",
            avatarURL: avatar,
            isSelf: isSelf,
            nicknameColor: .default
        )
    }

    // MARK: - 全服/本房中奖公屏（136 / 138 / 140）

    /// 136 / 138 → `.gameWinNotify`。字段从 payload 派生（对齐 H5 `game-win-public-msg.vue:L56-63`）。
    /// **⚠️ 首次真机接入需 preflight**：期望字段 `avatar/nickname/winAmount/gameName/gameIcon`。
    static func gameWinNotify(payload: [String: Any]) -> UnifiedPublicChatMessage? {
        // 兼容 winAmount 是 Number 或 String
        let winAmountStr: String = {
            if let s = payload["winAmount"] as? String { return s }
            if let n = payload["winAmount"] as? NSNumber { return n.stringValue }
            return ""
        }()
        let nickname = (payload["nickname"] as? String) ?? ""
        let gameName = (payload["gameName"] as? String) ?? ""
        guard !nickname.isEmpty || !gameName.isEmpty else { return nil }
        let gameWin = GameWinPayload(
            avatar: payload["avatar"] as? String,
            nickname: nickname,
            winAmount: winAmountStr,
            gameName: gameName,
            gameIcon: payload["gameIcon"] as? String
        )
        return UnifiedPublicChatMessage(
            sender: nil,
            variant: .gameWinNotify(payload: gameWin)
        )
    }

    /// 140 活动中奖公屏广播（含 worldcup 世界杯活动卡）。
    /// **⚠️ 首次真机接入需 preflight**：期望字段 `activityName/quantity/imageURL/joinCTA/avatar`。
    static func winnerBroadcast(payload: [String: Any]) -> UnifiedPublicChatMessage? {
        let activity = (payload["activityName"] as? String) ?? ""
        guard !activity.isEmpty else { return nil }
        let qty = PartyValueNormalizer.intify(payload["quantity"])
        // imageURL 兼容 messageImage / imageURL 两种字段名
        let imageURL = (payload["imageURL"] as? String)
                    ?? (payload["messageImage"] as? String)
                    ?? (payload["image"] as? String)
        // joinCTA 兼容 messageJoin / joinCTA 两种字段名
        let joinCTA = (payload["joinCTA"] as? String) ?? (payload["messageJoin"] as? String)
        let avatar = payload["avatar"] as? String
        return UnifiedPublicChatMessage(
            sender: nil,
            variant: .winnerBroadcast(
                activityName: activity,
                quantity: qty,
                imageURL: imageURL,
                joinCTA: joinCTA,
                avatar: avatar
            )
        )
    }

    // MARK: - 内部工具

    /// 从 NIM `remoteExt` dict 派生 SenderProfile。
    /// H5 `party.js:sendTextMessage` 注入 `serverExtension.data` 里的字段：
    /// - `userId` (String/Int) / `nickname` / `userAvatar`
    /// - `userLevel` (Int) / `isVip` (Bool/Int)
    /// - `role` (Int) — 1=owner, 2=manager (Party 场景) 或 audience=3（不入 SenderProfile.role）
    /// - `chatBubble` (String) / `isPlatformAdmin` (Bool/Int)
    /// - `medalList` (String JSON / [String])
    static func makeSender(
        from ext: [String: Any],
        fallbackNickname: String?,
        isSelf: Bool
    ) -> SenderProfile {
        let userId = PartyValueNormalizer.stringify(ext["userId"])
        let nickname = (ext["nickname"] as? String) ?? fallbackNickname ?? ""
        let avatarURL = (ext["userAvatar"] as? String) ?? (ext["avatar"] as? String)
        let userLevel = PartyValueNormalizer.intify(ext["userLevel"])
        let isVip = boolify(ext["isVip"])
        let isPlatformAdmin = boolify(ext["isPlatformAdmin"])
        let chatBubble = ext["chatBubble"] as? String
        let role = (ext["role"] as? Int).flatMap { PartyRole(rawValue: $0) }   // 1=owner, 2=manager
        let medals = parseMedals(ext["medalList"])
        // v3: 头像框静态图 URL — H5 sendTextMessage 注入字段名 `headFrame`（party.js:1044）
        // fallback 兼容 `headwear` / `avatarFrame` 以防后端字段名微调
        let headFrame = (ext["headFrame"] as? String)
                     ?? (ext["headwear"] as? String)
                     ?? (ext["avatarFrame"] as? String)
        return SenderProfile(
            userId: userId,
            nickname: nickname,
            avatarURL: avatarURL,
            userLevel: userLevel,
            isVip: isVip,
            isHost: role == .owner,
            role: role,
            medals: medals,
            chatBubble: chatBubble,
            isPlatformAdmin: isPlatformAdmin,
            isSelf: isSelf,
            isNewUser: false,
            nicknameColor: .default,
            headFrame: headFrame
        )
    }

    /// Bool 兼容：Bool / Int（0/1） 双识别
    static func boolify(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let i = v as? Int { return i != 0 }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    /// medalList 兼容：数组 / JSON string / nil
    static func parseMedals(_ v: Any?) -> [String] {
        if let arr = v as? [String] { return arr }
        if let arrAny = v as? [Any] {
            return arrAny.compactMap { $0 as? String }
        }
        if let s = v as? String,
           !s.isEmpty,
           let data = s.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [String] {
            return arr
        }
        return []
    }
}
