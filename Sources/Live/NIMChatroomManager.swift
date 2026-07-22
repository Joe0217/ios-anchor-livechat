import Foundation
import NIMSDK
import os

// PublicChatMessage / LiveRawPayload 结构定义已迁到 `Sources/Live/PublicScreen/LivePublicChatPayload.swift`（Phase 1 T8）

/// 在线人数独立 ObservableObject（review 202606260029 P1-1）：onlineCount 在 .enter/.exit 通知下
/// >1Hz 变化，原 @Published 挂在 NIMChatroomManager 上会触发 LiveRoomView 整树（CameraPreview /
/// RemoteVideoView / PKOverlayHost / publicScreen）重算。抽出独立 store 后仅 topBar 子 view
/// `OnlineCountText` 订阅，本体 LiveRoomView 不受影响。
///
/// **v19 语义修正**（对齐 H5 audienceNum，live.js:121-137）：
/// - `onlineCount` = **观众数**（已过滤主播本人）
/// - 初始值：进房后 NIM `fetchChatroomMembers` 查询成员列表 → filter(!= anchor) 计数
/// - 实时增减：`memberEnter/memberExit` 通知过滤主播事件后 +/-1
/// - 30s 定时轮询 fetchChatroomMembers 纠错
@MainActor
final class ChatPresenceStore: ObservableObject {
    @Published var onlineCount: Int = 0
}

/// 直播云信聊天室（独立模式）：进/退房 + 公屏文本 + 在线人数 + 路由分发。
///
/// H M5 简化（207 → ~130 行）：
/// - 删 IM 登录代码：登录由 `NIMOnlineKeeper.start` 统一处理（spec §3 / NIMService.login）
/// - 删 `weak pkRouter` 字段：M2 后所有 router 走 `NIMService.shared.registerRouter`，dispatch 通过协议
/// - `onRecvMessages` 改走 `NIMService.shared.dispatch(_:payload:context:.liveChatroom)`：router 链路按 protocol 短路
/// - `setupOnce` 改 forwarder（保留旧调用点兼容；实际工作转 `NIMService.setupOnce`）
///
/// 线程模型：整类 `@MainActor`，NIMSDK 子线程回调（`onRecvMessages` / `chatroom(_:connectionStateChanged:)`）
/// 标 `nonisolated`，函数体仅 `Task { @MainActor }` 切回主 actor。
@MainActor
final class NIMChatroomManager: NSObject, ObservableObject {
    /// 公屏消息独立 store；子 view 订阅，append 不触发 LiveRoomView 整树重渲染。
    let messagesStore = PublicChatMessagesStore()
    /// 在线人数独立 store（review 202606260029 P1-1）：>1Hz 变化字段抽出，子 view 内观测。
    let presenceStore = ChatPresenceStore()
    /// v8 送礼动画队列（对齐 H5 giftStore.giftQueue）；LiveRoomView 挂 GiftAnimationOverlay 订阅
    let giftAnimationQueue = GiftAnimationQueue()
    /// v8 用户进场飘屏队列（attachType 80 触发）
    let enterRoomQueue = EnterRoomFloatQueue()
    /// v8 钻石盲盒飘屏队列（attachType 1030-1033 触发）
    let diamondGiftQueue = DiamondGiftFloatQueue()
    /// 直播付费跑马灯：1050 与派对房幸运数字同号，只在本直播聊天室内解析。
    let paidBulletQueue = PaidBulletQueue(service: PaidBulletServiceReal())
    /// v10 钻石收益 store（顶部 Contribution 徽章数字，attachType 50 收礼后 refresh）
    let contributionStore = LiveContributionStore()
    /// v10 主播 Rank 位次 store（顶部 Rank 徽章数字，进房一次拉 receiveRankV3）
    let anchorRankStore = LiveAnchorRankStore()
    /// v10 心愿单 store（顶部小卡 + 半屏面板 + Top6）
    let wishlistStore = WishlistStore()
    /// v10 心愿达成飘屏队列（attachType 252/253 触发）
    let wishAchievedQueue = WishAchievedQueue()
    /// v11 顶部右侧 Top2 送礼头像 store（H 里程碑接入 IM attachType 50/56 分发；本轮 Fakes）
    let topRankStore = LiveTopRankStore()
    /// v25（2026-07-17）直播间任务面板进度 store —— IM attachType 50 触发 refreshOnGift 重拉
    /// （对齐 H5 handleLiveGiftMessage:live.js:937 收 50 号消息后调 updateLiveGiftTask；
    /// H5 outer gate `attachType===50` 已过滤 1/4 case，iOS 只挂 50 case，不挂 sendGift/liveCallGift）
    let liveGiftTaskStore = LiveGiftTaskStore(service: LiveGiftTaskServiceReal())
    /// 长连接态；当前无 view 订阅（grep 0 命中），保留为普通字段供内部状态机使用，不发 publish。
    private(set) var connected = false

    /// v24（B3 禁言状态机）：LiveRoomView 挂载后注入；notification `NIMChatroomEventType.addMute` /
    /// `.removeMute` / `.addMuteTemporarily` / `.removeMuteTemporarily` 事件命中"主播本人是 target"时
    /// 分派到 [`LiveStore.applyGag/applyUngag`](../LiveStore.swift)；weak 避免循环引用。
    weak var liveStore: LiveStore?
    /// 客态直播间设置本回调，收到 44/62 时退出远端 RTC 与聊天室；主态保持 nil，仍由 LiveStore 接管。
    var onRoomEnded: (() -> Void)?

    private var roomId = ""
    /// 付费跑马灯使用业务直播间 ID；不能误用云信聊天室 ID `roomId`。
    private var paidBulletContext: PaidBulletQueue.Context?
    private var hasJoined = false   // 防止重复 enter 导致 NIMSDK delegate 重复 add → 公屏双播
    /// 客态展示的观众数应排除房主，而不是排除当前观众自己；主态未设置时继续排除当前主播。
    private var audienceOwnerYxAccount: String?
    /// v19 主播自己的 IM 账号（用于过滤 memberEnter/Exit 和 fetchMembers 时排除主播本人）
    /// 对齐 H5 `userStore.mineInfo.yxAccid`（NIM SDK 里的 IM 账号 ID）
    private var anchorYxAccount: String? {
        NIMSDK.shared().loginManager.currentAccount()
    }

    private var audienceExcludedYxAccount: String? {
        audienceOwnerYxAccount ?? anchorYxAccount
    }
    /// v19 30s 观众数纠错定时器（对齐 H5 startAudienceSyncTimer live.js:155-162）
    private var audienceSyncTimer: Timer?
    private lazy var rpsWinQueue = RpsWinNotificationQueue { [weak self] message in
        self?.messagesStore.append(message)
    }

    /// 兜底：LiveRoomView.onDisappear 的 leave() 受 scenePhase + state 双守卫，logout / 路由切换等
    /// 非 .ended 路径下 view 销毁会跳过 leave；deinit 在此强制注销 NIMSDK delegate 防回调残留。
    deinit {
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
    }

    /// 进聊天室。**前置**：NIMSDK 已由 `NIMOnlineKeeper.start` 完成 login；本方法不再 login。
    /// H M5：account / token 参数删除，调用点 (LiveRoomView) 同步简化。
    func enter(roomId: String, nickname: String) {
        guard !hasJoined else {
            AppLogger.im.notice("[Chatroom] already joined room=\(self.roomId, privacy: .public), skip enter")
            return
        }
        hasJoined = true
        NIMService.setupOnce()
        self.roomId = roomId
        AppLogger.im.debug("🟣 [Chatroom] enter roomId=\(roomId, privacy: .public) nickname=\(nickname, privacy: .private)")
        NIMSDK.shared().chatManager.add(self)
        NIMSDK.shared().chatroomManager.add(self)

        guard NIMSDK.shared().loginManager.isLogined() else {
            AppLogger.im.error("🔴 [Chatroom] IM 未登录，无法进房；NIMOnlineKeeper.start 应先于 enter 调用")
            push(String(format: L10n.imSystemLoginFailedFormat, "0"), system: true)
            rollbackEnterFailure()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await NIMService.shared.enterChatroom(roomId: roomId, nickname: nickname)
                self.connected = true
                // v19 对齐 H5：不再用 chatroom.onlineUserCount（含主播 + 可能有僵尸连接），
                // 改为主动 fetchChatroomMembers 计数（过滤主播）+ 启动 30s 定时纠错
                self.presenceStore.onlineCount = 0  // 先置 0，等 fetch 结果
                self.syncAudienceNumFromMembers()
                self.startAudienceSyncTimer()
                self.push(L10n.imSystemJoined, system: true)
                AppLogger.im.info("🟢 [Chatroom] enter ok, audience count pending fetchChatroomMembers")
            } catch let err as NIMServiceError {
                if case let .chatroomEnterFailed(code, _) = err {
                    self.push(String(format: L10n.imSystemJoinFailedFormat, "\(code)"), system: true)
                }
                self.rollbackEnterFailure()
            } catch {
                self.push(String(format: L10n.imSystemJoinFailedFormat, "-1"), system: true)
                self.rollbackEnterFailure()
            }
        }
    }

    /// LiveRoomView 在进云信聊天室前注入付费跑马灯的直播业务上下文。
    func configurePaidBullet(roomId: Int, viewerUserId: Int, countryCode: String) {
        guard roomId > 0, viewerUserId > 0 else {
            paidBulletContext = nil
            return
        }
        paidBulletContext = PaidBulletQueue.Context(
            roomId: roomId,
            viewerUserId: viewerUserId,
            countryCode: countryCode
        )
    }

    /// 客态入房前注入房主云信账号。主态不调用，保持既有在线人数与通知计数语义。
    func configureAudience(ownerYxAccount: String?) {
        audienceOwnerYxAccount = ownerYxAccount?.isEmpty == false ? ownerYxAccount : nil
    }

    /// v19 拉取聊天室成员列表（对齐 H5 getAudienceList live.js:121-137）
    ///
    /// - NIM 用 `NIMChatroomFetchMemberTypeTemp` (临时成员=在线观众)，对标 H5 `type: 'regularReverse'`
    /// - limit 500（对齐 H5）
    /// - 过滤主播本人（`member.userId != anchorYxAccount`）
    /// - 更新 `presenceStore.onlineCount` = 观众数
    private func syncAudienceNumFromMembers() {
        guard !roomId.isEmpty else { return }
        let req = NIMChatroomMemberRequest()
        req.roomId = roomId
        req.type = .temp    // 临时成员 = 在线观众（对齐 H5 regularReverse 语义，NIMChatroomFetchMemberTypeTemp）
        req.limit = 500

        NIMSDK.shared().chatroomManager.fetchChatroomMembers(req) { [weak self] (error: Error?, members: [NIMChatroomMember]?) in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    AppLogger.im.warning("🟡 [Chatroom] fetchChatroomMembers error=\(error.localizedDescription, privacy: .public)")
                    return
                }
                let anchorId = self.audienceExcludedYxAccount
                let count = (members ?? []).filter { m in
                    // 过滤主播本人（对齐 H5 member.account !== yxAccid）
                    guard let uid = m.userId else { return false }
                    return uid != anchorId
                }.count
                self.presenceStore.onlineCount = count
                AppLogger.im.debug("👥 [Chatroom] audience count=\(count, privacy: .public) (filtered anchor)")
            }
        }
    }

    /// v19 启动 30s 定时轮询（对齐 H5 startAudienceSyncTimer 30 * 1000ms）
    private func startAudienceSyncTimer() {
        stopAudienceSyncTimer()
        audienceSyncTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncAudienceNumFromMembers()
            }
        }
    }

    private func stopAudienceSyncTimer() {
        audienceSyncTimer?.invalidate()
        audienceSyncTimer = nil
    }

    /// review 202606260029 P2-3：enter 失败两条路径（IM 未登录 / enterChatroom 抛错）必须回滚
    /// hasJoined + 已 add 的 NIMSDK delegate + roomId，否则用户重试 enter() 会被 `guard !hasJoined`
    /// 永久 skip，且残留 delegate 在 leave() 前持续接收同 roomId 消息。
    private func rollbackEnterFailure() {
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
        rpsWinQueue.reset()
        paidBulletQueue.clear()
        paidBulletContext = nil
        audienceOwnerYxAccount = nil
        onRoomEnded = nil
        messagesStore.clear()
        roomId = ""
        hasJoined = false
        connected = false
    }

    func leave() {
        guard !roomId.isEmpty else { return }
        stopAudienceSyncTimer()   // v19 停 30s 定时器
        rpsWinQueue.reset()
        paidBulletQueue.clear()
        paidBulletContext = nil
        audienceOwnerYxAccount = nil
        onRoomEnded = nil
        messagesStore.clear()
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
        NIMSDK.shared().chatroomManager.exitChatroom(roomId, completion: nil)
        roomId = ""
        connected = false
        hasJoined = false
        presenceStore.onlineCount = 0
    }

    /// 主播发送公屏文字（严格对齐 H5 sendMessage liveRoom.vue:291-319）。
    ///
    /// remoteExt 是 `[String: Any]` NSDictionary（`NIMMessage.h:174`），H5 `JSON.stringify` 是 JS SDK
    /// 类型要求；iOS SDK 直接接受 dict，同 Party [`PartyRoomChatManager.sendText`](../Party/Chat/PartyRoomChatManager.swift)。
    /// 本地立即 append 后不做 echo 过滤（NIMSDK 10.10.0 chatroom `.text` send 不回声给发送者，
    /// Party 已生产验证）。空/纯空白/未进房 → 静默 return；200 字上限（H5 maxlength）单点截断；
    /// send throw → catch log 不清空 inputText 让用户重试。
    /// 详见 `docs/plan/H-直播间发送公屏文字-spec-202607101100.md`。
    ///
    /// - Returns: `true` = caller 可清空 inputText（发送成功 or 输入本来就空/未进房，清空无副作用）；
    ///            `false` = NIM SDK send 抛错，caller 应保留 inputText 让用户重试（对齐 spec R5）
    @discardableResult
    func sendText(_ text: String, replyToNick: String? = nil, replyToUserId: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hasJoined else { return true }
        let capped = String(trimmed.prefix(200))

        // 本地立即回显（主播自身信息 SessionStore + AnchorInfoStore 三级回落已由 AnchorInfoStore 封装）
        let session = SessionStore.shared.user
        let anchor = AnchorInfoStore.shared
        let anchorUserId = anchor.userId
        let nickname = anchor.displayName.isEmpty ? session?.nickname : anchor.displayName
        let avatar = anchor.info?.icon ?? anchor.mine?.icon ?? session?.icon
        let userLevel = anchor.info?.level ?? anchor.mine?.level
        let selfYxAccid = anchorYxAccount ?? session?.yxAccid

        messagesStore.append(PublicChatMessage(
            text: capped,
            isSystem: false,
            senderNickname: nickname,
            senderAvatar: avatar,
            userLevel: userLevel,
            isHost: true,
            isVip: false,   // AnchorInfoStore/SessionStore 目前无 isVip 字段；观众端自身补齐
            messageType: .regular,
            // v24（B4）：本地 echo 也带 replyToNick 让公屏立即渲染"@ nick:" 格式
            senderYxAccId: selfYxAccid,
            senderUserId: anchorUserId.isEmpty ? nil : anchorUserId,
            replyToNick: replyToNick,
            isSelf: true
        ))

        // 云信广播（remoteExt = dict 直接赋值，禁止 JSONSerialization → String 转换）
        // v24（B4 · 对齐 H5 sendMessageToUser L332-340）：**只**放 `userId/chatBubble/replyNick` 三字段
        // `replyUserId` 是 H5 未使用的自造字段（rule im-payload-real-log-over-code-assumption），
        // 不进 payload；仅本地 pendingReplyTo 保留供 UI 用
        let msg = NIMMessage()
        msg.text = capped
        var remoteExt: [String: Any] = [
            "userId": anchorUserId as Any,
            "chatBubble": ""   // v22 Phase 3 / chatBubble 里程碑接入 mineInfo.chatBubble
        ]
        if let nick = replyToNick, !nick.isEmpty {
            remoteExt["replyNick"] = nick
        }
        msg.remoteExt = remoteExt
        let nimSession = NIMSession(roomId, type: .chatroom)
        do {
            try NIMSDK.shared().chatManager.send(msg, to: nimSession)
            AppLogger.im.info("🟢 [Chatroom] sendText ok len=\(capped.count, privacy: .public) reply=\(replyToNick ?? "-", privacy: .public)")
            return true
        } catch {
            AppLogger.im.error("🔴 [Chatroom] sendText failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// 向本直播间广播 PK 对手静音状态。
    ///
    /// 对齐 H5 `livePk.toggleOpponentMute`：自定义消息顶层字段必须包含
    /// `attachType=-8` 与 `muteOppositeAnchor=0/1`，供观众端立即切换对手音频。
    /// `data` 保持 JSON 字符串形态，兼容 H5 `sendCustomMsg` 的消息契约。
    @discardableResult
    func sendPKMuteBroadcast(muted: Bool) -> Bool {
        guard hasJoined else {
            AppLogger.im.warning("[Chatroom] PK mute broadcast skipped: not joined")
            return false
        }

        let muteFlag = muted ? 1 : 0
        let innerPayload: [String: Any] = [
            "muteOppositeAnchor": muteFlag,
            "attachType": -8,
        ]
        guard JSONSerialization.isValidJSONObject(innerPayload),
              let innerData = try? JSONSerialization.data(withJSONObject: innerPayload),
              let innerJSON = String(data: innerData, encoding: .utf8) else {
            AppLogger.im.error("[Chatroom] PK mute broadcast JSON encode failed")
            return false
        }

        let payload: [String: Any] = [
            "attachType": -8,
            "muteOppositeAnchor": muteFlag,
            "data": innerJSON,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            AppLogger.im.error("[Chatroom] PK mute broadcast payload encode failed")
            return false
        }

        let attachment = GenericCustomAttachment(rawDict: payload, rawJSON: json)
        let customObject = NIMCustomObject()
        customObject.attachment = attachment
        let message = NIMMessage()
        message.messageObject = customObject
        message.remoteExt = payload

        do {
            try NIMSDK.shared().chatManager.send(message, to: NIMSession(roomId, type: .chatroom))
            AppLogger.im.info("[Chatroom] PK mute broadcast sent muted=\(muted, privacy: .public)")
            return true
        } catch {
            AppLogger.im.error("[Chatroom] PK mute broadcast failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    private func push(_ text: String, system: Bool) {
        messagesStore.append(PublicChatMessage(text: text, isSystem: system))
    }

    /// v12 payload 数值字段多态解析（后端 giftPrice/giftNum/cost 混发 Int/Int64/NSNumber/String）
    static func readInt64(_ raw: Any?) -> Int64? {
        if raw is Bool { return nil }
        if let v = raw as? Int64 { return v }
        if let v = raw as? Int { return Int64(v) }
        if let v = raw as? NSNumber {
            let type = String(cString: v.objCType)
            guard type != "c", type != "B" else { return nil }
            return v.int64Value
        }
        if let v = raw as? String, let n = Int64(v) { return n }
        return nil
    }

    /// v22（2026-07-10）：Int 兼容读取（NSNumber → Int 直接 as? Int 在大数 / JSON parse 场景可能 nil）
    static func readInt(_ raw: Any?) -> Int? {
        readInt64(raw).map(Int.init)
    }

    /// userId / giftId 会在 Int、NSNumber 与 String 间混发，统一转为稳定 String 再参与匹配。
    static func readString(_ raw: Any?) -> String? {
        if let value = raw as? String, !value.isEmpty { return value }
        if let value = readInt64(raw) { return String(value) }
        return nil
    }

    /// v22：Bool 兼容读取（remoteExt 从 JSON parse 时布尔可能是 NSNumber(0/1)，as? Bool 可能 fail）
    static func readBool(_ raw: Any?) -> Bool {
        if let v = raw as? Bool { return v }
        if let v = raw as? NSNumber { return v.boolValue }
        if let v = raw as? Int { return v != 0 }
        if let v = raw as? String { return v == "1" || v.lowercased() == "true" }
        return false
    }

    /// 收公屏消息（main actor）。H M5：自定义消息分发统一走 `NIMService.dispatch`，
    /// 路由器按 protocol 短路决定消费；公屏文本副作用（-9 pkChatNotice）由本方法兼顾。
    fileprivate func processIncoming(_ batch: [NIMMessage]) {
        var items: [PublicChatMessage] = []
        var rpsWinItems: [PublicChatMessage] = []
        var delta = 0

        for m in batch {
            // 双过滤（对齐 PartyRoomChatManager.belongsToThisRoom）：仅本聊天室且本 roomId 的消息进流程。
            // 防多 chatManager delegate 共存时（如同时持有直播 + 派对房）串消息。
            guard let s = m.session,
                  s.sessionType == .chatroom,
                  s.sessionId == roomId else { continue }

            // v13 提取自定义消息 payload —— 4 层兜底 + log 埋点定位真机断链
            //
            // NIMSDK-iOS 的 remoteExt 类型不稳定：
            // - iOS SDK 通常 parse 为 [String: Any]
            // - 但某些通道 / SDK 版本会保留 JSON String（NIMSDK-node 一致行为）
            // - encode() 后可能是 JSON String 也可能是 base64 二进制
            //
            // v12 及以前只处理 Dict 分支，若 remoteExt 是 String 则整消息丢弃 → Top2 永不更新
            var payload: [String: Any]?
            var extractionPath: String = "none"
            if let ext = m.remoteExt as? [String: Any], ext["attachType"] != nil {
                payload = ext
                extractionPath = "remoteExt-dict"
            } else if let extStr = m.remoteExt as? String,
                      let d = extStr.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      parsed["attachType"] != nil {
                // v13 新增：remoteExt 是 JSON String → 二次 parse 兜底
                payload = parsed
                extractionPath = "remoteExt-string-parsed"
            } else if m.messageType == .custom,
                      let obj = m.messageObject as? NIMCustomObject {
                if let attach = obj.attachment as? GenericCustomAttachment {
                    payload = attach.rawDict
                    extractionPath = "attachment-rawDict"
                } else if let attach = obj.attachment {
                    let raw = attach.encode()
                    if let data = raw.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       parsed["attachType"] != nil {
                        payload = parsed
                        extractionPath = "attachment-encode-parsed"
                    }
                }
            }

            // v13 log：无 payload 消息类型 + remoteExt raw type 便于真机排查
            if payload == nil {
                let extType = String(describing: type(of: m.remoteExt))
                AppLogger.im.debug("🟠 [Chatroom] payload=nil messageType=\(String(describing: m.messageType), privacy: .public) remoteExtType=\(extType, privacy: .public)")
            }

            if let payload {
                // 直播付费跑马灯与派对房幸运数字共用 numeric attachType=1050。
                // 此处仅在 Live NIMChatroomManager 消费，PartyMessageRouter 的 1050 保持不变。
                if Self.readInt(payload["attachType"]) == 1050 {
                    if let context = paidBulletContext {
                        switch paidBulletQueue.receive(payload: payload, context: context) {
                        case .ignored:
                            break
                        case .enqueued(_, let firstHostEarnings):
                            if let earnings = firstHostEarnings {
                                AppToastCenter.shared.show(
                                    String(format: L10n.paidBulletEarningsToast, earnings)
                                )
                            }
                        }
                    } else {
                        AppLogger.im.debug("[Chatroom] paid bullet ignored: live context unavailable")
                    }
                    continue
                }
                let at = AttachType(raw: payload["attachType"])
                // H M5：路由统一走 NIMService.dispatch；PKNIMRouter / GiftMessageRouter / SystemMessageRouter
                // 等按 protocol 短路决定消费
                NIMService.shared.dispatch(at, payload: payload, context: .liveChatroom(roomId: roomId))

                // 主态的 44/62 由 SystemMessageRouter → LiveStore.forceEnd 处理；客态没有 LiveStore，
                // 必须在聊天室通道直接退房，语义对齐 H5 `@live-end="quitLiveRoom"`。
                if at == .forceEndLive || at == .banned {
                    onRoomEnded?()
                    continue
                }

                // 公屏文本副作用：-9 pkChatNotice 的 content 直接展示（对齐 H5 handelPkNotification）
                // v22 Phase 1（2026-07-10）：改用 .pkNotify 变体渲染暗红 D33901/30 气泡（H5 L519-521）
                // v22（2026-07-10 二轮）：content 字段 3 层兜底（payload/data/text）保 PK 结果消息可见
                if at == .pkChatNotice {
                    // 单独提前解 innerData（此处未走到 line 330 的 data 声明）
                    var innerData: [String: Any] = payload
                    if let dict = payload["data"] as? [String: Any] {
                        innerData = dict
                    } else if let s = payload["data"] as? String,
                              let d = s.data(using: .utf8),
                              let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        innerData = parsed
                    }
                    let txt = (payload["content"] as? String)
                        ?? (innerData["content"] as? String)
                        ?? (payload["text"] as? String)
                        ?? (innerData["text"] as? String)
                        ?? ""
                    AppLogger.im.debug("🥊 [Chatroom] pkChatNotice content='\(txt.prefix(80), privacy: .public)' payloadKeys=\(payload.keys.joined(separator: ","), privacy: .public) dataKeys=\(innerData.keys.joined(separator: ","), privacy: .public)")
                    if !txt.isEmpty {
                        items.append(PublicChatMessage(
                            text: txt,
                            isSystem: false,
                            senderNickname: nil, senderAvatar: nil,
                            userLevel: nil, isHost: false, isVip: false,
                            messageType: .pkNotify
                        ))
                    }
                    continue
                }
                // v11 礼物副作用桥接（H 期 GiftMessageRouter 落地前的直连方案）：
                // 收到 sendGift(1) / liveGiftRankUpdate(50) / rankUpdateOnly(56) 触发：
                //   ① contributionStore.refresh() 拉最新钻石收益（对齐 H5 handleLiveGiftMessage getCurrentLiveIncome）
                //   ② topRankStore.updateFromGiftMessage(...) 更新右上角 Top2 头像（对齐 H5 topRankList 事件驱动）
                // H 期 GiftMessageRouter 类接入后可整体迁移，本处删除；本会话仅打通 UI 反馈闭环
                // v12 修正（对齐 H5 payload.ext.data.msg[] 全量替换语义 + giftPrice*giftNum 真实累加）：
                //
                // - liveGiftRankUpdate(50) / rankUpdateOnly(56)：ext.data.msg[] 是完整排行榜 {userId,icon,cost}
                //   前端全量替换 Top2（非累加），50 附带 hotScore；不进公屏
                // - sendGift(1/'SEND_GIFT') / liveCallGift(4)：ext.data 含 giftPrice/giftNum/smallImg 单条明细
                //   ① contributionStore.apply(giftPrice*giftNum) 累加真实 delta
                //   ② 公屏构造 .gift(icon,name,count) 结构化消息供 ChatRowGift 渲染
                //
                // v13 payload 深度兼容 —— 3 层兜底：
                //   1. payload.data 是 Dict → 直接用
                //   2. payload.data 是 String（JSON 未 parse）→ 二次 parse 兜底
                //   3. 都无 → 用 payload 顶层（对齐 flat 格式 {attachType, msg[], ...}）
                var data: [String: Any] = payload
                if let dataDict = payload["data"] as? [String: Any] {
                    data = dataDict
                } else if let dataStr = payload["data"] as? String,
                          let d = dataStr.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    data = parsed
                    AppLogger.im.debug("🟡 [Chatroom] payload.data was String, parsed OK keys=\(parsed.keys.joined(separator: ","), privacy: .public)")
                }

                // v13 log：每条含 attachType 的消息统一打印一行（真机日志过滤 "[Chatroom] IM msg" 即可复盘）
                let atRaw = payload["attachType"].map { "\($0)" } ?? "nil"
                AppLogger.im.debug("🟢 [Chatroom] IM msg attachType=\(atRaw, privacy: .public) path=\(extractionPath, privacy: .public) dataKeys=\(data.keys.joined(separator: ","), privacy: .public)")

                switch at {
                case .liveGiftRankUpdate, .rankUpdateOnly:
                    // 2026-07-09 真机反悔（GiftEffect 引擎接入）：iOS 原假设"50=rank / 1=gift 明细"分两条消息，
                    // 实测后端 attachType=50 一条消息**同时**含 rank + gift 明细（giftPrice/giftId/giftName/
                    // giftIcon/smallImg/sendYxAccid/giftNum）。给 rank 分支也补 intake，让直播礼物特效展示。
                    // rankUpdateOnly(56) 无 giftId → decoder 内 guard giftId!=0 自然拒绝，安全无副作用。
                    if at == .liveGiftRankUpdate {
                        GiftEffectIntake.ingest(
                            scene: .live,
                            scopeId: roomId,
                            payload: data,
                            mineYxAccid: SessionStore.shared.user?.yxAccid ?? ""
                        )
                    }
                    // v13 msg[] 3 层兜底：Array 直用 / String parse 兜底 / list 字段兼容
                    var msgArray: [[String: Any]]?
                    if let arr = data["msg"] as? [[String: Any]] {
                        msgArray = arr
                    } else if let msgStr = data["msg"] as? String,
                              let d = msgStr.data(using: .utf8),
                              let parsed = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                        msgArray = parsed
                    } else if let list = data["list"] as? [[String: Any]] {
                        msgArray = list   // 后端可能下发 list 字段
                    }

                    if let msgArray {
                        AppLogger.im.debug("🎁 [Chatroom] rank update msgArray count=\(msgArray.count, privacy: .public) first=\(String(describing: msgArray.first).prefix(200), privacy: .public)")
                        topRankStore.setFromRankList(msgArray)
                    } else {
                        AppLogger.im.debug("🔴 [Chatroom] rank update msg[] not found data keys=\(data.keys.joined(separator: ","), privacy: .public) payload keys=\(payload.keys.joined(separator: ","), privacy: .public)")
                    }

                    // v14 对齐 H5 handleLiveGiftMessage（live.js:840）：收 attachType 50 后
                    // **调 getCurrentLiveIncome API 重拉后端已算好的最新值**，不做本地累加也不从 msg[] 猜 self.cost。
                    // rankUpdateOnly(56) 是纯排行榜变更，钻石数不变，无需重拉。
                    if at == .liveGiftRankUpdate {
                        Task { [weak self] in await self?.contributionStore.refresh() }
                        AppLogger.im.debug("💎 [Chatroom] attachType 50 → contribution refresh() (对齐 H5 handleLiveGiftMessage)")
                        // v25 (2026-07-17) 直播间任务面板同排触发：收 50 号消息 → 重拉 getLiveGiftTask 更新进度
                        // （对齐 H5 live.js:937 updateLiveGiftTask()；只挂 50 case，H5 outer gate 已过滤 1/4）
                        liveGiftTaskStore.refreshOnGift()
                        AppLogger.im.debug("🎯 [Chatroom] attachType 50 → liveGiftTaskStore.refreshOnGift() (对齐 H5 handleLiveGiftMessage)")

                        // H5 `handleLiveGiftMessage`：命中心愿礼物时推进进度并即时刷新已打开面板的 Top6。
                        // 线上 50 消息偶发漏发 `compelteGiftNum`，此时用本次 giftNum 增量兜底；
                        // `completeGiftNum` 是后端逐步修正拼写后的兼容字段。
                        if let giftId = Self.readString(data["giftId"]) {
                            let completed = Self.readInt(
                                data["compelteGiftNum"]
                                    ?? data["completedGiftNum"]
                                    ?? data["completeGiftNum"]
                            )
                            let receivedCount = Self.readInt(data["giftNum"] ?? data["num"]) ?? 1
                            _ = wishlistStore.applyGiftProgress(
                                giftId: giftId,
                                completedCount: completed,
                                receivedCount: receivedCount
                            )
                        }
                    }
                    // msg[] 是 H5 的权威完整榜单，直接采用并避免 API 旧响应覆盖它。
                    // 仅 payload 缺少 msg[] 时才用 apiSendRank 兜底。
                    if msgArray == nil {
                        Task { [weak self] in await self?.topRankStore.refresh() }
                    }

                    // v22 Phase 1（2026-07-10）：attachType 50 含 gift 明细，追加公屏 gift row
                    // （im-payload-real-log-over-code-assumption：后端真实通道，attachType 1 从未发过）
                    // rankUpdateOnly(56) 无 giftId → 跳过，避免误 append 空 row
                    if at == .liveGiftRankUpdate {
                        let giftIcon = (data["smallImg"] as? String) ?? (data["giftImg"] as? String) ?? (data["giftIcon"] as? String)
                        let giftName = (data["giftName"] as? String) ?? (data["name"] as? String) ?? ""
                        let giftNum: Int64 = Self.readInt64(data["giftNum"]) ?? 1
                        let hasGift = (giftIcon != nil) || !giftName.isEmpty
                        if hasGift {
                            let nickname: String? = (m.senderName?.isEmpty == false ? m.senderName : nil)
                                ?? (data["fromNick"] as? String)
                                ?? (data["nickname"] as? String)
                            let avatar = (data["fromAvatar"] as? String) ?? (data["icon"] as? String)
                            let userLevel = Self.readInt(data["userLevel"]) ?? Self.readInt(data["level"])
                            let isVip = Self.readBool(data["isVip"])
                            let isHost = Self.readBool(data["isHost"])
                            let totalReward: Int64 = Self.readInt64(data["totalReward"]) ?? 0
                            let msgType: PublicChatMessageType = totalReward > 0
                                ? .luckyGift(giftIconUrl: giftIcon, count: Int(giftNum), totalReward: totalReward)
                                : .gift(giftIconUrl: giftIcon, giftName: giftName, count: Int(giftNum))
                            // v24（B1 M3 finding）：gift-path 也 decode activeTycoon → 让 RowGift 徽章接线生效
                            let isActiveTycoon = Self.readBool(data["activeTycoon"])
                            items.append(PublicChatMessage(
                                text: "",
                                isSystem: false,
                                senderNickname: nickname,
                                senderAvatar: avatar,
                                userLevel: userLevel,
                                isHost: isHost,
                                isVip: isVip,
                                messageType: msgType,
                                isActiveTycoon: isActiveTycoon
                            ))
                        }
                    }

                case .sendGift, .liveCallGift:
                    // Task 9：接入跨场景礼物特效引擎（中央大动画 / MicroToast 二选一，与既有 contribution/topRank/公屏 side effect 解耦）
                    GiftEffectIntake.ingest(
                        scene: .live,
                        scopeId: roomId,
                        payload: data,
                        mineYxAccid: SessionStore.shared.user?.yxAccid ?? ""
                    )

                    // 单条送礼：累加钻石 + 公屏结构化 gift row（v18 支持 luckyGift 分派）
                    let giftPrice: Int64 = Self.readInt64(data["giftPrice"]) ?? 0
                    let giftNum: Int64 = Self.readInt64(data["giftNum"]) ?? 1
                    let diamonds = giftPrice * giftNum
                    if diamonds > 0 {
                        contributionStore.apply(diamonds: diamonds)
                    }
                    // v16 兜底：任何礼物消息都触发 Top2 refresh（对齐 H5 事件驱动，防 attachType 50 丢失）
                    Task { [weak self] in await self?.topRankStore.refresh() }
                    // 公屏 gift row（对齐 H5 messageScroller.vue L486-517 三分支 VIP/NewUser/Regular）
                    let giftIcon = (data["smallImg"] as? String) ?? (data["giftImg"] as? String)
                    let giftName = (data["giftName"] as? String) ?? (data["name"] as? String) ?? ""
                    let count = Int(giftNum)
                    let nickname: String? = {
                        if let s = m.senderName, !s.isEmpty { return s }
                        return data["fromNick"] as? String
                    }()
                    let userLevel = Self.readInt(data["userLevel"]) ?? Self.readInt(data["level"])
                    let isVip = Self.readBool(data["isVip"])
                    let isHost = Self.readBool(data["isHost"])
                    let avatar = data["fromAvatar"] as? String

                    // v18 luckyGift 分派（对齐 H5 handleLiveGiftMessage L818）：
                    // data.totalReward 非零 → 幸运礼物中奖 messageType.luckyGift；否则普通 gift
                    let totalReward: Int64 = Self.readInt64(data["totalReward"]) ?? 0
                    let msgType: PublicChatMessageType = totalReward > 0
                        ? .luckyGift(giftIconUrl: giftIcon, count: count, totalReward: totalReward)
                        : .gift(giftIconUrl: giftIcon, giftName: giftName, count: count)
                    // v24（B1 M3 finding）：gift-path 也 decode activeTycoon → 让 RowGift 徽章接线生效
                    let sendGiftIsActiveTycoon = Self.readBool(data["activeTycoon"])

                    items.append(PublicChatMessage(
                        text: "",
                        isSystem: false,
                        senderNickname: nickname,
                        senderAvatar: avatar,
                        userLevel: userLevel,
                        isHost: isHost,
                        isVip: isVip,
                        messageType: msgType,
                        isActiveTycoon: sendGiftIsActiveTycoon
                    ))
                    continue   // gift/luckyGift row 已 append，跳过下方默认分支

                // v22（2026-07-10）：活动中奖广播（attachType 140）主播端不入公屏
                // （用户反馈：Winner Got 消息不该出现在主播端公屏；H5 该消息主要面向用户端）
                case .activityWinnerPublic:
                    continue

                // v18 猜拳获胜（attachType 144 LIVA_GAME_NOTIFY）
                case .guessGameWinner:
                    let rpsPayload = RpsWinNotificationPayload(data: data, fallbackNickname: m.senderName)
                    rpsWinItems.append(PublicChatMessage(
                        text: "",
                        isSystem: false,
                        senderNickname: rpsPayload.nickname,
                        senderAvatar: nil,
                        userLevel: nil, isHost: false, isVip: false,
                        messageType: .rpsWin(medalUrl: rpsPayload.medalURL, medalHours: rpsPayload.medalHours)
                    ))
                    continue

                // v18 直播公告（attachType 195，roomId 一致性过滤 + 去重由消费方处理）
                case .liveAnnouncement:
                    let text = (data["text"] as? String) ?? (payload["content"] as? String) ?? ""
                    guard !text.isEmpty else { continue }
                    // roomId 一致性过滤
                    if let annRoomId = Self.readInt64(data["roomId"]), annRoomId > 0,
                       let currentRoomId = Int64(roomId), annRoomId != currentRoomId {
                        continue
                    }
                    // 去重：若最新一条公屏已是相同 announcement，跳过
                    if case .announcement = items.last?.messageType,
                       items.last?.text == text {
                        continue
                    }
                    items.append(PublicChatMessage(
                        text: text,
                        isSystem: false,
                        senderNickname: nil, senderAvatar: nil,
                        userLevel: nil, isHost: false, isVip: false,
                        messageType: .announcement
                    ))
                    continue

                // v18 心愿单 TOP1 登顶（attachType 251）
                case .wishlistTop1:
                    let nickname = (data["nickname"] as? String)
                        ?? (data["fromNick"] as? String)
                        ?? m.senderName
                    let userId = Self.readString(data["userId"] ?? data["sendUserId"])
                    items.append(PublicChatMessage(
                        text: "",
                        isSystem: false,
                        senderNickname: nickname,
                        senderAvatar: (data["avatar"] as? String) ?? (data["fromAvatar"] as? String),
                        userLevel: nil, isHost: false, isVip: false,
                        messageType: .wishlistEffect,
                        senderYxAccId: (data["sendYxAccid"] as? String) ?? (data["senderYxAccid"] as? String),
                        senderUserId: userId
                    ))
                    continue

                // H5 不为 250 写公屏；252/253 只更新本地进度并重播顶部横幅。
                case .wishlistFirst:
                    continue
                case .wishlistPoolDone, .wishlistGiftDone:
                    _ = wishlistStore.markCompleted(
                        wholePool: at == .wishlistPoolDone,
                        giftId: Self.readString(data["giftId"]),
                        hasGiftId: data["giftId"].map { !($0 is NSNull) } ?? false
                    )
                    // H5 每次 252/253 都重播横幅；消息可能先于 wishlist 接口回包到达，
                    // 因此不能以本地 item 是否命中作为展示条件。
                    wishAchievedQueue.show()
                    continue

                // v18 钻石盲盒 4 subType（1030 发包 / 1032 瓜分 / 1033 结算 or 过期）
                case .diamondBoxWarm:
                    let sender = (data["senderName"] as? String) ?? (data["senderNickName"] as? String) ?? ""
                    let tier = data["tierName"] as? String
                    let total = Self.readInt64(data["totalDiamonds"]) ?? 0
                    items.append(PublicChatMessage(
                        text: "", isSystem: false,
                        senderNickname: sender, senderAvatar: nil,
                        userLevel: nil, isHost: false, isVip: false,
                        messageType: .diamondGift(subType: .send(senderName: sender, tierName: tier, totalDiamonds: total))
                    ))
                    continue
                case .diamondBoxClaim:
                    let user = (data["userName"] as? String) ?? ""
                    let d = Self.readInt64(data["diamonds"]) ?? 0
                    items.append(PublicChatMessage(
                        text: "", isSystem: false,
                        senderNickname: user, senderAvatar: nil,
                        userLevel: nil, isHost: false, isVip: false,
                        messageType: .diamondGift(subType: .claim(userName: user, diamonds: d))
                    ))
                    continue
                case .diamondBoxSettle:
                    // 判断 settled variant：有 topShareDiamonds → settled；有 refundDiamonds → expired
                    if let topUser = data["topShareUserName"] as? String, !topUser.isEmpty {
                        let d = Self.readInt64(data["topShareDiamonds"]) ?? 0
                        items.append(PublicChatMessage(
                            text: "", isSystem: false,
                            senderNickname: topUser, senderAvatar: nil,
                            userLevel: nil, isHost: false, isVip: false,
                            messageType: .diamondGift(subType: .settled(topUserName: topUser, topDiamonds: d))
                        ))
                    } else if let sender = data["senderName"] as? String, !sender.isEmpty {
                        let refund = Self.readInt64(data["refundDiamonds"]) ?? 0
                        items.append(PublicChatMessage(
                            text: "", isSystem: false,
                            senderNickname: sender, senderAvatar: nil,
                            userLevel: nil, isHost: false, isVip: false,
                            messageType: .diamondGift(subType: .expired(senderName: sender, refundDiamonds: refund))
                        ))
                    }
                    continue

                default: break
                }

                switch at {
                case .pkInvite, .pkScoreUpdate, .pkInviteAck, .pkStatusBundle, .pkMuteBroadcast:
                    // v22（2026-07-11）：PK 开始 / 结果公屏消息改由 PKStore 本地 append
                    // （对齐 H5 sendLiveRoomNotice + 本地 unshift 语义，避免依赖聊天室广播 echo）
                    continue
                case .liveGiftRankUpdate, .rankUpdateOnly:
                    // Top2 已同步，不污染公屏
                    continue
                case .enterRoomAnimation, .privateCallEnterAnimation:
                    // v22（2026-07-10）：attachType 80 座驾进场 / 83 私 call 进场 → 公屏 .enterRoom
                    // 对齐 H5 stores/modules/virtualProps.js playEnterAnimation payload 结构：
                    //   data.username / data.icon / data.userLevel / data.isVip / data.activeTycoon
                    //   data.list: Array<String> —— 每项是 JSON 字符串，parse 后 {itemImg, itemType, ...}
                    // inLiveChannel === 1 → officialBoostEnter；其他 → enterRoom
                    let inLiveChannel = Self.readInt(data["inLiveChannel"]) ?? Self.readInt(payload["inLiveChannel"]) ?? 0
                    let nickname: String? = (data["username"] as? String)
                        ?? (m.senderName?.isEmpty == false ? m.senderName : nil)
                        ?? (data["fromNick"] as? String)
                        ?? (data["nickname"] as? String)
                        ?? (payload["fromNick"] as? String)
                    let avatar = (data["icon"] as? String)
                        ?? (data["fromAvatar"] as? String)
                        ?? (data["avatar"] as? String)
                    // 座驾图 + 内嵌 userLevel/isVip：先解 data.list[0] JSON
                    var vehicleItemImg: String? = nil
                    var listInnerUserLevel: Int? = nil
                    var listInnerIsVip: Bool? = nil
                    if let list = data["list"] as? [String], let first = list.first,
                       let d = first.data(using: .utf8),
                       let itemDict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        vehicleItemImg = itemDict["itemImg"] as? String
                        listInnerUserLevel = Self.readInt(itemDict["userLevel"]) ?? Self.readInt(itemDict["level"])
                        listInnerIsVip = Self.readBool(itemDict["isVip"])
                    }
                    if vehicleItemImg == nil {
                        vehicleItemImg = (data["itemSmallImg"] as? String) ?? (data["vehicleImg"] as? String)
                    }
                    // userLevel 多路兜底（data / payload 顶层 / list 内嵌 / ext key 通用）
                    let userLevel = Self.readInt(data["userLevel"])
                        ?? Self.readInt(data["level"])
                        ?? Self.readInt(payload["userLevel"])
                        ?? Self.readInt(payload["level"])
                        ?? listInnerUserLevel
                    let isVip = Self.readBool(data["isVip"]) || Self.readBool(payload["isVip"]) || (listInnerIsVip ?? false)
                    // v24（B1 活跃大R）：activeTycoon 提前解析，供公屏 Row 徽章 + EnterRoomFloat 金色底两路共用
                    // TODO: [im-payload-real-log-over-code-assumption] 真机首次收到 attachType=80 通过 🚗 log
                    //   校对 activeTycoon / senderYxAccid 字段真实位置；当前基于 H5 蓝本 + GiftEffect 同款 fallback
                    let isActiveTycoon = Self.readBool(data["activeTycoon"])
                        || Self.readBool(payload["activeTycoon"])
                    AppLogger.im.debug("🚗 [Chatroom] attachType=\(String(describing: at), privacy: .public) userLevel=\(userLevel ?? -1, privacy: .public) isVip=\(isVip, privacy: .public) activeTycoon=\(isActiveTycoon, privacy: .public) vehicle=\(vehicleItemImg ?? "nil", privacy: .public) dataKeys=\(data.keys.joined(separator: ","), privacy: .public) payloadKeys=\(payload.keys.joined(separator: ","), privacy: .public)")
                    items.append(PublicChatMessage(
                        text: "",
                        isSystem: false,
                        senderNickname: nickname,
                        senderAvatar: avatar,
                        userLevel: userLevel,
                        isHost: false,
                        isVip: isVip,
                        messageType: inLiveChannel == 1 ? .officialBoostEnter : .enterRoom,
                        itemSmallImg: vehicleItemImg,
                        isActiveTycoon: isActiveTycoon
                    ))
                    // v23（2026-07-11）用户进场双链路（对齐 H5 userEntranceFloat + giftQueue 分离）：
                    //   链路 1: EnterRoomFloatQueue —— 公屏上方胶囊 banner（无 vehicle 也播）
                    //   链路 2: EnterEffectCenter —— 全屏 SVGA/MP4 座驾特效（vehicleItemImg 是 svga/mp4 才播）
                    //     独立于 GiftEffect 并行播放（用户明示 "不同的特效队列分开，允许同时播放"）
                    // - 主播自己进场 filter drop（H5 payload 里的 sender 永远是观众/客人，防御性过滤）
                    // - activeTycoon 大 R 用金色底图（H5 live_userRR_bg.webp）
                    // - EnterEffectCenter scopeId 与 enterEffectScene modifier 同源用 self.roomId
                    let mineYxAccid = SessionStore.shared.user?.yxAccid ?? ""
                    let senderAccid = (data["senderYxAccid"] as? String)
                        ?? (data["sendYxAccid"] as? String)
                        ?? (payload["senderYxAccid"] as? String)
                        ?? (payload["sendYxAccid"] as? String)
                        ?? ""
                    let isSelfSent = !senderAccid.isEmpty
                        && !mineYxAccid.isEmpty
                        && senderAccid == mineYxAccid
                    if !isSelfSent {
                        // 链路 1: EnterRoomFloat banner（无 vehicle 也播）
                        enterRoomQueue.addToQueue(EnterRoomFloatQueue.Item(
                            nickname: nickname ?? "",
                            avatarUrl: avatar,
                            userLevel: userLevel ?? 0,
                            isVip: isVip,
                            isActiveTycoon: isActiveTycoon
                        ))
                        // 链路 2: EnterEffectCenter 全屏 SVGA/MP4（后缀白名单 + 有 URL 才播）
                        if let vehicleUrl = vehicleItemImg,
                           let parsed = URL(string: vehicleUrl) {
                            let ext = parsed.pathExtension.lowercased()
                            if ext == "svga" || ext == "mp4" {
                                let item = GiftEffectItem(
                                    sceneKey: GiftEffectSceneKey(scene: .live, scopeId: self.roomId),
                                    senderYxAccid: senderAccid,
                                    senderNickname: nickname ?? "",
                                    senderAvatarUrl: avatar,
                                    giftId: 0,
                                    giftName: "vehicle",
                                    giftCount: 1,
                                    giftPrice: 0,
                                    animationUrl: vehicleUrl,
                                    staticImgUrl: nil,
                                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                                    isSelfSent: false   // 已前置 filter
                                )
                                EnterEffectCenter.shared.enqueue(item)
                            }
                        }
                    }
                    continue
                case .activeTycoonEnter:
                    // v24（B1 · 对齐 H5 §9.6 handleActiveTycoonEnterToast · live.js:713–739）：
                    // 活跃大 R 进房触发顶部 Toast；同 userId 当天去重。
                    // **isHost + isStreaming 门禁在 iOS 主播端 App 里等价于 `hasJoined`**：
                    //   NIMChatroomManager 只在主播自己开播成功后 enter 聊天室；只要 hasJoined=true
                    //   即"是本主播房间 + 开播中"（对齐 H5 铁律"仅主态主播开播中弹"）
                    // TODO: [im-payload-real-log-over-code-assumption] `data.userId` vs `data.sendUserId` 真机 log 后 finalize
                    // v24 B4 兜底：Bool 桥接排除（ios-decode-userid-compat rule）
                    let tycoonUserIdStr: String = {
                        if let s = data["userId"] as? String, !s.isEmpty { return s }
                        if let n = data["userId"] as? NSNumber {
                            let c = String(cString: n.objCType)
                            if c != "c" && c != "B" { return n.stringValue }
                        }
                        if let s = data["sendUserId"] as? String, !s.isEmpty { return s }
                        if let n = data["sendUserId"] as? NSNumber {
                            let c = String(cString: n.objCType)
                            if c != "c" && c != "B" { return n.stringValue }
                        }
                        return ""
                    }()
                    AppLogger.im.debug("💎 [Chatroom] activeTycoonEnter userId=\(tycoonUserIdStr, privacy: .private) hasJoined=\(self.hasJoined, privacy: .public) dataKeys=\(data.keys.joined(separator: ","), privacy: .public)")
                    ActiveTycoonToastCenter.shared.trigger(
                        userId: tycoonUserIdStr,
                        isHost: self.hasJoined,
                        isStreaming: self.hasJoined
                    )
                    // v24（B1 M2 finding · 对齐 H5 §9.6 showActiveTycoonEntrance live.js:978-987）：
                    // Big-R 用户即使不带座驾进房，也需要金色胶囊 banner —— 追加 EnterRoomFloatQueue enqueue
                    // 用 IM payload 里的 nickname/avatar/userLevel/isVip（尽量兼容多字段名）
                    let tycoonNickname: String? = (data["nickname"] as? String)
                        ?? (data["username"] as? String)
                        ?? (data["fromNick"] as? String)
                    let tycoonAvatar: String? = (data["icon"] as? String)
                        ?? (data["avatar"] as? String)
                        ?? (data["fromAvatar"] as? String)
                    let tycoonLevel = Self.readInt(data["userLevel"]) ?? Self.readInt(data["level"]) ?? 0
                    let tycoonIsVip = Self.readBool(data["isVip"])
                    if self.hasJoined, let nickname = tycoonNickname, !nickname.isEmpty {
                        enterRoomQueue.addToQueue(EnterRoomFloatQueue.Item(
                            nickname: nickname,
                            avatarUrl: tycoonAvatar,
                            userLevel: tycoonLevel,
                            isVip: tycoonIsVip,
                            isActiveTycoon: true
                        ))
                    }
                    continue
                case .knownButUnhandled, .unknown:
                    // 已知但不实现（132/133/1004/1007/1014/...）+ unknown：仅静默 dispatch（router 已分发），不污染公屏
                    continue
                default:
                    // v22（2026-07-10）：不再 append "[Gift/Custom message]" 占位污染公屏
                    // 未识别的 attachType 走 router 已 dispatch 静默处理，公屏侧不展示
                    if m.messageType == .custom {
                        AppLogger.im.debug("🔕 [Chatroom] unhandled custom attachType=\(String(describing: at), privacy: .public) —— skip public chat")
                        continue
                    }
                }
            }

            // 文本 / notification（无 payload）
            switch m.messageType {
            case .text:
                let body = m.text ?? ""
                // v11 结构化填充：让 ChatRowRegular 能渲染等级徽章 + 昵称青绿色 + Host/VIP 标
                // remoteExt 常见字段（H5 蓝本 messageScroller.vue setLevelImg 依赖）：
                //   userLevel: Int / level: Int / isVip: Bool / isHost: Bool / fromNick / fromIcon
                // v22（2026-07-11）：H5 转盘/猜拳等特殊消息也走 NIM `.text`（非 custom），通过
                // ext.type 字段区分（H5 messageScroller L347 注释：wheelRes/rpsWinNotify/pk_notification/enterRoom）
                //   type='wheelRes' → RowWheelRes（text=奖品名）
                //   type='enterRoom' → RowEnterRoom（text 常为空 + ext 有 itemSmallImg）
                //   其他/无 type → RowRegularText（普通用户文本）
                var ext = (m.remoteExt as? [String: Any]) ?? [:]
                if ext.isEmpty, let s = m.remoteExt as? String,
                   let d = s.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    ext = parsed
                }
                let extType = ext["type"] as? String ?? ""
                var nickname = (ext["fromNick"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (ext["fromNickName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? m.senderName
                let level = Self.readInt(ext["userLevel"]) ?? Self.readInt(ext["level"])
                let isVip = Self.readBool(ext["isVip"])
                let isHost = Self.readBool(ext["isHost"])
                let avatar = (ext["fromIcon"] as? String) ?? (ext["icon"] as? String)

                // 按 ext.type 分派 messageType
                let msgType: PublicChatMessageType
                switch extType {
                case "wheelRes":
                    msgType = .wheelRes
                case "rpsWinNotify":
                    let rpsPayload = RpsWinNotificationPayload(data: ext, fallbackNickname: nickname)
                    nickname = rpsPayload.nickname
                    msgType = .rpsWin(medalUrl: rpsPayload.medalURL, medalHours: rpsPayload.medalHours)
                case "pk_notification":
                    msgType = .pkNotify
                case "enterRoom":
                    let inLive = Self.readInt(ext["inLiveChannel"]) ?? 0
                    msgType = inLive == 1 ? .officialBoostEnter : .enterRoom
                default:
                    msgType = .regular
                }

                let itemSmallImg = (ext["itemSmallImg"] as? String) ?? (ext["vehicleImg"] as? String)
                // v24（B1）：activeTycoon 字段透传（对齐 H5 messageScroller.vue L373 徽章 gating）
                let isActiveTycoon = Self.readBool(ext["activeTycoon"])
                // v24（B4 · 对齐 H5 §9.12.5 live.js:244 ext.replyNick decode + ios-decode-userid-compat.md）
                let replyToNick = (ext["replyNick"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let senderUserIdStr: String? = {
                    if let s = ext["userId"] as? String, !s.isEmpty { return s }
                    if let n = ext["userId"] as? NSNumber {
                        let c = String(cString: n.objCType)
                        if c != "c" && c != "B" { return n.stringValue }
                    }
                    return nil
                }()
                let senderYxAccId = m.from
                let mineYxAccid = anchorYxAccount ?? SessionStore.shared.user?.yxAccid
                let isSelf = !(senderYxAccId ?? "").isEmpty
                    && senderYxAccId == mineYxAccid
                AppLogger.im.debug("💬 [Chatroom] text ext.type='\(extType, privacy: .public)' → msgType=\(String(describing: msgType), privacy: .public) reply=\(replyToNick ?? "-", privacy: .public) isSelf=\(isSelf, privacy: .public) body='\(body.prefix(40), privacy: .public)'")
                items.append(PublicChatMessage(
                    text: body,
                    isSystem: false,
                    senderNickname: nickname,
                    senderAvatar: avatar,
                    userLevel: level,
                    isHost: isHost,
                    isVip: isVip,
                    messageType: msgType,
                    itemSmallImg: itemSmallImg,
                    isActiveTycoon: isActiveTycoon,
                    senderYxAccId: senderYxAccId,
                    senderUserId: senderUserIdStr,
                    replyToNick: replyToNick,
                    isSelf: isSelf
                ))
            case .custom:
                // v22（2026-07-10）：解码失败静默 log，不再 append "[Gift/Custom message]" 污染公屏
                AppLogger.im.debug("🔕 [Chatroom] custom NIMMessage no attachType extracted —— skip public chat")
            case .notification:
                // v19 对齐 H5 handleNotificationMessage（live.js:927-1007）：
                // memberEnter/memberExit 时**过滤主播本人**（`account !== yxAccid`）后 delta +/-1
                //
                // v22（2026-07-10）：notification 分支**只**做 delta 计数，不再 append enterRoom row
                // （memberEnter.ext 常无 itemSmallImg 字段 → 座驾图拿不到；改由 attachType 80
                // enterRoomAnimation 分支统一 append，那里携带完整 vehicle 数据）
                if let obj = m.messageObject as? NIMNotificationObject,
                   let content = obj.content as? NIMChatroomNotificationContent {
                    let evtUserId: String = content.targets?.first?.userId ?? ""
                    let isAnchorSelf = !evtUserId.isEmpty && evtUserId == audienceExcludedYxAccount
                    if content.eventType == .enter {
                        if !isAnchorSelf { delta += 1 }
                    } else if content.eventType == .exit {
                        if !isAnchorSelf && presenceStore.onlineCount + delta > 0 {
                            delta -= 1
                        }
                    }
                    // v24（B3 · 对齐 H5 §9.16 handleNotificationMessage gagMember/ungagMember）：
                    // NIMSDK 直接暴露 typed enum，比 H5 JSON attach.type 更结构化
                    // - addMute(305) / addMuteTemporarily(314) → 被禁言（gagMember）
                    // - removeMute(306) / removeMuteTemporarily(315) → 被解禁（ungagMember）
                    // 门禁：仅当"主播本人是 target"才处理（对齐 H5 attach.from === yxAccid 守卫）
                    // targets?.contains(where:) 支持多 target 场景（NIM 单次通知可能包含多人）
                    let isMuteEvent = content.eventType == .addMute
                                   || content.eventType == .addMuteTemporarily
                    let isUnmuteEvent = content.eventType == .removeMute
                                     || content.eventType == .removeMuteTemporarily
                    if isMuteEvent || isUnmuteEvent {
                        let mineInTargets = content.targets?.contains(where: { $0.userId == anchorYxAccount }) ?? false
                        AppLogger.im.debug("🔇 [Chatroom] mute event=\(String(describing: content.eventType), privacy: .public) mineInTargets=\(mineInTargets, privacy: .public) targetsCount=\(content.targets?.count ?? 0, privacy: .public)")
                        if mineInTargets {
                            if isMuteEvent {
                                liveStore?.applyGag()
                            } else {
                                liveStore?.applyUngag()
                            }
                        }
                    }
                }
            default:
                break
            }
        }

        guard !items.isEmpty || !rpsWinItems.isEmpty || delta != 0 else { return }
        // v11 修复：直接 append 完整 PublicChatMessage 保留结构化字段（senderNickname/userLevel/isVip 等），
        // 供 ChatRowRegular / ChatRowGift 分派子视图渲染。原 push(text,system) 只保留 2 字段会丢失所有徽章信息
        for it in items { messagesStore.append(it) }
        // 对齐 H5 `enqueueRpsWinNotify`：attachType=144 首条立即，其余 10 秒间隔，待发最多 20 条。
        for item in rpsWinItems { rpsWinQueue.enqueue(item) }
        if delta != 0 {
            presenceStore.onlineCount = max(0, presenceStore.onlineCount + delta)
        }
    }
}

// MARK: - 收消息 / 连接状态（NIMSDK 子线程回调）

extension NIMChatroomManager: NIMChatManagerDelegate {
    nonisolated func onRecvMessages(_ messages: [NIMMessage]) {
        Task { @MainActor [weak self] in
            self?.processIncoming(messages)
        }
    }
}

extension NIMChatroomManager: NIMChatroomManagerDelegate {
    nonisolated func chatroom(_ roomId: String, connectionStateChanged state: NIMChatroomConnectionState) {
        // M5：长连接 / 重连状态由 NIMService.connectionState 全局承担；本回调暂留占位
    }
}
