import Foundation
import NIMSDK

/// 派对房云信聊天室封装（spec §1.4.4）。与直播 `NIMChatroomManager` 并存。
///
/// **抽取候选点（路线图 §五）**：底层 `NIMSDK` 长连接共享；多 ChatManagerDelegate 同时挂时
/// 必须按 `session.sessionType == .chatroom && session.sessionId == self.roomId` **双过滤**
/// 防与直播聊天室公屏窜消息。
///
/// 范围（MVP）：
/// - 进/退聊天室（复用 IM 登录态，不再 login）
/// - `fetchMessageHistory` 拉 30 条 text 历史
/// - 公屏文本发送 + 本地回显
/// - 6 类核心 attachType handler（1001 / 1003 / 1008 / 1012 / 1015 / 2049）
/// - 9 类 INVITE_VIDEO_SEAT 响应 handler（1040-1048）
/// - 连接状态监听（断连置 imAlive=false；重连触发 didReconnect 钩子）
///
/// 整体标 `@MainActor`：NIM 回调统一切到 main actor 处理，避免与 `SessionStore`（@MainActor 单例）
/// 跨 actor 访问 + `@Published` 更新触发 UI thread checker 警告。
@MainActor
final class PartyRoomChatManager: NSObject, ObservableObject {

    /// v3（2026-07-15）：迁移到 unified `UnifiedPublicChatMessage`（跨场景公屏统一模型）。
    /// 不嵌套 `UnifiedPublicChatFeed` ObservableObject，避免 [swiftui-observable-double-publish]
    /// 双 publish；用扁平 `@Published` 数组 + 手写 trim。
    @Published private(set) var messages: [UnifiedPublicChatMessage] = []
    @Published private(set) var onlineCount: Int = 0
    @Published private(set) var connected: Bool = false
    @Published private(set) var imAlive: Bool = false

    /// 公屏消息上限（对齐 H5 `_maxPlubicChatLength` = 100）
    private let messagesLimit: Int = 200

    weak var delegate: PartyRoomChatManagerDelegate?

    /// H M3：自定义消息分发抽到 `PartyMessageRouter`；本 manager 仅保留 enter/exit/pullHistory/sendText
    /// + text + notification 处理。custom 分支转发到 router.processCustom(_:)。
    weak var router: PartyMessageRouter?

    private(set) var roomId: String = ""
    private var hasJoined: Bool = false   // 防止重复 enter

    /// 异常路径（scenePhase=.background 销毁、未走 leave()）下注销 delegate，
    /// 避免下个派对房 manager 实例共存时 NIMSDK 回调跨房分发到错的 PartyStore。
    /// NIMSDK 10.x 的 chatManager/chatroomManager 容器内部 thread-safe，deinit 直接 remove 安全。
    deinit {
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
    }

    // MARK: - 进 / 退 房

    /// 进聊天室。**前置**：NIMSDK 已由直播路径完成 `loginManager.login`；本方法不再 login。
    /// 若未登录上层应在调用前确保 SessionStore.shared.user 完整或显式触发主 IM 登录。
    func enter(yxRoomId: String, nickname: String) {
        guard !hasJoined else {
            AppLogger.party.notice("[PartyChat] already joined room=\(self.roomId, privacy: .public), skip")
            return
        }
        self.roomId = yxRoomId
        guard NIMSDK.shared().loginManager.isLogined() else {
            AppLogger.party.error("[PartyChat] IM not logined; cannot enter chatroom")
            delegate?.partyRoomChat(self, didFailToEnter: "im_not_logined")
            return
        }
        NIMSDK.shared().chatManager.add(self)
        NIMSDK.shared().chatroomManager.add(self)

        let req = NIMChatroomEnterRequest()
        req.roomId = yxRoomId
        req.roomNickname = nickname
        req.retryCount = 3

        NIMSDK.shared().chatroomManager.enterChatroom(req) { [weak self] error, chatroom, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error = error {
                    let code = (error as NSError).code
                    AppLogger.party.error("[PartyChat] enter failed code=\(code, privacy: .public)")
                    // review 202606260029 P2-6：失败回滚 add 在 line 72-73 已注册的 delegate + 清 roomId，
                    // 防止用户重试 enter() 时残留 delegate 双播 / 同实例响应同 roomId 消息。
                    NIMSDK.shared().chatManager.remove(self)
                    NIMSDK.shared().chatroomManager.remove(self)
                    self.roomId = ""
                    self.delegate?.partyRoomChat(self, didFailToEnter: "enter_\(code)")
                    return
                }
                self.hasJoined = true
                self.connected = true
                self.imAlive = true
                self.onlineCount = chatroom?.onlineUserCount ?? 0
                AppLogger.party.info("[PartyChat] enter ok online=\(self.onlineCount, privacy: .public)")
                self.pullHistory()
                self.delegate?.partyRoomChatDidEnter(self)
            }
        }
    }

    /// 退聊天室 + 移除 delegate（防与直播 IM 路径串）。
    func leave() {
        guard hasJoined else { return }
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
        NIMSDK.shared().chatroomManager.exitChatroom(roomId, completion: nil)
        hasJoined = false
        connected = false
        // imAlive 反映长连接，退房不应该置 false（IM 仍在线）
        roomId = ""
        messages = []
        onlineCount = 0
    }

    // MARK: - 历史拉取

    private func pullHistory() {
        let option = NIMHistoryMessageSearchOption()
        option.limit = 30
        option.startTime = 0
        option.order = .asc
        option.messageTypes = [NSNumber(value: NIMMessageType.text.rawValue)]

        NIMSDK.shared().chatroomManager.fetchMessageHistory(roomId, option: option) { [weak self] error, history in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error = error {
                    AppLogger.party.notice("[PartyChat] pullHistory error code=\((error as NSError).code, privacy: .public)")
                    return
                }
                // v3：迁移到 UnifiedPublicChatMessage（isSelf 由 sender userId == self 派生；historical 消息一律 false）
                let mapped = (history ?? []).compactMap { self.makeUnifiedTextMessage(from: $0, isSelf: false) }
                if !mapped.isEmpty {
                    self.messages.insert(contentsOf: mapped, at: 0)
                    self.trimIfNeeded()
                }
                AppLogger.party.info("[PartyChat] history pulled count=\(mapped.count, privacy: .public)")
            }
        }
    }

    // MARK: - 发送公屏文本（本地回显）

    /// 本地立即回显 → 异步 chatManager.send；不等服务端回声。
    /// 文本走 NIM `.text` 标准消息；`remoteExt` 附挂 H5 sendTextMessage 全字段
    /// （对齐 `livechat-h5/src/stores/modules/party.js:1044` serverExtension.data：
    /// `userId / nickname / userAvatar / isVip / userLevel / role / headFrame / chatBubble / isPlatformAdmin`）
    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hasJoined else { return }

        let me = SessionStore.shared.user
        let anchorMine = AnchorInfoStore.shared.mine
        let myUserId = me?.userId.map(String.init)
        let myNickname = me?.nickname ?? ""
        // 自己角色在 PartyStore 衍生；这里默认 .audience（房主发文本时由 Store 上层覆盖 remoteExt）
        let myRole: PartyRoomRoleType = .audience
        let myAvatar = me?.icon ?? anchorMine?.icon
        let myChatBubble = anchorMine?.chatBubble

        // 本地立即回显（v3：走 unified Adapter，字段富化）
        // 主播端本人无 headFrame 数据（后端 AnchorInfo 无此字段），nil
        let local = PartyPublicChatAdapter.selfEchoText(
            text: trimmed,
            myUserId: myUserId,
            myNickname: myNickname,
            myAvatar: myAvatar,
            myLevel: anchorMine?.level,
            myIsVip: false,
            myChatBubble: myChatBubble,
            myRoleRaw: myRole.rawValue,
            myHeadFrame: nil
        )
        appendMessage(local)

        // 构造 NIMMessage 并发送 —— 注入 H5 sendTextMessage 全字段（对齐 party.js:1044）
        let msg = NIMMessage()
        msg.text = trimmed
        var ext: [String: Any] = [:]
        if let uid = myUserId { ext["userId"] = uid }
        if !myNickname.isEmpty { ext["nickname"] = myNickname }
        if let av = myAvatar, !av.isEmpty { ext["userAvatar"] = av }
        if let lv = anchorMine?.level { ext["userLevel"] = lv }
        ext["role"] = myRole.rawValue
        if let cb = myChatBubble, !cb.isEmpty { ext["chatBubble"] = cb }
        // isVip / headFrame / medalList / isPlatformAdmin 主播端本人无源，留给远端消息填充
        msg.remoteExt = ext

        let session = NIMSession(roomId, type: .chatroom)
        do {
            try NIMSDK.shared().chatManager.send(msg, to: session)
        } catch {
            AppLogger.party.error("[PartyChat] send failed: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - 工具

    /// 从 NIM `.text` 消息构造 unified message（对齐 H5 addPartyChatRecordsMsg 字段派生）。
    /// NIMMessage 依赖内联在此（保持 PartyPublicChatAdapter 主文件 zero-NIM 便于 test target 单测）。
    ///
    /// **头像回落逻辑**（H5 用户端 sendTextMessage 不注入 userAvatar 到 remoteExt，
    /// H5 UI 层取自 NIM V2 `userInfoConfig.senderAvatar` —— iOS V1 SDK 无此 API，改走 `NIMUser` 缓存）：
    /// 1. remoteExt.userAvatar 有 → 使用（iOS 主播端发的消息按此约定）
    /// 2. 否则 `NIMSDK.userManager.userInfo(m.from)` 缓存查（H5 用户端消息 SDK 自动填充 userInfo）
    /// 3. 都无 → nil，AvatarView 显示默认图占位
    private func makeUnifiedTextMessage(from m: NIMMessage, isSelf: Bool) -> UnifiedPublicChatMessage? {
        guard m.messageType == .text else { return nil }
        var ext = m.remoteExt as? [String: Any] ?? [:]
        let text = m.text ?? ""
        guard !text.isEmpty else { return nil }
        // 头像 fallback：remoteExt 无 userAvatar 时从 NIMUser 缓存查（对齐 H5 senderAvatar 语义）
        if (ext["userAvatar"] as? String)?.isEmpty ?? true,
           let from = m.from,
           let nimUser = NIMSDK.shared().userManager.userInfo(from),
           let avatarUrl = nimUser.userInfo?.avatarUrl,
           !avatarUrl.isEmpty {
            ext["userAvatar"] = avatarUrl
        }
        // 昵称 fallback：同理，remoteExt.nickname 无值时从 NIMUser 或 m.senderName 补
        if (ext["nickname"] as? String)?.isEmpty ?? true,
           let from = m.from,
           let nimUser = NIMSDK.shared().userManager.userInfo(from),
           let nickName = nimUser.userInfo?.nickName,
           !nickName.isEmpty {
            ext["nickname"] = nickName
        }
        return UnifiedPublicChatMessage(
            sender: PartyPublicChatAdapter.makeSender(from: ext, fallbackNickname: m.senderName, isSelf: isSelf),
            variant: .text(content: text)
        )
    }

    /// 通用 append + trim（供内部 + delegate append 方法调用）。
    func appendMessage(_ msg: UnifiedPublicChatMessage) {
        messages.append(msg)
        trimIfNeeded()
    }

    /// v3 便利方法：Store delegate 需要 append 多种公屏消息（.announcement / .partyModeSwitch / .gift / .gameWinNotify / .winnerBroadcast / .luckyGift）
    /// 通过公开的 `appendMessage` 一站式入口；Adapter 生成 message + 此处 trim。
    /// 保持 Store 端调用点极简：`chat.appendMessage(PartyPublicChatAdapter.systemMode(text: ...))`。

    /// 追加本地系统消息（E v2 §1/§2：切模板 / Mic Application 开关广播后公屏落一条业务系统消息）。
    /// v3（2026-07-15）：迁移到 `.partyModeSwitch(kind: .mode)` unified variant；旧 caller 仍可用（默认 kind=.mode）。
    /// **推荐**：Store 端直接调 Adapter.systemMode/systemApplication/... 生成消息后 appendMessage。
    func appendLocalSystemMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendMessage(PartyPublicChatAdapter.systemMode(text: trimmed))
    }

    /// 更新指定消息的 translation 字段（对齐 H5 messageScroller.vue translatedClick）。
    /// 命中不到 msgId 或非 `.text` variant 时静默 no-op。
    func setTranslation(messageId: UUID, translation: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let old = messages[idx]
        guard case .text(let content, let mentions, _, let replyToNick) = old.variant else { return }
        let newVariant: PublicChatVariant = .text(
            content: content,
            mentions: mentions,
            translation: translation,
            replyToNick: replyToNick
        )
        messages[idx] = UnifiedPublicChatMessage(
            id: old.id,
            timestamp: old.timestamp,
            sender: old.sender,
            variant: newVariant
        )
    }

    private func trimIfNeeded() {
        if messages.count > messagesLimit {
            messages.removeFirst(messages.count - messagesLimit)
        }
    }

    /// 双过滤：仅本聊天室 + 本 roomId 的消息进入处理流程
    private func belongsToThisRoom(_ m: NIMMessage) -> Bool {
        guard let s = m.session else { return false }
        return s.sessionType == .chatroom && s.sessionId == roomId
    }

    // MARK: - 处理消息（统一在 main actor 执行，避免跨 actor 访问 SessionStore）

    fileprivate func processIncoming(_ batch: [NIMMessage]) {
        var textPush: [UnifiedPublicChatMessage] = []
        var memberDelta = 0

        // 判定 isSelf：ext["userId"] == 当前登录 userId
        let myUserIdStr = SessionStore.shared.user?.userId.map(String.init)

        for m in batch {
            guard belongsToThisRoom(m) else { continue }

            switch m.messageType {
            case .text:
                // v3：远端消息通过 ext.userId 判 isSelf（可能是自己在其他端发的回声）
                let isSelf: Bool = {
                    guard let mine = myUserIdStr,
                          let ext = m.remoteExt as? [String: Any],
                          let uid = PartyValueNormalizer.stringify(ext["userId"]) else {
                        return false
                    }
                    return uid == mine
                }()
                if let pm = makeUnifiedTextMessage(from: m, isSelf: isSelf) {
                    textPush.append(pm)
                }

            case .custom:
                router?.processCustom(m)

            case .notification:
                if let obj = m.messageObject as? NIMNotificationObject,
                   let content = obj.content as? NIMChatroomNotificationContent {
                    if content.eventType == .enter {
                        memberDelta += 1
                    } else if content.eventType == .exit {
                        memberDelta -= 1
                    }
                }

            default:
                break
            }
        }

        for m in textPush { appendMessage(m) }
        if memberDelta != 0 {
            onlineCount = max(0, onlineCount + memberDelta)
        }
    }

    // H M3：dispatchCustom / handle / handleKickedOut / handleVideoSeatInvite / unwrapDataField
    //       全部抽到 `PartyMessageRouter`。本 manager 仅保留 IM 通道层（enter/exit/text/notification）。
    //       processIncoming 内 case .custom 分支已改为转发到 router.processCustom(_:)。
}

// MARK: - 收消息（NIMSDK 回调，非 main actor → Task 切回）

extension PartyRoomChatManager: NIMChatManagerDelegate {

    nonisolated func onRecvMessages(_ messages: [NIMMessage]) {
        Task { @MainActor [weak self] in
            self?.processIncoming(messages)
        }
    }
}

// MARK: - 连接状态

extension PartyRoomChatManager: NIMChatroomManagerDelegate {

    /// NIMChatroomConnectionState 真实枚举：entering(0) / enterOK(1) / enterFailed(2) / loseConnection(3)
    nonisolated func chatroom(_ roomId: String, connectionStateChanged state: NIMChatroomConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard roomId == self.roomId else { return }
            switch state {
            case .entering:
                break  // 中间态不更新
            case .enterOK:
                self.imAlive = true
                self.connected = true
                AppLogger.party.notice("[PartyChat] chatroom enterOK → reconnect hook")
                self.delegate?.partyRoomChatDidReconnect(self)
            case .enterFailed:
                self.imAlive = false
                self.connected = false
            case .loseConnection:
                self.imAlive = false
                self.connected = false
            @unknown default:
                break
            }
            AppLogger.party.notice("[PartyChat] chatroom state=\(state.rawValue, privacy: .public)")
        }
    }
}

// MARK: - delegate 协议（PartyStore 实现）

@MainActor
protocol PartyRoomChatManagerDelegate: AnyObject {
    func partyRoomChatDidEnter(_ chat: PartyRoomChatManager)
    func partyRoomChat(_ chat: PartyRoomChatManager, didFailToEnter reason: String)
    func partyRoomChatDidReconnect(_ chat: PartyRoomChatManager)
    func partyRoomChatDidKickOut(_ chat: PartyRoomChatManager)

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveSeatUpdate payload: [String: Any], raw: NIMMessage)
    /// 1012 全量重拉指令；`msgTimestampMs` 用于 `lastRoomTempSwitchAt` 精确判丢旧广播（对齐 1017 pattern）
    func partyRoomChatDidRequireSeatListReload(_ chat: PartyRoomChatManager, msgTimestampMs: Int64)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveProhibitMic payload: [String: Any], raw: NIMMessage)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveMediaUpdate payload: [String: Any], raw: NIMMessage)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveGift payload: [String: Any], raw: NIMMessage)
    /// v23（2026-07-13）用户进场动画（attachType=80）：VIP/带座驾用户进入派对房时触发座驾 SVGA/MP4 全屏特效
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveEnterAnimation payload: [String: Any], raw: NIMMessage)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveVideoSeatInvite invite: PartyVideoSeatInvite)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveInviteResult result: PartyVideoSeatInviteResult)

    // E v2（2026-07-14）Room Mode + Mic Application IM 消费 callback
    /// 1017 切模板广播；`msgTimestampMs` 用于 spec §1 IM 处理步骤 1 乱序判丢（vs `lastRoomTempSwitchAt`）
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveModeChange payload: [String: Any], msgTimestampMs: Int64)
    /// 1018 排麦通知；payload 内 `{ num, operation, userId }`（真机验证前起草）
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveQueueSeatUpdate payload: [String: Any], raw: NIMMessage)
    /// 1021 Mic Application 开关广播；payload 内 `{ enable: Int }`（0/1）
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveMicApplicationSwitch payload: [String: Any], raw: NIMMessage)

    /// F 期（2026-07-14）1029 派对房私 call 状态通知
    /// payload 已通过 PartyPrivateCallNotify decoder 严格校验（status enum 硬要求）
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceivePrivateCallNotify notify: PartyPrivateCallNotify, raw: NIMMessage)

    // MARK: - v3（2026-07-14）Step 1 通知基建骨架 delegate

    /// 1019 房管变更（仅本人被设/取消房管时公屏文案；Store 端做 userId==self 校验）。
    /// payload 期望 `{ userId, authType }`（authType: 1=设房管 / 2=取消）—— 真机 preflight。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveAuthUpdate payload: [String: Any], raw: NIMMessage)

    /// 1049 房间通告公屏广播。payload 期望 `{ text, roomId }`—— roomId 校验后落公屏。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveRoomAnnouncement payload: [String: Any], raw: NIMMessage)

    /// 1050 幸运数字抽数公屏卡片（⚠️ 直读 ext，无 ext.data 包裹）。
    /// ext 期望 `{ userId, nickname, luckyNumber, giftId, ... }` —— 真机 preflight。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveLuckyNumberDraw payload: [String: Any], raw: NIMMessage)

    /// 1051 幸运数字中奖公屏广播（⚠️ 直读 ext）。
    /// ext 期望 `{ userId, nickname, luckyNumber, winAmount, ... }` —— 真机 preflight。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveLuckyNumberWin payload: [String: Any], raw: NIMMessage)

    /// 136 游戏中奖公屏通知（全服，session 通道主入口 + Party 通道兜底）。
    /// payload 期望 `{ avatar, nickname, winAmount, gameName, gameIcon, gameId, gameType, messageSkin }` —— 真机 preflight。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveGameWinGlobal payload: [String: Any], raw: NIMMessage)

    /// 138 PK 小奖 / Party 房游戏小奖（本房，字段同 136）。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceivePkSmallPrize payload: [String: Any], raw: NIMMessage)

    /// 140 活动中奖公屏广播（含 worldcup 世界杯活动卡）。
    /// payload 期望 `{ activityName, quantity, imageURL, joinCTA, avatar, cardType, ... }` —— 真机 preflight。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveWinnerBroadcast payload: [String: Any], raw: NIMMessage)
}
