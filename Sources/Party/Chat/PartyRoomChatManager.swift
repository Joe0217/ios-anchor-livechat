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

    /// 公屏消息上限（对齐 H5 `_maxPlubicChatLength` = 100）。
    private let messagesLimit: Int = 100

    /// 小窗期间暂存的新公屏。H5 不在小窗时更新可见公屏，恢复后才将最近 100 条合并。
    private var defersMessages = false
    private var deferredMessages: [UnifiedPublicChatMessage] = []

    weak var delegate: PartyRoomChatManagerDelegate?

    /// H M3：自定义消息分发抽到 `PartyMessageRouter`；本 manager 仅保留 enter/exit/pullHistory/sendText
    /// + text + notification 处理。custom 分支转发到 router.processCustom(_:)。
    weak var router: PartyMessageRouter?

    /// 发送文本时的当前房间身份。由 `PartyStore` 在发送瞬间提供，不能在此处缓存：
    /// 1019/1024 和 1001 都可能在同一会话内改变房管/平台管理员身份。
    /// 闭包使用弱引用，避免 ChatManager 与 PartyStore 形成循环持有。
    var outgoingTextMetadataProvider: (() -> (role: PartyRoomRoleType, isPlatformAdmin: Bool))?

    private(set) var roomId: String = ""
    private var hasJoined: Bool = false   // 防止重复 enter
    /// 云信进房是异步回调。每次 enter / leave 递增，使迟到的旧回调不能把已经退掉的会话复活。
    private var chatroomOperationGeneration: UInt = 0

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
        guard !hasJoined, roomId.isEmpty else {
            AppLogger.party.notice("[PartyChat] enter skipped joined=\(self.hasJoined, privacy: .public) roomLength=\(self.roomId.count, privacy: .public)")
            return
        }
        chatroomOperationGeneration &+= 1
        let operationGeneration = chatroomOperationGeneration
        self.roomId = yxRoomId
        guard NIMSDK.shared().loginManager.isLogined() else {
            AppLogger.party.error("[PartyChat] IM not logined; cannot enter chatroom")
            self.roomId = ""
            delegate?.partyRoomChat(self, didFailToEnter: "im_not_logined")
            return
        }
        NIMSDK.shared().chatManager.add(self)
        NIMSDK.shared().chatroomManager.add(self)

        let req = NIMChatroomEnterRequest()
        req.roomId = yxRoomId
        req.roomNickname = nickname
        req.retryCount = 3
        req.tags = "[\"party_room\"]"

        // 与 H5 Party 聊天室 enter 对齐：云信成员进出事件需要携带该成员的身份上下文。
        let user = SessionStore.shared.user
        var notifyExt: [String: Any] = [:]
        if let yxAccid = user?.yxAccid, !yxAccid.isEmpty {
            notifyExt["yxAccid"] = yxAccid
        }
        if let userId = user?.userId {
            notifyExt["userId"] = userId
        }
        if let userLevel = user?.userLevel, !userLevel.isEmpty {
            notifyExt["userLevel"] = userLevel
        }
        if let userNickname = user?.nickname, !userNickname.isEmpty {
            notifyExt["nickname"] = userNickname
        }
        if JSONSerialization.isValidJSONObject(notifyExt),
           let data = try? JSONSerialization.data(withJSONObject: notifyExt),
           let json = String(data: data, encoding: .utf8) {
            req.roomNotifyExt = json
        }
        NIMSDK.shared().chatroomManager.enterChatroom(req) { [weak self] error, chatroom, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 用户可能在进房回调返回前已选择退出。此时旧回调不可重新写入 joined 状态；
                // 若云信实际已进房，补发一次 exit，避免服务端仍把主播视为 Party 成员。
                guard self.chatroomOperationGeneration == operationGeneration,
                      self.roomId == yxRoomId else {
                    guard error == nil else { return }
                    let currentRoomId = self.roomId
                    let isNewActiveSameRoom = currentRoomId == yxRoomId && self.hasJoined
                    guard !isNewActiveSameRoom else {
                        return
                    }
                    NIMSDK.shared().chatroomManager.exitChatroom(yxRoomId, completion: nil)
                    return
                }
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
                // 派对房观众数**含自己**（对齐 H5 用户端 usePartyHooks.js:305
                // `audienceNum = onlineUserCount || 0`，无 -1；安卓 PartyRoomVM.kt 同款）。
                // 直播房 useLiveRoom.js:347 才 -1 减主播；派对房无此语义（房主也算参与者）。
                self.onlineCount = chatroom?.onlineUserCount ?? 0
                AppLogger.party.info("[PartyChat] enter ok online=\(self.onlineCount, privacy: .public)")
                self.pullHistory()
                self.delegate?.partyRoomChatDidEnter(self)
            }
        }
    }

    /// 退聊天室 + 移除 delegate（防与直播 IM 路径串）。
    /// 即使聊天室进房回调尚未返回，也按已记录的 roomId 发起退出，防止迟到回调复活旧会话。
    func leave() {
        clearDeferredMessages()
        let exitingRoomId = roomId
        // 必须先失效进房回调：exit 允许在 enterChatroom 仍 in-flight 时触发。
        chatroomOperationGeneration &+= 1
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
        hasJoined = false
        connected = false
        // imAlive 反映长连接，退房不应该置 false（IM 仍在线）
        roomId = ""
        messages = []
        onlineCount = 0

        guard !exitingRoomId.isEmpty else {
            return
        }
        NIMSDK.shared().chatroomManager.exitChatroom(exitingRoomId, completion: nil)
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
        // H5 `sendTextMessage` 同步把当前 room role 和平台管理员身份写进 serverExtension。
        // 不可固定为 audience：房主/房管/超管在消息到达其他端时需要显示正确角色徽章。
        let outgoingMetadata = outgoingTextMetadataProvider?()
        let myRole = outgoingMetadata?.role ?? .audience
        let isPlatformAdmin = outgoingMetadata?.isPlatformAdmin ?? false
        let myAvatar = me?.icon ?? anchorMine?.icon
        let myChatBubble = AnchorInfoStore.shared.currentChatBubble

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
            myIsPlatformAdmin: isPlatformAdmin,
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
        ext["isPlatformAdmin"] = isPlatformAdmin
        // 主播端固定注入 userType=2（对齐 android `PartyRoomVM.kt:949`；差异文档 §1.3 明示）—
        // 与坐麦身份无关；主播以观众身份进他人 Party 房时消息仍带 2，接收端据此差异化展示（等级/VIP 徽章仅对 userType=1 用户消息渲染）
        ext["userType"] = 2
        // isVip / headFrame / medalList 主播端本人无源，留给远端消息填充
        msg.remoteExt = ext

        let session = NIMSession(roomId, type: .chatroom)
        do {
            try NIMSDK.shared().chatManager.send(msg, to: session)
        } catch {
            AppLogger.party.error("[PartyChat] send failed: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - 发送自定义消息（表情等 attachType 通道）

    /// 发送 attachType custom 消息（F 里程碑表情面板 attachType `-10 / -11` 使用）。
    ///
    /// **对齐 H5 `usePartyHooks.js:1748-1774` `sendCustomMsg({ attachType, data: JSON.stringify(exData) })`**：
    /// - `remoteExt.attachType = attachType`
    /// - `remoteExt.data = data`（字典 · **本方法内不做 JSON.stringify**；后端 chatroom 服务端会按 dict 处理，
    ///   若观察真机需 stringify 再改；对齐 gzip/JSON/dict 三态解码基础设施 `NIMPayloadDecoder.unwrapDataField`）
    /// - 走 NIM `.custom` 消息类型（`NIMCustomObject` + `NIMCustomAttachment` protocol · 空 encode）
    /// - 不做本地回显（云信 chatroom 会 push 自己发的消息回来 · 由 IM router self-echo skip 逻辑处理）
    ///
    /// **权限**：调用方需保证已 `hasJoined`；未 joined 时 return（防漏收 IM 后异步 send 崩）。
    func sendCustomMessage(attachType: Int, data: [String: Any]) {
        guard hasJoined else {
            AppLogger.party.notice("[PartyChat] sendCustomMessage skip: not joined attachType=\(attachType, privacy: .public)")
            return
        }
        let msg = NIMMessage()
        let attachment = PartyGenericCustomAttachment(attachType: attachType, data: data)
        let obj = NIMCustomObject()
        obj.attachment = attachment
        msg.messageObject = obj
        // remoteExt 是 chatroom 通道消息路由 + 消费的真值来源（IM router.processCustom 从 remoteExt 读 attachType）
        msg.remoteExt = [
            "attachType": attachType,
            "data": data,
        ]

        let session = NIMSession(roomId, type: .chatroom)
        do {
            try NIMSDK.shared().chatManager.send(msg, to: session)
            AppLogger.party.info("[PartyChat] sendCustomMessage sent attachType=\(attachType, privacy: .public) dataKeys=\(Array(data.keys), privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyChat] sendCustomMessage failed attachType=\(attachType, privacy: .public) err=\(String(describing: error), privacy: .private)")
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
        let source: PublicChatMessageSource? = {
            let messageId = m.messageId
            guard !messageId.isEmpty,
                  let fromAccid = m.from, !fromAccid.isEmpty else {
                return nil
            }
            return PublicChatMessageSource(
                messageId: messageId,
                timetag: Int64(m.timestamp * 1000),
                fromAccid: fromAccid
            )
        }()
        return UnifiedPublicChatMessage(
            timestamp: Date(timeIntervalSince1970: m.timestamp),
            sender: PartyPublicChatAdapter.makeSender(from: ext, fallbackNickname: m.senderName, isSelf: isSelf),
            variant: .text(content: text),
            source: source
        )
    }

    /// 通用 append + trim（供内部 + delegate append 方法调用）。
    func appendMessage(_ msg: UnifiedPublicChatMessage) {
        guard !defersMessages else {
            deferredMessages.append(msg)
            if deferredMessages.count > messagesLimit {
                deferredMessages.removeFirst(deferredMessages.count - messagesLimit)
            }
            return
        }
        messages.append(msg)
        trimIfNeeded()
    }

    /// 进入 Party 小窗：后续实时公屏先入 pending，避免更新已卸载的房间页面。
    func beginDeferringMessages() {
        defersMessages = true
        deferredMessages.removeAll()
    }

    /// 恢复 Party 房间页时合并 pending。只保留最近 100 条，和 H5 `setPendingMsg()` 一致。
    func flushDeferredMessages() {
        defersMessages = false
        guard !deferredMessages.isEmpty else { return }
        messages.append(contentsOf: deferredMessages.suffix(messagesLimit))
        deferredMessages.removeAll()
        trimIfNeeded()
    }

    /// 离开 Party 会话时丢弃尚未显示的 pending，防止带入下一房。
    func clearDeferredMessages() {
        defersMessages = false
        deferredMessages.removeAll()
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
            variant: newVariant,
            source: old.source
        )
    }

    /// 删除指定公屏消息的本地副本。服务端删除成功后立即调用，和 H5 的乐观移除保持一致。
    func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        deferredMessages.removeAll { $0.id == id }
    }

    /// 消费云信聊天室撤回通知。`revokedMessageId` 与文本消息的 `NIMMessage.messageId` 相同；
    /// 系统消息没有 source，因此不会被误删。
    func removeMessage(sourceMessageId: String) {
        guard !sourceMessageId.isEmpty else { return }
        messages.removeAll { $0.source?.messageId == sourceMessageId }
        deferredMessages.removeAll { $0.source?.messageId == sourceMessageId }
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
        var memberEnterNotifications: [(extension: String?, nickname: String?)] = []
        var recalledMessageIds = Set<String>()

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
                    // H5 `handleNotificationMessage` 对聊天室事件 16（消息撤回）按 messageClientId
                    // 移除公屏记录。V1 SDK 的对应事件是 `.recall`，被撤回消息 ID 由
                    // `revokedMessageId` 提供。收集到本批次末尾统一删除，避免边遍历边修改 UI 数据源。
                    if content.eventType == .recall {
                        if let messageId = content.revokedMessageId, !messageId.isEmpty {
                            recalledMessageIds.insert(messageId)
                        }
                        continue
                    }
                    // 对齐 H5 party.js:1013 过滤自己：仅当事件 target 不是自己时才计入观众数增减
                    // （云信 chatroom member.userId 即 yxAccid，与 SessionStore.user.yxAccid 直比）
                    let mineYxAccid = SessionStore.shared.user?.yxAccid ?? ""
                    let evtUserId = content.targets?.first?.userId ?? ""
                    let isSelf = !evtUserId.isEmpty && evtUserId == mineYxAccid
                    if content.eventType == .enter {
                        if !isSelf { memberDelta += 1 }
                        memberEnterNotifications.append((
                            extension: content.notifyExt,
                            nickname: content.targets?.first?.nick ?? content.source?.nick
                        ))
                    } else if content.eventType == .exit {
                        if !isSelf { memberDelta -= 1 }
                    }
                }

            default:
                break
            }
        }

        for m in textPush { appendMessage(m) }
        for messageId in recalledMessageIds {
            removeMessage(sourceMessageId: messageId)
        }
        if memberDelta != 0 {
            onlineCount = max(0, onlineCount + memberDelta)
        }
        for notification in memberEnterNotifications {
            delegate?.partyRoomChat(
                self,
                didReceiveMemberEnter: notification.extension,
                fallbackNickname: notification.nickname
            )
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
    /// 1009 房间关闭/白名单限制；当前用户必须离开房间。
    func partyRoomChatDidCloseOrWhitelist(_ chat: PartyRoomChatManager)
    /// 1014 Party 鉴黄告警。time 非 0 时当前用户会被强制下麦。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveAuditWarning payload: [String: Any])
    /// 1019 系统通知只发给权限变更的本人，type/authType: 1=设房管、2=取消。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveSystemAuthUpdate payload: [String: Any])
    /// 1024 平台管理员状态变更，只同步当前登录用户的房内权限。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceivePlatformAdminChange payload: [String: Any])

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveSeatUpdate payload: [String: Any], raw: NIMMessage)
    /// 1012 全量重拉指令；`msgTimestampMs` 用于 `lastRoomTempSwitchAt` 精确判丢旧广播（对齐 1017 pattern）
    func partyRoomChatDidRequireSeatListReload(_ chat: PartyRoomChatManager, msgTimestampMs: Int64)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveProhibitMic payload: [String: Any], raw: NIMMessage)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveMediaUpdate payload: [String: Any], raw: NIMMessage)
    /// 1010 全房音乐总开关；关闭时 UI 必须立刻隐藏音乐入口。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveRoomMusicAvailability payload: [String: Any], raw: NIMMessage)
    /// 1011 切歌 / 1013 房间音乐开关。H5 以 currentMusicInfo 合并 payload。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveMusicUpdate payload: [String: Any], switchOnly: Bool, raw: NIMMessage)
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveGift payload: [String: Any], raw: NIMMessage)
    /// v23（2026-07-13）用户进场动画（attachType=80）：VIP/带座驾用户进入派对房时触发座驾 SVGA/MP4 全屏特效
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveEnterAnimation payload: [String: Any], raw: NIMMessage)
    /// 聊天室成员进入的 notificationExtension。无座驾用户在此驱动 H5 同款进场条。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveMemberEnter notificationExtension: String?, fallbackNickname: String?)
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

    /// 1050 幸运数字抽数公屏卡片（优先 ext.data，缺失时回退顶层 ext）。
    /// ext 期望 `{ userId, nickname, luckyNumber, giftId, ... }` —— 真机 preflight。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveLuckyNumberDraw payload: [String: Any], raw: NIMMessage)

    /// 1051 幸运数字中奖公屏广播（优先 ext.data，缺失时回退顶层 ext）。
    /// ext 期望 `{ userId, nickname, luckyNumber, winAmount, ... }` —— 真机 preflight。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveLuckyNumberWin payload: [String: Any], raw: NIMMessage)

    /// 1150-1156 Super Wheel 房内广播。attachType 与已解包 payload 分开传入。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveSuperWheelBroadcast attachType: Int, payload: [String: Any])

    /// 1052 幸运数字中奖个人弹窗（NIM CustomSystemNotification，仅中奖者收到）。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveLuckyNumberPersonalWin payload: [String: Any])

    /// 136 游戏中奖公屏通知（全服，session 通道主入口 + Party 通道兜底）。
    /// payload 期望 `{ avatar, nickname, winAmount, gameName, gameIcon, gameId, gameType, messageSkin }` —— 真机 preflight。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveGameWinGlobal payload: [String: Any], raw: NIMMessage)

    /// 138 PK 小奖 / Party 房游戏小奖（本房，字段同 136）。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceivePkSmallPrize payload: [String: Any], raw: NIMMessage)

    /// 140 活动中奖公屏广播（含 worldcup 世界杯活动卡）。
    /// payload 期望 `{ activityName, quantity, imageURL, joinCTA, avatar, cardType, ... }` —— 真机 preflight。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveWinnerBroadcast payload: [String: Any], raw: NIMMessage)

    /// 197 首礼时刻公屏与顶部飘屏。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveFirstGiftMoment payload: [String: Any], raw: NIMMessage)

    /// F 期房主管理批（2026-07-17）1025 roomBgUpdate / 1026 roomBgExpire 广播 —— 触发 PartyStore 重拉当前背景。
    /// - `expired = false`：1025 房主 setBgImages 后广播，观众端全量重拉 getRoomBgImage
    /// - `expired = true`：1026 背景过期，清空 currentRoomBackground → UI 层走 DEFAULT_BG fallback
    /// payload 字段名待真机 preflight（agent-recon-field-names-unverified rule），不依赖 payload 字段。
    func partyRoomChatDidRequireRoomBgReload(_ chat: PartyRoomChatManager, expired: Bool)

    /// F 里程碑（2026-07-17）表情面板 IM 分发：attachType `-10 emojiStatic` / `-11 emojiPlay` 分发到麦位队列。
    /// payload 已经过 `PartyEmojiPayload.from(payload:)` 严校验（缺 emojiId/playUrl/sendUserId 任一 drop）+
    /// self-echo skip 于 router 层完成 · 到 Store 时 payload 已保证 fresh 非 self。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveEmoji payload: PartyEmojiPayload, raw: NIMMessage)
}

/// NIMCustomAttachment 空桥接实现（发送 custom 消息必需 · attachType 与 data 已通过 `remoteExt` 传输，
/// 此 attachment 只做 protocol 合规占位 · encode 用最小 JSON 兜住 NIMSDK 序列化路径）。
///
/// 对齐 H5 侧 `sendCustomMsg` 语义 · 不用于消费端反序列化（消费走 remoteExt.attachType + remoteExt.data）。
final class PartyGenericCustomAttachment: NSObject, NIMCustomAttachment {
    let attachType: Int
    let data: [String: Any]

    init(attachType: Int, data: [String: Any]) {
        self.attachType = attachType
        self.data = data
        super.init()
    }

    func encode() -> String {
        // 最小合规 JSON · 真正的 payload 走 remoteExt · 此串仅 NIMSDK 内部序列化占位
        let obj: [String: Any] = ["attachType": attachType, "data": data]
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else {
            return "{\"attachType\":\(attachType)}"
        }
        return s
    }
}
