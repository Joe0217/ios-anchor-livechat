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

    private(set) var roomId: String = ""
    private var hasJoined: Bool = false   // 防止重复 enter

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
                dispatchCustom(m)

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

    /// 自定义消息分发：按 `remoteExt.type` / `remoteExt.attachType` 取数字键 → enum 转换 → 6+9 类 handler。
    /// 未识别项打 warning 日志；值冲突项（45 / 1029）+ 范围外 attachType（1004/1014/1017/1018-1027/1049-1052/1100-1112）
    /// 通过 `PartyKnownButUnhandledAttachType.codes` 降噪。
    private func dispatchCustom(_ m: NIMMessage) {
        guard let ext = m.remoteExt as? [String: Any] else { return }
        // 兼容两种键名：sapi 数字消息用 type，聊天室 attach 用 attachType
        let raw: Int
        if let v = ext["type"] as? Int { raw = v }
        else if let v = ext["attachType"] as? Int { raw = v }
        else if let s = ext["type"] as? String, let v = Int(s) { raw = v }
        else if let s = ext["attachType"] as? String, let v = Int(s) { raw = v }
        else {
            AppLogger.party.notice("[PartyChat] custom msg missing type field; ext keys=\(Array(ext.keys), privacy: .public)")
            return
        }

        guard let kind = PartyAttachType.from(rawValue: raw) else {
            // 值冲突 / F 期常量 → 仅 debug 级降噪
            if PartyKnownButUnhandledAttachType.codes.contains(raw) {
                AppLogger.party.debug("[PartyChat] known-but-unhandled attachType=\(raw, privacy: .public)")
            } else {
                AppLogger.party.notice("[PartyChat] unrecognized attachType=\(raw, privacy: .public)")
            }
            return
        }

        handle(attachType: kind, message: m, ext: ext)
    }

    private func handle(attachType: PartyAttachType, message m: NIMMessage, ext: [String: Any]) {
        // gzip payload：data 字段（Base64）→ Data → GzipDecompressor → JSON
        var payload: [String: Any] = [:]
        if attachType.requiresGzip {
            payload = decodeGzipPayload(ext: ext)
        } else if let data = ext["data"] as? [String: Any] {
            payload = data
        }

        AppLogger.party.info("[PartyChat] handle \(attachType.rawValue, privacy: .public)")

        switch attachType {
        case .seatUpdate:
            delegate?.partyRoomChat(self, didReceiveSeatUpdate: payload, raw: m)
        case .seatUpdateList:
            delegate?.partyRoomChatDidRequireSeatListReload(self)
        case .prohibitMic:
            delegate?.partyRoomChat(self, didReceiveProhibitMic: payload, raw: m)
        case .kickedOut:
            handleKickedOut(payload: payload)
        case .updateMedia:
            delegate?.partyRoomChat(self, didReceiveMediaUpdate: payload, raw: m)
        case .giftCompressed:
            delegate?.partyRoomChat(self, didReceiveGift: payload, raw: m)
        case .inviteVideoSeat:
            handleVideoSeatInvite(payload: payload, raw: m)
        case .inviteVideoSeatAccept:
            delegate?.partyRoomChat(self, didReceiveInviteResult: .accepted)
        case .inviteVideoSeatReject:
            delegate?.partyRoomChat(self, didReceiveInviteResult: .rejected)
        case .inviteVideoSeatTimeout:
            delegate?.partyRoomChat(self, didReceiveInviteResult: .timeout)
        case .inviteVideoSeatLeave:
            delegate?.partyRoomChat(self, didReceiveInviteResult: .leave)
        case .inviteVideoSeatOccupied:
            delegate?.partyRoomChat(self, didReceiveInviteResult: .occupied)
        case .inviteVideoSeatAlreadyOn:
            delegate?.partyRoomChat(self, didReceiveInviteResult: .alreadyOn)
        case .inviteVideoSeatBroadcast:
            delegate?.partyRoomChat(self, didReceiveInviteResult: .broadcast)
        case .inviteVideoSeatJoinFailed:
            delegate?.partyRoomChat(self, didReceiveInviteResult: .joinFailed)
        }
    }

    /// 被踢双字段守护（spec §1.4.4 防误踢）：payload 内 `userId == 自己 && roomId == 当前房` 才认。
    private func handleKickedOut(payload: [String: Any]) {
        let myUserId = SessionStore.shared.user?.userId.map(String.init)
        let targetUserId = (payload["userId"] as? String) ?? (payload["userId"].map { "\($0)" })
        let targetRoomId = payload["roomId"] as? String

        guard let me = myUserId, let t = targetUserId, me == t else {
            AppLogger.party.notice("[PartyChat] kickedOut not for me, skip")
            return
        }
        guard let r = targetRoomId, r == roomId else {
            AppLogger.party.notice("[PartyChat] kickedOut roomId mismatch, skip")
            return
        }
        delegate?.partyRoomChatDidKickOut(self)
    }

    private func handleVideoSeatInvite(payload: [String: Any], raw m: NIMMessage) {
        let inviteId = (payload["inviteId"] as? String) ?? ""
        let seatIndex = (payload["seatIndex"] as? Int) ?? -1
        guard !inviteId.isEmpty, seatIndex > 0 else {
            AppLogger.party.notice("[PartyChat] invite payload missing inviteId/seatIndex")
            return
        }
        let invite = PartyVideoSeatInvite(
            inviteId: inviteId,
            seatIndex: seatIndex,
            fromUserId: payload["fromUserId"] as? String,
            fromNickname: payload["fromNickname"] as? String,
            roomId: payload["roomId"] as? String ?? roomId,
            timestamp: Int64(m.timestamp * 1000)
        )
        delegate?.partyRoomChat(self, didReceiveVideoSeatInvite: invite)
    }

    /// 解 gzip + Base64 payload：`ext.data` 或 `ext.content` 字段都试
    /// 真实字段位 M3 真机自检确认。
    private func decodeGzipPayload(ext: [String: Any]) -> [String: Any] {
        let base64Str = (ext["data"] as? String) ?? (ext["content"] as? String) ?? ""
        guard !base64Str.isEmpty, let zipped = Data(base64Encoded: base64Str) else {
            AppLogger.party.notice("[PartyChat] gzip payload base64 missing or invalid")
            return [:]
        }
        do {
            let raw = try GzipDecompressor.decompress(zipped)
            guard let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                AppLogger.party.notice("[PartyChat] gzip payload not a JSON object")
                return [:]
            }
            return json
        } catch {
            AppLogger.party.error("[PartyChat] gzip decompress failed: \(String(describing: error), privacy: .private)")
            return [:]
        }
    }
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
