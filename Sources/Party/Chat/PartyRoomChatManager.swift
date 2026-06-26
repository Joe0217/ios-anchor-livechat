import Foundation
import NIMSDK

/// 派对房公屏一条消息（UI 模型，非持久化）。
struct PartyChatMessage: Identifiable, Equatable {
    let id = UUID()
    let userId: String?
    let nickname: String?
    let role: PartyRoomRoleType?
    let text: String
    let msgType: PartyMsgType
    let isLocal: Bool                  // 本端回显（未等服务端广播即先 push 的消息）
    let timestamp: TimeInterval
}

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

    @Published private(set) var messages: [PartyChatMessage] = []
    @Published private(set) var onlineCount: Int = 0
    @Published private(set) var connected: Bool = false
    @Published private(set) var imAlive: Bool = false

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
                let mapped = (history ?? []).compactMap { self.makeTextMessage(from: $0, isLocal: false) }
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
    /// 文本走 NIM `.text` 标准消息；`remoteExt` 附挂 userId/role/nickname。
    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hasJoined else { return }

        let me = SessionStore.shared.user
        let myUserId = me?.userId.map(String.init)
        let myNickname = me?.nickname ?? ""
        // 自己角色在 PartyStore 衍生；这里默认 .audience（房主发文本时由 Store 上层覆盖 remoteExt）
        let myRole: PartyRoomRoleType = .audience

        // 本地立即回显
        let local = PartyChatMessage(
            userId: myUserId,
            nickname: myNickname,
            role: myRole,
            text: trimmed,
            msgType: .text,
            isLocal: true,
            timestamp: Date().timeIntervalSince1970
        )
        push(local)

        // 构造 NIMMessage 并发送
        let msg = NIMMessage()
        msg.text = trimmed
        var ext: [String: Any] = [:]
        if let uid = myUserId { ext["userId"] = uid }
        ext["role"] = myRole.rawValue
        if !myNickname.isEmpty { ext["nickname"] = myNickname }
        msg.remoteExt = ext

        let session = NIMSession(roomId, type: .chatroom)
        do {
            try NIMSDK.shared().chatManager.send(msg, to: session)
        } catch {
            AppLogger.party.error("[PartyChat] send failed: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - 工具

    private func makeTextMessage(from m: NIMMessage, isLocal: Bool) -> PartyChatMessage? {
        guard m.messageType == .text else { return nil }
        let ext = m.remoteExt as? [String: Any] ?? [:]
        let userId = (ext["userId"] as? String) ?? (ext["userId"].map { "\($0)" })
        let nickname = (ext["nickname"] as? String) ?? m.senderName
        let role = PartyRoomRoleType(rawValue: (ext["role"] as? Int) ?? -1)
        let text = m.text ?? ""
        guard !text.isEmpty else { return nil }
        return PartyChatMessage(
            userId: userId,
            nickname: nickname,
            role: role,
            text: text,
            msgType: .text,
            isLocal: isLocal,
            timestamp: m.timestamp
        )
    }

    private func push(_ msg: PartyChatMessage) {
        messages.append(msg)
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        if messages.count > 200 {
            messages.removeFirst(messages.count - 200)
        }
    }

    /// 双过滤：仅本聊天室 + 本 roomId 的消息进入处理流程
    private func belongsToThisRoom(_ m: NIMMessage) -> Bool {
        guard let s = m.session else { return false }
        return s.sessionType == .chatroom && s.sessionId == roomId
    }

    // MARK: - 处理消息（统一在 main actor 执行，避免跨 actor 访问 SessionStore）

    fileprivate func processIncoming(_ batch: [NIMMessage]) {
        var textPush: [PartyChatMessage] = []
        var memberDelta = 0

        for m in batch {
            guard belongsToThisRoom(m) else { continue }

            switch m.messageType {
            case .text:
                if let pm = makeTextMessage(from: m, isLocal: false) {
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

        for m in textPush { push(m) }
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
    func partyRoomChatDidRequireSeatListReload(_ chat: PartyRoomChatManager)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveProhibitMic payload: [String: Any], raw: NIMMessage)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveMediaUpdate payload: [String: Any], raw: NIMMessage)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveGift payload: [String: Any], raw: NIMMessage)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveVideoSeatInvite invite: PartyVideoSeatInvite)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveInviteResult result: PartyVideoSeatInviteResult)
}
