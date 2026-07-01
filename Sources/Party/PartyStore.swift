import Combine
import Foundation
import NIMSDK

/// 派对房全局房间状态（spec §1.4.2 + §1.4.5 + §1.4.6）。
///
/// 对齐安卓 `PartyRoomDataManager`，但**职责仅限房间状态**——拆分三对象避免巨石（spec §1.0.2）：
/// - `PartyStore`：房间信息 / 麦位 / 在线人数 / 送礼事件 / 进出房编排
/// - `PartyRTCEngine`：声网封装
/// - `PartyRoomChatManager`：NIM 公屏 + attachType 分发
///
/// 单例语义（一次只能在一个房）；多次进退房会先 `forceLeaveRoom(.userRequest)` 清残留。
/// **禁止字段**：`weak var liveStore` / `weak var callStore`（spec §1.0.3 验证；E 期完全不与 B/C/D 耦合）。
@MainActor
final class PartyStore: ObservableObject {
    static let shared = PartyStore()

    // MARK: - 状态字段

    @Published private(set) var roomInfo: PartyRoomInfo?
    @Published private(set) var seatList: [PartyRoomSeat] = []
    @Published private(set) var onlineUserCount: Int = 0
    @Published private(set) var isJoinedChannel: Bool = false   // RTC joined
    @Published private(set) var imAlive: Bool = false           // NIM chatroom enterOK
    @Published private(set) var lastGiftEvent: PartyGiftEvent?
    @Published private(set) var roomState: PartyRoomState = .idle {
        didSet {
            guard oldValue != roomState else { return }
            // IM 场景闸门 wiring：进入/退出 .joined 同步 IMSceneGate（派对房 sysMsg 不走 sysMsg
            // 通道，但 .party active 表示用户在派对房中——其他场景的 sysMsg 应根据 .party 状态过滤）。
            // 详见 Sources/Live/NIM/IMSceneFilter.swift §设计核心。
            let wasJoined = (oldValue == .joined)
            let isJoined = (roomState == .joined)
            if !wasJoined && isJoined {
                IMSceneGate.shared.enter(.party)
            } else if wasJoined && !isJoined {
                IMSceneGate.shared.exit(.party)
            }
        }
    }
    @Published private(set) var pendingVideoSeatInvite: PartyVideoSeatInvite?
    @Published private(set) var lastInviteResult: PartyVideoSeatInviteResult?
    @Published private(set) var lastError: PartyRoomError?

    // MARK: - 子模块

    let rtc = PartyRTCEngine()
    let chat = PartyRoomChatManager()
    /// H M3：派对房 NIM 消息路由（dispatchCustom + 业务 handler）从 chat 拆出。
    /// PartyStore 实现 PartyRoomChatManagerDelegate 的回调由 chatRouter 转发，chat 只管 IM 通道。
    let chatRouter = PartyMessageRouter()

    /// 视频位本地采集（仅在视频位上麦时实例化；下麦/退房 tearDown + 置 nil 释放相机+美颜）。
    /// CameraManager 已封装 FUBeautyRenderer + Passthrough 降级，sink 收到的就是美颜后的 BGRA。
    /// 与直播 LiveRoomView 持有的 CameraManager 是**不同实例**——AVCaptureSession 同时只能一个会话
    /// 占用前置摄像头，E MVP 期间用户不会"直播 + 派对房同时在视频位"（PartyCall 抢占推 F），无冲突。
    private(set) var camera: CameraManager?

    /// 视频位本端采集是否激活。UI 通过此 @Published 触发 re-render 后再取 `camera` 实例渲染 CameraPreview。
    /// camera 字段自身非 @Published（CameraManager 不需要 Combine 链路追踪）。
    @Published private(set) var isLocalCameraActive: Bool = false

    // MARK: - 衍生

    /// 自己当前所在麦位（衍生：seatList.first { userId == 自己 }）
    var selfSeat: PartyRoomSeat? {
        guard let me = myUserIdString else { return nil }
        return seatList.first { $0.userId == me }
    }

    /// 自己角色（owner / audience；admin 推 F）
    var selfRole: PartyRoomRoleType {
        roomInfo?.selfRoleType(myUserId: myUserIdString) ?? .audience
    }

    /// 当前登录 userId 的字符串形式（用于 seatList.userId 比较）
    var myUserIdString: String? { SessionStore.shared.user?.userId.map(String.init) }

    /// 当前登录 userId 的 UInt 形式（用于声网 uid 比较）
    var myRtcUid: UInt? {
        guard let id = SessionStore.shared.user?.userId, id > 0 else { return nil }
        return UInt(id)
    }

    private init() {
        rtc.delegate = self
        chat.delegate = self
        // H M3：派对房消息路由 wiring。chatRouter 持 chat 的 weak 引用以转发 delegate 调用第一参；
        // chat 持 chatRouter 的 weak 引用以 processIncoming case .custom 调度。
        // delegate 仍是 PartyStore（实现 PartyRoomChatManagerDelegate）。
        chatRouter.delegate = self
        chatRouter.chatManager = chat
        chat.router = chatRouter
        // M5 备用路径：上游 NIMChatroomManager 改走 NIMService.dispatch(context: .liveChatroom) 时，
        // 本 router 在直播聊天室通道短路（避免下游意外消费派对房 attachType）；
        // 派对房通道仍由 chat.processIncoming → chatRouter.processCustom 单一路径维持。
        NIMService.shared.registerRouter(chatRouter)
    }

    // MARK: - enterRoom

    func enterRoom(roomId: String, password: String? = nil) async {
        // 残留检查：state != idle/ended → 先强清
        if roomState != .idle && roomState != .ended {
            AppLogger.party.notice("[PartyStore] enterRoom while state=\(self.roomState.debugDesc, privacy: .public), force leave first")
            await forceLeaveRoom(.userRequest)
        }
        roomState = .preparing
        lastError = nil
        AppLogger.party.info("[PartyStore] enterRoom roomId=\(roomId, privacy: .public)")

        // Step 1: HTTP enter
        let info: PartyRoomInfo
        do {
            info = try await PartyAPI.enterRoom(roomId: roomId, password: password)
        } catch let api as PartyAPIError {
            let mapped = PartyRoomErrorMapper.map(api)
            roomState = .ended
            lastError = mapped
            AppLogger.party.error("[PartyStore] enter HTTP failed: \(api.localizedDescription, privacy: .private)")
            return
        } catch let dec as DecodingError {
            roomState = .ended
            let detail = "enter 解码: \(dec)"
            lastError = .enterFailed(underlying: detail)
            AppLogger.party.error("[PartyStore] enter decoding error: \(String(describing: dec), privacy: .public)")
            return
        } catch {
            roomState = .ended
            lastError = .enterFailed(underlying: error.localizedDescription)
            AppLogger.party.error("[PartyStore] enter unknown error: \(String(describing: error), privacy: .public)")
            return
        }

        // Step 2: 写入本地状态 + 预对账
        roomInfo = info
        seatList = info.roomSeatList ?? []
        onlineUserCount = info.onlineCount
        roomState = .entering

        // Step 3: RTC join
        guard let channelId = info.agoraChannelId, !channelId.isEmpty else {
            await forceLeaveRoom(.entryFailed)
            lastError = .enterFailed(underlying: "agoraChannelId missing")
            return
        }
        guard let uid = myRtcUid else {
            await forceLeaveRoom(.entryFailed)
            lastError = .enterFailed(underlying: "uid missing")
            return
        }
        let rtcToken: String
        if let t = info.rtcToken, !t.isEmpty {
            rtcToken = t
        } else {
            // 降级（spec §1.4.6 步骤 3）：调主接口 getAgoraRtmToken
            do {
                let r = try await LiveService.getAgoraRtmToken()
                rtcToken = r.rtcToken ?? ""
            } catch {
                AppLogger.party.error("[PartyStore] getAgoraRtmToken fallback failed: \(String(describing: error), privacy: .private)")
                await forceLeaveRoom(.entryFailed)
                lastError = .enterFailed(underlying: "rtcToken missing")
                return
            }
            guard !rtcToken.isEmpty else {
                await forceLeaveRoom(.entryFailed)
                lastError = .enterFailed(underlying: "rtcToken empty")
                return
            }
        }
        rtc.join(channelId: channelId, token: rtcToken, uid: uid)

        // Step 4: NIM enter
        guard let yxRoomId = info.yxRoomId, !yxRoomId.isEmpty else {
            await forceLeaveRoom(.entryFailed)
            lastError = .enterFailed(underlying: "yxRoomId missing")
            return
        }
        let nickname = SessionStore.shared.user?.nickname ?? ""
        chat.enter(yxRoomId: yxRoomId, nickname: nickname)

        // Step 5: 首次对账（即使 RTC didJoin 还没回，先用 info.seatList 让 UI 状态正确）
        postMikeList()
        // Step 6: 通知 WS 心跳进入派对房上下文（spec §1.5 v3）
        // 后端 weidou-socket.partyRoomHeartbeat() 据 roomId+seatIndex 更新 lastActiveTime，
        // 30s 无心跳 → 强制下麦。iOS 现有 5s 心跳保活，理论上足够。
        WSHeartbeat.shared.setPartyContext(roomId: roomId, seatIndex: selfSeat?.seatIndex ?? -1)
        // roomState = .joined 由 RTC didJoin + Chat didEnter 双就绪后回调 markJoinedIfReady() 设置
    }

    // MARK: - leaveRoom

    /// 用户主动退房（HTTP + RTC + Chat 串行；spec §1.4.6）
    func leaveRoom() async {
        guard roomState == .joined || roomState == .entering else {
            AppLogger.party.notice("[PartyStore] leaveRoom skip state=\(self.roomState.debugDesc, privacy: .public)")
            return
        }
        roomState = .leaving

        let roomIdBiz = roomInfo?.id ?? ""
        let yxRoomId = roomInfo?.yxRoomId ?? ""
        let mySeatIndex = selfSeat?.seatIndex ?? 0
        let roomTempId = roomInfo?.roomTempIdInt ?? 1

        // Step 1: 在麦时先 downSeat
        if mySeatIndex > 0 {
            do {
                try await PartyAPI.downSeat(roomId: roomIdBiz, seatIndex: mySeatIndex, yxRoomId: yxRoomId, roomTempId: roomTempId)
            } catch {
                AppLogger.party.notice("[PartyStore] downSeat on leave failed: \(String(describing: error), privacy: .private)")
            }
        }

        // Step 2: exitRoom HTTP
        do {
            try await PartyAPI.exitRoom(roomId: roomIdBiz, seatIndex: mySeatIndex, yxRoomId: yxRoomId)
        } catch {
            AppLogger.party.notice("[PartyStore] exitRoom HTTP failed: \(String(describing: error), privacy: .private)")
        }

        // Step 3: 关相机采集（视频位）+ RTC leave (async + sharedEngine 不 destroy)
        disableLocalVideoCapture()
        await rtc.leave()

        // Step 4: Chat leave
        chat.leave()

        // Step 5: 清 WS 心跳的派对房上下文
        WSHeartbeat.shared.clearPartyContext()

        // Step 6: reset
        resetState()
        roomState = .ended
        AppLogger.party.info("[PartyStore] leaveRoom done")
    }

    /// 强制退房（被踢 / 进房失败 / 网络断 / 用户主动；spec §1.4.6 异常分流）
    /// 所有步骤 try? 容错；不阻塞 reset 链路。
    func forceLeaveRoom(_ reason: PartyForceLeaveReason) async {
        AppLogger.party.notice("[PartyStore] forceLeaveRoom reason=\(String(describing: reason), privacy: .public)")
        roomState = .leaving

        let roomIdBiz = roomInfo?.id ?? ""
        let yxRoomId = roomInfo?.yxRoomId ?? ""
        let mySeatIndex = selfSeat?.seatIndex ?? 0

        if !roomIdBiz.isEmpty, !yxRoomId.isEmpty {
            // exitRoom 容错
            _ = try? await PartyAPI.exitRoom(roomId: roomIdBiz, seatIndex: mySeatIndex, yxRoomId: yxRoomId)
        }
        disableLocalVideoCapture()
        await rtc.leave()
        chat.leave()
        WSHeartbeat.shared.clearPartyContext()
        resetState()
        roomState = .ended

        if reason == .kicked {
            lastError = .kicked
        }
    }

    private func resetState() {
        roomInfo = nil
        seatList = []
        onlineUserCount = 0
        isJoinedChannel = false
        imAlive = false
        lastGiftEvent = nil
        pendingVideoSeatInvite = nil
        lastInviteResult = nil
    }

    /// RTC + Chat 双 ready 才标 .joined
    private func markJoinedIfReady() {
        guard roomState == .entering else { return }
        guard isJoinedChannel, imAlive else { return }
        roomState = .joined
        AppLogger.party.info("[PartyStore] markJoinedIfReady → state=joined")
    }

    // MARK: - 上下麦 / 媒体切换

    func requestOnSeat(seatIndex: Int) async {
        guard let info = roomInfo, roomState == .joined else { return }
        do {
            _ = try await PartyAPI.onSeat(
                roomId: info.id ?? "",
                seatIndex: seatIndex,
                yxRoomId: info.yxRoomId ?? "",
                roomTempId: info.roomTempIdInt
            )
            // 成功后等服务端下发 1001 → seatList 更新触发 postMikeList；不乐观更新
        } catch let api as PartyAPIError {
            let mapped = PartyRoomErrorMapper.map(api)
            lastError = mapped
            // 占用 / 空位错误码 → 全量重拉对账（02-04 §5）
            if case .seatOccupied = mapped { await reloadSeatListFromServer() }
            if case .seatEmpty = mapped { await reloadSeatListFromServer() }
        } catch {
            lastError = .underlying(.networkError)
        }
    }

    func requestDownSeat() async {
        guard let info = roomInfo, let me = selfSeat, let idx = me.seatIndex, roomState == .joined else { return }
        do {
            try await PartyAPI.downSeat(
                roomId: info.id ?? "",
                seatIndex: idx,
                yxRoomId: info.yxRoomId ?? "",
                roomTempId: info.roomTempIdInt
            )
        } catch {
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// 切换自己麦克风（type=1）或摄像头（type=2）开关。
    /// 本地立即更新中间态（UI 立即反馈），服务端下发 1008 后由 reload 同步 seatList 持久态。
    func toggleSelfMedia(type: Int, enable: Bool) async {
        guard let info = roomInfo, let me = selfSeat, let idx = me.seatIndex else { return }
        do {
            try await PartyAPI.updateMedia(
                roomId: info.id ?? "",
                seatIndex: idx,
                type: type,
                enable: enable,
                yxRoomId: info.yxRoomId ?? ""
            )
            // 不乐观更新 seatList；等 1008 NIM 反馈 → reload → postMikeList
        } catch {
            lastError = .mediaSwitchFailed
            AppLogger.party.error("[PartyStore] updateMedia failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 接受视频位邀请：调 `seat/respondInvite(action=1)`（**不是直接 onSeat**，安卓确认 §3.8）。
    /// 后端内部置 byInvite=true 直接 doOnSeat 绕过排队。
    /// 接受成功后立即 `updateMedia(type=3, enable=1)` 自动开麦+摄像头（安卓行为）。
    func acceptVideoSeatInvite() async {
        guard let invite = pendingVideoSeatInvite, let info = roomInfo else { return }
        pendingVideoSeatInvite = nil
        do {
            try await PartyAPI.respondInvite(
                roomId: info.id ?? "",
                yxRoomId: info.yxRoomId ?? "",
                seatIndex: invite.seatIndex,
                inviteId: invite.inviteId,
                action: 1,
                roomTempId: info.roomTempIdInt
            )
            // 接受成功 → 自动开麦+摄像头（安卓 PartyRoomDataManager 行为）
            try await PartyAPI.updateMedia(
                roomId: info.id ?? "",
                seatIndex: invite.seatIndex,
                type: 3,
                enable: true,
                yxRoomId: info.yxRoomId ?? ""
            )
        } catch {
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
            AppLogger.party.error("[PartyStore] acceptInvite failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 拒绝视频位邀请：调 `seat/respondInvite(action=2)`。
    func rejectVideoSeatInvite() async {
        guard let invite = pendingVideoSeatInvite, let info = roomInfo else {
            pendingVideoSeatInvite = nil
            return
        }
        pendingVideoSeatInvite = nil
        do {
            try await PartyAPI.respondInvite(
                roomId: info.id ?? "",
                yxRoomId: info.yxRoomId ?? "",
                seatIndex: invite.seatIndex,
                inviteId: invite.inviteId,
                action: 2,
                roomTempId: info.roomTempIdInt
            )
        } catch {
            AppLogger.party.error("[PartyStore] rejectInvite failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 清空待响应邀请（用户长时间未操作时由 UI 调用）
    func clearPendingVideoSeatInvite() {
        pendingVideoSeatInvite = nil
    }

    func clearLastError() { lastError = nil }
    func clearLastGiftEvent() { lastGiftEvent = nil }
    func clearLastInviteResult() { lastInviteResult = nil }

    // MARK: - 麦位重拉

    /// 全量重拉 seatList → 触发 postMikeList 对账。
    /// 触发场景：1012 信令 / NIM 重连 / ROOM_SEAT_IS_OCCUPIED 错误码 / NIMOnlineKeeper LOGINED 重连。
    func reloadSeatListFromServer() async {
        guard let id = roomInfo?.id, !id.isEmpty else { return }
        do {
            let seats = try await PartyAPI.seatList(roomId: id)
            seatList = seats
            postMikeList()
            AppLogger.party.info("[PartyStore] seatList reloaded count=\(seats.count, privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyStore] reload seatList failed: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - 麦位-RTC 对账中心（spec §1.4.5）

    /// 每次 seatList 变更全量遍历执行；语聊位语义已完整，视频位推帧 M5 在此基础上叠加 CameraManager 订阅。
    /// 三分类：他人在麦 / 自己在麦 / 自己不在麦。禁用 `muteRemoteAudioStream`（spec §1.2）。
    /// v4：追加他人视频位远端流 bind/unbind 对账（spec amendment v4 §4）。
    private func postMikeList() {
        let myUid = myRtcUid
        let mySelf = selfSeat
        AppLogger.party.notice("[PartyStore] postMikeList seats=\(self.seatList.count, privacy: .public) selfOn=\(mySelf != nil, privacy: .public) selfIdx=\(mySelf?.seatIndex ?? -1, privacy: .public) myUid=\(myUid ?? 0, privacy: .public)")

        // 1. 他人静音/取消静音（播放端）
        for seat in seatList {
            guard let uidStr = seat.userId, !uidStr.isEmpty else { continue }
            guard let uid = UInt(uidStr) else { continue }
            if uid == myUid { continue }
            let micOK = (seat.microphoneEnabled ?? 0) == 1 && (seat.seatMicrophoneEnabled ?? 0) == 1
            rtc.setRemoteAudio(uid: uid, enabled: micOK)
        }

        // 1b. 他人视频位远端流绑定对账（spec v4 §4）
        // diff 算法：本轮应绑的 seatIndex 集合 vs 上轮已绑；新增/同 → bindRemoteVideo（幂等）；
        // 上轮有本轮无 → unbindRemoteVideo（用旧 uid 解关联）。
        // 摄像头开关不影响绑定 —— UI 头像覆盖即可（H5 行为，对齐 spec v4 §2）；流持续订阅保证开关切换无首帧丢失。
        var desiredBindings: Set<Int> = []
        for seat in seatList {
            guard let idx = seat.seatIndex, idx > 0 else { continue }
            guard seat.seatType == 1, seat.occupied else { continue }
            guard let uidStr = seat.userId, let uid = UInt(uidStr), uid > 0 else {
                if let bad = seat.userId {
                    AppLogger.party.notice("[PartyStore] postMikeList skip remote video, bad uid=\(bad, privacy: .public) seatIndex=\(idx, privacy: .public)")
                }
                continue
            }
            if uid == myUid { continue }  // R7：自己视频位不进远端绑定
            desiredBindings.insert(idx)
            rtc.bindRemoteVideo(seatIndex: idx, uid: uid)
        }
        // 上轮绑过但本轮不在 desired 的 → 清理
        let previouslyBound = rtc.boundRemoteSeatIndices
        for idx in previouslyBound where !desiredBindings.contains(idx) {
            rtc.unbindRemoteVideo(seatIndex: idx)
        }

        // 同步 WS 心跳的 seatIndex，让 5s 周期心跳带最新麦位状态（spec §1.5 v3）
        if roomState == .joined || roomState == .entering, let rid = roomInfo?.id, !rid.isEmpty {
            WSHeartbeat.shared.setPartyContext(roomId: rid, seatIndex: mySelf?.seatIndex ?? -1)
        }

        // 2. 自己在麦 / 不在麦
        if let me = mySelf {
            let seatType = me.typed ?? .voice
            rtc.upperSeat(seatType: seatType)
            let micEnabled = (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
            rtc.muteLocalMicrophone(!micEnabled)
            // 视频位：启 RTC 视频通道 + CameraManager 订阅推帧；
            // 摄像头开关由 microphoneEnabled 同侪字段 cameraEnabled 决定（M5 接入）
            if seatType == .video {
                rtc.enableVideoSeat()
                let camEnabled = (me.cameraEnabled ?? 0) == 1
                if camEnabled {
                    enableLocalVideoCapture()
                } else {
                    disableLocalVideoCapture()
                }
            } else {
                disableLocalVideoCapture()
                rtc.disableVideoSeat()
            }
        } else {
            disableLocalVideoCapture()
            rtc.downSeat()
        }
    }

    // MARK: - 视频位本端采集（M5）

    /// 启动相机采集 + 美颜 + 推帧到 PartyRTCEngine。
    /// CameraManager 内部已含 FUBeautyRenderer / Passthrough 降级；sink 拿到的就是美颜后 BGRA。
    /// closure capture `rtc` 引用（PartyRTCEngine 非 @MainActor，pushFrame 是 nonisolated）。
    private func enableLocalVideoCapture() {
        guard camera == nil else { return }
        let cm = CameraManager()
        camera = cm
        let rtcRef = rtc
        let key = ObjectIdentifier(self)
        cm.subscribe(key) { pixelBuffer in
            rtcRef.pushFrame(pixelBuffer)
        }
        cm.start()
        isLocalCameraActive = true
        AppLogger.party.info("[PartyStore] camera capture started (video seat)")
    }

    /// 停止相机采集；下视频位 / 退房时调用。
    /// tearDown 内会 stop session + remove observers + clear subscribers + 释放美颜资源。
    private func disableLocalVideoCapture() {
        guard let cm = camera else { return }
        cm.unsubscribe(ObjectIdentifier(self))
        cm.tearDown()
        camera = nil
        isLocalCameraActive = false
        AppLogger.party.info("[PartyStore] camera capture stopped")
    }
}

// MARK: - PartyRTCEngineDelegate

extension PartyStore: PartyRTCEngineDelegate {

    func partyRTCEngineDidJoin(_ engine: PartyRTCEngine) {
        isJoinedChannel = true
        markJoinedIfReady()
    }

    func partyRTCEngine(_ engine: PartyRTCEngine, didJoinedRemoteUid uid: UInt) {
        // 远端加入触发对账（确保新进入的远端音量状态正确）
        postMikeList()
    }

    func partyRTCEngine(_ engine: PartyRTCEngine, didOfflineRemoteUid uid: UInt) {
        // 远端离开：seatList 由 NIM 1001 推送同步；这里仅对账（无 op）
    }

    func partyRTCEngine(_ engine: PartyRTCEngine, didFailWithReason reason: String) {
        AppLogger.party.error("[PartyStore] RTC fail: \(reason, privacy: .public)")
        guard roomState == .entering || roomState == .joined else { return }
        Task { [weak self] in
            await self?.forceLeaveRoom(.entryFailed)
        }
        lastError = .enterFailed(underlying: reason)
    }
}

// MARK: - PartyRoomChatManagerDelegate

extension PartyStore: PartyRoomChatManagerDelegate {

    func partyRoomChatDidEnter(_ chat: PartyRoomChatManager) {
        imAlive = true
        markJoinedIfReady()
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didFailToEnter reason: String) {
        AppLogger.party.error("[PartyStore] chat enter fail: \(reason, privacy: .public)")
        Task { [weak self] in await self?.forceLeaveRoom(.entryFailed) }
        lastError = .enterFailed(underlying: reason)
    }

    func partyRoomChatDidReconnect(_ chat: PartyRoomChatManager) {
        guard isJoinedChannel else { return }
        AppLogger.party.notice("[PartyStore] chat reconnect → reload seatList")
        Task { [weak self] in await self?.reloadSeatListFromServer() }
    }

    func partyRoomChatDidKickOut(_ chat: PartyRoomChatManager) {
        Task { [weak self] in await self?.forceLeaveRoom(.kicked) }
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveSeatUpdate payload: [String: Any], raw: NIMMessage) {
        _ = raw
        // MVP 简化：1001 payload schema 待 M3 抓真实帧确认；
        // 现策略——若 payload 含完整 seatList 数组直接替换，否则全量重拉。
        AppLogger.party.notice("[PartyStore] 1001 seatUpdate payload keys=\(Array(payload.keys), privacy: .public)")
        if let seats = decodeSeatListField(payload) {
            AppLogger.party.notice("[PartyStore] 1001 direct seatList replace count=\(seats.count, privacy: .public)")
            seatList = seats
            postMikeList()
        } else {
            AppLogger.party.notice("[PartyStore] 1001 fallback to reloadSeatListFromServer")
            Task { [weak self] in await self?.reloadSeatListFromServer() }
        }
    }

    func partyRoomChatDidRequireSeatListReload(_ chat: PartyRoomChatManager) {
        AppLogger.party.notice("[PartyStore] 1012 require full seatList reload")
        Task { [weak self] in await self?.reloadSeatListFromServer() }
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveProhibitMic payload: [String: Any], raw: NIMMessage) {
        _ = raw
        // 安卓确认 §3.7：1015 payload `{roomId, seatIndex, seatMicrophoneEnabled(0禁/1解), userId, operatorType(6禁/7解)}`。
        // 定向更新（取代全量 reload），减少抖动。
        applyMediaUpdate(payload, isProhibit: true)
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveMediaUpdate payload: [String: Any], raw: NIMMessage) {
        _ = raw
        // 安卓确认 §3.6：1008 payload `{roomId, seatIndex, seatType, userId, cameraEnabled(0/1), microphoneEnabled(0/1)}`。
        // 定向更新（取代全量 reload）。
        applyMediaUpdate(payload, isProhibit: false)
    }

    /// 把 1008 / 1015 payload 的字段定向更新到 seatList 对应麦位 → 触发 postMikeList 对账。
    /// `isProhibit=true` 时更新 `seatMicrophoneEnabled`（管理员禁麦态），
    /// `false` 时更新 `microphoneEnabled / cameraEnabled`（用户自身开关）。
    /// 字段缺失则不更新该字段（与服务端 partial update 语义一致）。
    private func applyMediaUpdate(_ payload: [String: Any], isProhibit: Bool) {
        guard let targetSeatIndex = PartyValueNormalizer.intify(payload["seatIndex"]) else {
            AppLogger.party.notice("[PartyStore] media update payload missing seatIndex; full reload fallback")
            Task { [weak self] in await self?.reloadSeatListFromServer() }
            return
        }
        guard let idx = seatList.firstIndex(where: { $0.seatIndex == targetSeatIndex }) else {
            // 未匹配（房间模板可能切了）→ 全量 reload 兜底
            Task { [weak self] in await self?.reloadSeatListFromServer() }
            return
        }
        let old = seatList[idx]
        let newSeat = PartyRoomSeat(
            id: old.id,
            roomId: old.roomId,
            seatIndex: old.seatIndex,
            userId: old.userId,
            avatar: old.avatar,
            nickname: old.nickname,
            seatType: PartyValueNormalizer.intify(payload["seatType"]) ?? old.seatType,
            isOccupied: old.isOccupied,
            cameraEnabled: isProhibit ? old.cameraEnabled : (PartyValueNormalizer.intify(payload["cameraEnabled"]) ?? old.cameraEnabled),
            microphoneEnabled: isProhibit ? old.microphoneEnabled : (PartyValueNormalizer.intify(payload["microphoneEnabled"]) ?? old.microphoneEnabled),
            roomRoleType: old.roomRoleType,
            giftValueCount: old.giftValueCount,
            headFrame: old.headFrame,
            yxAccid: old.yxAccid,
            userType: old.userType,
            seatCameraEnabled: old.seatCameraEnabled,
            seatMicrophoneEnabled: isProhibit ? (PartyValueNormalizer.intify(payload["seatMicrophoneEnabled"]) ?? old.seatMicrophoneEnabled) : old.seatMicrophoneEnabled,
            lockFlag: old.lockFlag,
            roomTempId: old.roomTempId,
            isHostSeat: old.isHostSeat,
            isPlatformAdmin: old.isPlatformAdmin,
            showBubble: old.showBubble,
            anchorTaskRewardExt: old.anchorTaskRewardExt
        )
        seatList[idx] = newSeat
        postMikeList()
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveGift payload: [String: Any], raw: NIMMessage) {
        // C 档单测重构（2026-06-26）：解析逻辑下沉到 PartyGiftEvent.from(payload:timestampMs:)
        // 仅此处保留 NIMMessage → timestampMs 桥接，避免 from 静态函数耦合 NIMSDK。
        let event = PartyGiftEvent.from(
            payload: payload,
            timestampMs: Int64(raw.timestamp * 1000)
        )
        lastGiftEvent = event
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveVideoSeatInvite invite: PartyVideoSeatInvite) {
        // 仅当邀请对象是自己（房间匹配）才弹窗——roomId 已在 chat 双过滤；
        // seatIndex 范围由 chat 内 handleVideoSeatInvite 校验过。
        pendingVideoSeatInvite = invite
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveInviteResult result: PartyVideoSeatInviteResult) {
        lastInviteResult = result
    }

    /// 从 1001 payload 解 seats 数组（安卓确认 §3.1：顶层 key=`seats`，全量麦位，附 `seatOperate` 变更原因）。
    /// 失败返 nil → 触发全量 reload。
    private func decodeSeatListField(_ payload: [String: Any]) -> [PartyRoomSeat]? {
        // 安卓真值：1001 顶层 key 是 `seats`（不是 seatList/mikeList/list/data）
        guard let arr = payload["seats"] as? [[String: Any]] else {
            return nil
        }
        // 顺带打日志 seatOperate 字段（调试用，MVP 不分支处理）
        if let op = payload["seatOperate"] as? Int {
            AppLogger.party.notice("[PartyStore] 1001 seatOperate=\(op, privacy: .public) seatCount=\(arr.count, privacy: .public)")
        }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: arr)
            return try JSONDecoder().decode([PartyRoomSeat].self, from: jsonData)
        } catch {
            AppLogger.party.error("[PartyStore] 1001 seats decode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

// MARK: - debug helper

private extension PartyRoomState {
    var debugDesc: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .entering: return "entering"
        case .joined: return "joined"
        case .leaving: return "leaving"
        case .ended: return "ended"
        }
    }
}
