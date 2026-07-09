import Foundation
import NIMSDK
import os

/// 公屏一条消息（v8 扩展：对齐 H5 messageScroller.vue 结构化字段）。
///
/// **v7 遗留**：`isSystem` 保留兼容旧构造点；新代码使用 `messageType` discriminator。
/// **v8 新增**：`senderNickname/senderAvatar/userLevel/isHost/isVip/messageType` 供 Row 视觉分派
struct PublicChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isSystem: Bool
    // v8 结构化扩展（可选，向后兼容旧调用点）
    let senderNickname: String?
    let senderAvatar: String?
    let userLevel: Int?
    let isHost: Bool
    let isVip: Bool
    let messageType: PublicChatMessageType

    init(text: String,
         isSystem: Bool,
         senderNickname: String? = nil,
         senderAvatar: String? = nil,
         userLevel: Int? = nil,
         isHost: Bool = false,
         isVip: Bool = false,
         messageType: PublicChatMessageType = .regular) {
        self.text = text
        self.isSystem = isSystem
        self.senderNickname = senderNickname
        self.senderAvatar = senderAvatar
        self.userLevel = userLevel
        self.isHost = isHost
        self.isVip = isVip
        self.messageType = messageType
    }
}

/// 公屏消息独立 ObservableObject：与 LiveStore.networkDebugStore 同模式。
/// 让 `NIMChatroomManager.objectWillChange` 不因每条公屏消息发射，避免 LiveRoomView 整树重渲染
/// （review P1-3）。子 view `PublicScreenList` 直接订阅本 store，append 仅触发子 view 重算。
@MainActor
final class PublicChatMessagesStore: ObservableObject {
    @Published var messages: [PublicChatMessage] = []

    func append(_ msg: PublicChatMessage, limit: Int = 80) {
        messages.append(msg)
        if messages.count > limit { messages.removeFirst(messages.count - limit) }
    }
}

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
    /// v9 付费弹幕飘屏队列（H5 attachType 1050 触发；本轮 Fakes 骨架）
    let paidBulletQueue = PaidBulletQueue()
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
    /// 长连接态；当前无 view 订阅（grep 0 命中），保留为普通字段供内部状态机使用，不发 publish。
    private(set) var connected = false

    private var roomId = ""
    private var hasJoined = false   // 防止重复 enter 导致 NIMSDK delegate 重复 add → 公屏双播
    /// v19 主播自己的 IM 账号（用于过滤 memberEnter/Exit 和 fetchMembers 时排除主播本人）
    /// 对齐 H5 `userStore.mineInfo.yxAccid`（NIM SDK 里的 IM 账号 ID）
    private var anchorYxAccount: String? {
        NIMSDK.shared().loginManager.currentAccount()
    }
    /// v19 30s 观众数纠错定时器（对齐 H5 startAudienceSyncTimer live.js:155-162）
    private var audienceSyncTimer: Timer?

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
                let anchorId = self.anchorYxAccount
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
        roomId = ""
        hasJoined = false
        connected = false
    }

    func leave() {
        guard !roomId.isEmpty else { return }
        stopAudienceSyncTimer()   // v19 停 30s 定时器
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
        NIMSDK.shared().chatroomManager.exitChatroom(roomId, completion: nil)
        roomId = ""
        connected = false
        hasJoined = false
        presenceStore.onlineCount = 0
    }

    private func push(_ text: String, system: Bool) {
        messagesStore.append(PublicChatMessage(text: text, isSystem: system))
    }

    /// v12 payload 数值字段多态解析（后端 giftPrice/giftNum/cost 混发 Int/Int64/NSNumber/String）
    static func readInt64(_ raw: Any?) -> Int64? {
        if let v = raw as? Int64 { return v }
        if let v = raw as? Int { return Int64(v) }
        if let v = raw as? NSNumber { return v.int64Value }
        if let v = raw as? String, let n = Int64(v) { return n }
        return nil
    }

    /// 收公屏消息（main actor）。H M5：自定义消息分发统一走 `NIMService.dispatch`，
    /// 路由器按 protocol 短路决定消费；公屏文本副作用（-9 pkChatNotice）由本方法兼顾。
    fileprivate func processIncoming(_ batch: [NIMMessage]) {
        var items: [PublicChatMessage] = []
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
                let at = AttachType(raw: payload["attachType"])
                // H M5：路由统一走 NIMService.dispatch；PKNIMRouter / GiftMessageRouter / SystemMessageRouter
                // 等按 protocol 短路决定消费
                NIMService.shared.dispatch(at, payload: payload, context: .liveChatroom(roomId: roomId))

                // 公屏文本副作用：-9 pkChatNotice 的 content 直接展示
                if at == .pkChatNotice, let txt = payload["content"] as? String, !txt.isEmpty {
                    items.append(PublicChatMessage(text: txt, isSystem: true))
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
                    }
                    // v16 兜底：额外调 apiSendRank(rankType='now') 更新 Top2（不依赖 msg[] 解析成功）
                    Task { [weak self] in await self?.topRankStore.refresh() }

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
                    let userLevel = (data["userLevel"] as? Int) ?? (data["level"] as? Int)
                    let isVip = (data["isVip"] as? Bool) ?? false
                    let isHost = (data["isHost"] as? Bool) ?? false
                    let avatar = data["fromAvatar"] as? String

                    // v18 luckyGift 分派（对齐 H5 handleLiveGiftMessage L818）：
                    // data.totalReward 非零 → 幸运礼物中奖 messageType.luckyGift；否则普通 gift
                    let totalReward: Int64 = Self.readInt64(data["totalReward"]) ?? 0
                    let msgType: PublicChatMessageType = totalReward > 0
                        ? .luckyGift(giftIconUrl: giftIcon, count: count, totalReward: totalReward)
                        : .gift(giftIconUrl: giftIcon, giftName: giftName, count: count)

                    items.append(PublicChatMessage(
                        text: "",
                        isSystem: false,
                        senderNickname: nickname,
                        senderAvatar: avatar,
                        userLevel: userLevel,
                        isHost: isHost,
                        isVip: isVip,
                        messageType: msgType
                    ))
                    continue   // gift/luckyGift row 已 append，跳过下方默认分支

                // v18 活动中奖广播（attachType 140）
                case .activityWinnerPublic:
                    let nickname = (data["nickname"] as? String) ?? (data["fromNick"] as? String)
                    let activityName = (data["activityName"] as? String) ?? ""
                    let quantity = data["quantity"] as? Int
                    items.append(PublicChatMessage(
                        text: "",
                        isSystem: false,
                        senderNickname: nickname,
                        senderAvatar: data["avatar"] as? String,
                        userLevel: nil, isHost: false, isVip: false,
                        messageType: .winnerBroadcast(activityName: activityName, quantity: quantity)
                    ))
                    continue

                // v18 猜拳获胜（attachType 144 LIVA_GAME_NOTIFY）
                case .guessGameWinner:
                    let nickname = (data["nickname"] as? String) ?? (m.senderName)
                    let medalUrl = data["medalUrl"] as? String
                    let medalHours: Int? = (data["grantedHours"] as? Int)
                        ?? (data["medalHours"] as? Int)
                        ?? ((data["grantedHours"] as? NSNumber)?.intValue)
                    items.append(PublicChatMessage(
                        text: "",
                        isSystem: false,
                        senderNickname: nickname,
                        senderAvatar: nil,
                        userLevel: nil, isHost: false, isVip: false,
                        messageType: .rpsWin(medalUrl: medalUrl, medalHours: medalHours)
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
                    let nickname = (data["nickname"] as? String) ?? (data["fromNick"] as? String)
                    items.append(PublicChatMessage(
                        text: "",
                        isSystem: false,
                        senderNickname: nickname,
                        senderAvatar: nil,
                        userLevel: nil, isHost: false, isVip: false,
                        messageType: .wishlistEffect
                    ))
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
                    continue
                case .liveGiftRankUpdate, .rankUpdateOnly:
                    // Top2 已同步，不污染公屏
                    continue
                case .knownButUnhandled, .unknown:
                    // 已知但不实现（132/133/1004/1007/1014/...）+ unknown：仅静默 dispatch（router 已分发），不污染公屏
                    continue
                default:
                    // 礼物 / 合规等 H 阶段仍占位显示（H 礼物会话接 SVGA 后改）
                    if m.messageType == .custom {
                        items.append(PublicChatMessage(text: L10n.imSystemGiftPlaceholder, isSystem: true))
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
                let ext = (m.remoteExt as? [String: Any]) ?? [:]
                let nickname = (ext["fromNick"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? m.senderName
                let level = (ext["userLevel"] as? Int) ?? (ext["level"] as? Int)
                let isVip = (ext["isVip"] as? Bool) ?? false
                let isHost = (ext["isHost"] as? Bool) ?? false
                let avatar = ext["fromIcon"] as? String
                items.append(PublicChatMessage(
                    text: body,
                    isSystem: false,
                    senderNickname: nickname,
                    senderAvatar: avatar,
                    userLevel: level,
                    isHost: isHost,
                    isVip: isVip,
                    messageType: .regular
                ))
            case .custom:
                // 解码失败兜底
                items.append(PublicChatMessage(text: L10n.imSystemGiftPlaceholder, isSystem: true))
            case .notification:
                // v19 对齐 H5 handleNotificationMessage（live.js:927-1007）：
                // memberEnter/memberExit 时**过滤主播本人**（`account !== yxAccid`）后 delta +/-1
                if let obj = m.messageObject as? NIMNotificationObject,
                   let content = obj.content as? NIMChatroomNotificationContent {
                    // 通知目标账号：content.targets 数组第一个即触发事件的用户
                    let evtUserId: String = content.targets?.first?.userId ?? ""
                    let isAnchorSelf = !evtUserId.isEmpty && evtUserId == anchorYxAccount
                    if content.eventType == .enter {
                        if !isAnchorSelf { delta += 1 }   // v19 过滤主播本人
                        items.append(PublicChatMessage(text: L10n.userJoined, isSystem: true))
                    } else if content.eventType == .exit {
                        if !isAnchorSelf && presenceStore.onlineCount + delta > 0 {
                            delta -= 1   // v19 过滤主播 + 避免负数
                        }
                    }
                }
            default:
                break
            }
        }

        guard !items.isEmpty || delta != 0 else { return }
        // v11 修复：直接 append 完整 PublicChatMessage 保留结构化字段（senderNickname/userLevel/isVip 等），
        // 供 ChatRowRegular / ChatRowGift 分派子视图渲染。原 push(text,system) 只保留 2 字段会丢失所有徽章信息
        for it in items { messagesStore.append(it) }
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
