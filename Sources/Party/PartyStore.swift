import Combine
import Foundation
import NIMSDK
import SwiftUI  // @AppStorage（E v2 §3 partySaveInfo.autoEnter{On,Off}Application 本地持久化）

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

    /// 是否已关注当前房主（对齐 H5 `currentPartyInfo.isFollowOwner`）。
    /// 进房时初始化自 `roomInfo.isFollowOwner`；`toggleFollowAnchor()` 后翻转。
    @Published private(set) var isFollowingAnchor: Bool = false
    /// 关注切换请求是否在飞（防连点重复请求）
    @Published private(set) var isTogglingFollow: Bool = false

    /// v12：房主头像装饰框 URL（对齐 H5 `ownerInfo.headFrame` = `apiPartyGetUser.headFrameSmallImg`）。
    /// enterRoom 完成后 async 拉；`.svga` 结尾 iOS 暂 fallback 到无装饰（G/H 期接 SVGA 播放器）。
    @Published private(set) var ownerHeadFrameURL: String?
    private var didLoadOwnerInfo = false

    /// v15 声纹反馈：正在说话的 Agora uid 集合（对齐 H5 `volumeList`）。
    /// 数据源：`PartyRTCEngine.reportAudioVolumeIndicationOfSpeakers` → 阈值 volume>5 → 500ms 全量替换。
    /// UI 层：`isSpeaking(seat:)` 派生，seat.userId String → UInt 转换后查集合命中。
    @Published private(set) var speakingUids: Set<UInt> = []

    // MARK: - Room Mode (E v2 §1)

    /// 房主 Room Mode 模板列表缓存（key=tab type 1/2）。spec §1 UI 态。
    @Published private(set) var roomModeTemplates: [PartyRoomModeType: [PartyRoomTemplate]] = [:]
    /// 模板拉取状态机；`partialLoaded` 承载单 tab 失败另一 tab 成功场景（spec §1）。
    @Published private(set) var roomModeTemplatesState: PartyRoomModeTemplatesState = .idle
    /// 切模板成功本地时间戳；IM 1017 处理入口对比 msgTimestamp - 3s 判丢乱序旧 1001/1012（spec §1 步骤 1）。
    private var lastRoomTempSwitchAt: Date? = nil
    /// switchRoomMode 幂等 flag（Confirm 2000ms window 内二次点击不重复请求，spec §0 throttle）
    private var isBusySwitchRoomMode: Bool = false

    // MARK: - Mic Application (E v2 §2)

    /// 排麦申请列表状态机（房主/房管端），套 list-refresh-preserve-items rule（保留 refreshing 视觉）
    @Published private(set) var micApplicationsState: PartyMicApplicationsState = .idle
    /// Mic Application 开关（来源：1021 IM 广播）
    @Published private(set) var micApplicationSwitchOn: Bool = false
    /// 队列总长度（1018 payload num 消费；用于外部 badge/系统消息计数）
    @Published private(set) var queueSeatNum: Int = 0
    /// 观众端 "我的申请"（inIndex 排队位序 + rejectedAt 30s 冷却）
    @Published private(set) var myApplyInfo: PartyMyApplyInfo = .init()
    /// agreeSeat 并发占位集合：房主快速批准两申请时排除已挑走的 seatIndex 防冲突（spec §2 R6）
    private var pendingApproveSeatIndex: Set<Int> = []
    /// applying 超时兜底 Task：inIndex > 0 持续 5min 无 IM → 本地自动 giveUp（spec §2 R9）
    private var applyingTimeoutTask: Task<Void, Never>? = nil
    /// 开关 API 幂等 flag（防连点，与 Confirm 分开 flag 隔离）
    private var isBusyMicSwitch: Bool = false
    /// spec §0 throttle：所有 Mic Application 类 mutating async 用 isBusy flag 幂等（防 spam 双请求）
    private var isBusyApplyMic: Bool = false
    private var isBusyCancelMyMicApplication: Bool = false
    private var isBusyRefuseMicApplication: Bool = false
    /// agreeMicApplication 用 per-userId set 幂等（同一申请者不重复批准，不同申请者可并发）
    private var pendingApproveUserId: Set<String> = []

    // MARK: - Blocklist (E spec §3，房间维度黑名单)

    /// 房间黑名单状态机（房主/房管端），套 list-refresh-preserve-items rule（保留 refreshing 视觉）
    @Published private(set) var blocklistState: PartyBlocklistState = .idle
    /// per-userId 幂等守护：同一 userId 快速连点 remove 只发一次请求（spec §4 R3）；
    /// 不同 userId 允许并发（每个 row 独立 isBusy）
    private var isBusyRemoveBlocklist: Set<String> = []
    /// spec §3：sheet 快关快开时 cancel 上一次未完成的 load，防 CancellationError 污染新 state
    private var loadBlocklistTask: Task<Result<[PartyBlocklistItem], Error>, Never>? = nil

    // MARK: - Lock Room (E spec §3 Lock Room)

    /// 房间加/解锁 API 幂等 flag（spec §4 R3；防 Save/Lock Room icon 连点双请求）
    private var isBusyLockRoom: Bool = false

    // MARK: - MC Seat (E spec §3 MC Seat, 2026-07-14)

    /// setMCSeat 幂等 flag（per-seatIndex；防同 seat 快速双点双请求）。
    /// 全房至多 1 个 MC，但 picker sheet 内切换目标 seatIndex 时允许对不同 seat 并发（服务端会覆盖）。
    /// spec §0.2 "MC 全房至多 1 个"：set/close 共用房间级 flag 避免 set A + close race
    /// （原 per-seatIndex Set 只防同 seat 双点，不防跨 set A + set B or set A + close）
    private var isBusyMCSeat: Bool = false  // set + close 共用（防 set A + close race）

    /// partySaveInfo（对齐 H5 stores/modules/user.js partySaveInfo）：本地长驻两个 Bool flag，
    /// 用户是否已经首次协议确认过 "打开申请" / "关闭申请"；二次同方向切换 UI 直接调 API 不弹协议弹窗。
    /// 说明：@AppStorage 在 ObservableObject 中不触发 objectWillChange（与视图订阅相反），
    /// 但本 flag 是 "应否弹协议弹窗" 的一次性判断——UI 层 imperative 读取即可，无需 Combine 订阅。
    @AppStorage("party.autoEnterOnApplication") var autoEnterOnApplication: Bool = false
    @AppStorage("party.autoEnterOffApplication") var autoEnterOffApplication: Bool = false

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

    /// E-spec §0.2 F-05：登出时切断 chatRouter 全局注册。
    /// 用户 A 登出 → NIMOnlineKeeper.stop → 用户 B 登录 → NIMService 重连；chatRouter 仍是 A 时代实例、
    /// delegate 仍是本单例 → 派对房消息若从 B 账号收到，会误触发 delegate 调用 UI 状态。
    /// 由 RootView.syncSessionDependent 登出分支调用。
    func detachChatRouter() {
        NIMService.shared.unregisterRouter(chatRouter)
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
        // 初始化关注态（对齐 H5 `currentPartyInfo.isFollowOwner`；nil 视为未关注）
        isFollowingAnchor = info.isFollowOwner ?? false
        // v16：字段真机对齐诊断 —— 若后端 `isFollowOwner` 字段名不匹配 / 不返回，
        // 用户报"已关注房间重进显示未关注"时可查此 log 确认后端行为
        AppLogger.party.info("[PartyStore] enter isFollowOwner raw=\(String(describing: info.isFollowOwner), privacy: .public) → isFollowingAnchor=\(self.isFollowingAnchor, privacy: .public)")
        // v12：房主头像框 async 拉（不阻塞进房主流程）
        Task { [weak self] in await self?.loadOwnerInfoIfNeeded() }
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
        isFollowingAnchor = false
        isTogglingFollow = false
        // v12：房主头像框 state 清（退房后下次进新房需重拉）
        ownerHeadFrameURL = nil
        didLoadOwnerInfo = false
        // E v2：Room Mode / Mic Application 状态清 —— 退房需清残留，避免下次进房带入旧队列
        roomModeTemplates = [:]
        roomModeTemplatesState = .idle
        lastRoomTempSwitchAt = nil
        isBusySwitchRoomMode = false
        micApplicationsState = .idle
        micApplicationSwitchOn = false
        queueSeatNum = 0
        myApplyInfo = .init()
        pendingApproveSeatIndex = []
        applyingTimeoutTask?.cancel()
        applyingTimeoutTask = nil
        isBusyMicSwitch = false
        // E spec §3：黑名单状态清 —— 退房需清残留，避免下次进新房带入旧列表
        blocklistState = .idle
        isBusyRemoveBlocklist = []
        loadBlocklistTask?.cancel()
        loadBlocklistTask = nil
        // E spec §3 Lock Room：幂等 flag 清（退房若正好卡在请求中，下次进新房重置为可用）
        isBusyLockRoom = false
        // E spec §3 MC Seat：幂等 flag 清（退房重置）
        isBusyMCSeat = false
    }

    // MARK: - 房主保存设置后本地同步（v8.2）

    /// 房主 `PartyRoomSettingsView` 保存成功后回写本地 `roomInfo` —— 顶栏/房间信息立即刷新，
    /// 不必等下次 enter 或 IM 广播。
    /// 传 nil 表示未变化不覆盖；传新值覆盖对应字段。
    func applyRoomSettingsChanges(
        roomName: String? = nil,
        roomAvatar: String? = nil,
        greetingMessage: String? = nil,
        roomLanguage: String? = nil
    ) {
        guard let info = roomInfo else { return }
        roomInfo = info.withUpdated(
            roomName: roomName,
            roomAvatar: roomAvatar,
            greetingMessage: greetingMessage,
            roomLanguage: roomLanguage
        )
    }

    // MARK: - 房主 ownerInfo（v12 对齐 H5 party.js:1259 loadOwnerInfo）

    /// enterRoom 后 async 拉房主 headFrame 装饰。失败/无字段静默 nil，视觉降级到无装饰。
    /// dedup：`didLoadOwnerInfo` 保证同一房只拉一次；`resetState()` 清 flag 让新房重拉。
    func loadOwnerInfoIfNeeded() async {
        guard !didLoadOwnerInfo,
              let ownerId = roomInfo?.ownerId,
              let uid = Int(ownerId), uid > 0 else { return }
        didLoadOwnerInfo = true
        do {
            let info = try await PartyAPI.getUserBasicInfo(userId: uid)
            let url = info?.headFrameSmallImg?.trimmingCharacters(in: .whitespaces)
            ownerHeadFrameURL = (url?.isEmpty == false) ? url : nil
        } catch {
            AppLogger.party.error("[PartyStore] loadOwnerInfo failed: \(String(describing: error), privacy: .public)")
            ownerHeadFrameURL = nil
        }
    }

    // MARK: - 关注房主（对齐 H5 header-wrap.vue L139-140 handleFollowOrNo）

    /// 切换关注状态。请求成功后翻转 `isFollowingAnchor`；失败静默保留原状态。
    /// followType：**已关注 → 2（取关）；未关注 → 1（关注）**（对齐 FollowListService.followUser 语义）。
    ///
    /// 返回值：`nil` = skip（重入 / owner 非法）；非 nil 时 `success=true` 代表接口成功，
    /// `willFollow` 反映**成功后的目标状态**（true=已关注 / false=已取关），View 层据此决定 toast 文案。
    @discardableResult
    func toggleFollowAnchor() async -> (success: Bool, willFollow: Bool)? {
        guard !isTogglingFollow else { return nil }
        guard let owner = roomInfo?.ownerId, let ownerIdInt = Int(owner), ownerIdInt > 0 else {
            AppLogger.party.error("[PartyStore] toggleFollow skip: ownerId invalid")
            return nil
        }
        let willFollow = !isFollowingAnchor
        let type = willFollow ? 1 : 2
        isTogglingFollow = true
        defer { isTogglingFollow = false }
        do {
            try await FollowListService.followUser(followUserId: ownerIdInt, followType: type)
            isFollowingAnchor = willFollow
            AppLogger.party.info("[PartyStore] toggleFollow ok uid=\(ownerIdInt) willFollow=\(willFollow, privacy: .public)")
            return (true, willFollow)
        } catch {
            AppLogger.party.error("[PartyStore] toggleFollow failed: \(String(describing: error), privacy: .public)")
            // 静默失败：不 lastError = ...（关注失败不阻塞房间业务；UI 层可通过 isFollowingAnchor 未翻转感知）
            return (false, willFollow)
        }
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

    /// 切麦：从当前麦位切换到目标 seatIndex（对齐 H5 feachExchangeSeat）。
    /// - 前置：selfSeat 存在且已 joined
    /// - targetSeatType 取自目标麦位 seatType（1=video / 2=voice），后端需知道目标位类型做校验
    /// - 成功后等服务端 1001 seat/update 广播 → seatList 更新触发 postMikeList，不乐观更新
    func requestExchangeSeat(targetSeatIndex: Int, targetSeatType: Int) async {
        guard let info = roomInfo, selfSeat != nil, roomState == .joined else { return }
        do {
            try await PartyAPI.exchangeSeat(
                roomId: info.id ?? "",
                seatIndex: targetSeatIndex,
                yxRoomId: info.yxRoomId ?? "",
                seatType: targetSeatType,
                roomTempId: info.roomTempIdInt
            )
        } catch let api as PartyAPIError {
            let mapped = PartyRoomErrorMapper.map(api)
            lastError = mapped
            if case .seatOccupied = mapped { await reloadSeatListFromServer() }
            if case .seatEmpty = mapped { await reloadSeatListFromServer() }
        } catch {
            lastError = .underlying(.networkError)
        }
    }

    /// v15 房主/房管：禁 / 解禁他人麦位（对齐 H5 feachProhibitSeat + usePartyHooks.js:1157）。
    /// - mute=true → operatorType=6（禁麦）；mute=false → operatorType=7（解禁麦）
    /// - 前置：selfRole==.owner || .admin；seatIndex 是**占用位**（seatMicrophoneEnabled 是服务端管理态）
    /// - 服务端下发 1008 广播 → seat.seatMicrophoneEnabled 切换 → isSpeaking 派生自动过滤禁麦位不显 pulse
    func requestProhibitSeat(seatIndex: Int, mute: Bool) async {
        guard let info = roomInfo, roomState == .joined else { return }
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] prohibitSeat rejected: not owner/admin")
            return
        }
        do {
            try await PartyAPI.prohibitSeat(
                roomId: info.id ?? "",
                seatIndex: seatIndex,
                yxRoomId: info.yxRoomId ?? "",
                operatorType: mute ? 6 : 7,
                roomTempId: info.roomTempIdInt
            )
        } catch let api as PartyAPIError {
            lastError = PartyRoomErrorMapper.map(api)
        } catch {
            lastError = .underlying(.networkError)
            AppLogger.party.error("[PartyStore] prohibitSeat failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// v15 房主/房管：锁 / 解锁空麦位（对齐 H5 feachLockSeat + usePartyHooks.js:1205）。
    /// - lock=true → operatorType=8（锁）；lock=false → operatorType=9（解锁）
    /// - 前置：selfRole==.owner || .admin；seatIndex 是空位（有人时后端拒）
    /// - 成功后等服务端 1001 seat/update 广播 → seat.lockFlag 切换 → UI 视觉更新
    func requestLockSeat(seatIndex: Int, lock: Bool) async {
        guard let info = roomInfo, roomState == .joined else { return }
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] lockSeat rejected: not owner/admin")
            return
        }
        do {
            try await PartyAPI.lockSeat(
                roomId: info.id ?? "",
                seatIndex: seatIndex,
                yxRoomId: info.yxRoomId ?? "",
                operatorType: lock ? 8 : 9,
                roomTempId: info.roomTempIdInt
            )
        } catch let api as PartyAPIError {
            let mapped = PartyRoomErrorMapper.map(api)
            lastError = mapped
            // 麦位状态可能已变（并发有人上麦）→ 触发 reload 对账
            if case .seatOccupied = mapped { await reloadSeatListFromServer() }
        } catch {
            lastError = .underlying(.networkError)
            AppLogger.party.error("[PartyStore] lockSeat failed: \(String(describing: error), privacy: .private)")
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
        // K 里程碑：attach `.party` token 到 Sharer，让 K 页面调过的美颜参数广播到派对房 renderer
        BeautyPipelineSharer.shared.attach(cm.renderer as AnyObject & BeautyRenderer, token: .party)
        BeautyPipelineSharer.shared.reportSetupResult(cm.isBeautyFallback ? .failure(.genericSetupFailed) : .success(()))
        // K 里程碑 P0-3 fix（2026-07-03 review 202607030426）：首帧一致（同 CallView 模式）
        cm.renderer.apply(BeautyPipelineSharer.shared.store.settings)
        AppLogger.party.info("[PartyStore] camera capture started (video seat)")
    }

    /// 停止相机采集；下视频位 / 退房时调用。
    /// tearDown 内会 stop session + remove observers + clear subscribers + 释放美颜资源。
    private func disableLocalVideoCapture() {
        guard let cm = camera else { return }
        // K 里程碑：detach Sharer 订阅（在 tearDown 前，让 subscribers 栈及时更新）
        BeautyPipelineSharer.shared.detach(cm.renderer as AnyObject & BeautyRenderer)
        cm.unsubscribe(ObjectIdentifier(self))
        cm.tearDown()
        camera = nil
        isLocalCameraActive = false
        AppLogger.party.info("[PartyStore] camera capture stopped")
    }

    // MARK: - Room Mode (E v2 §1)

    /// 拉取 Room Mode 模板列表（并发 type=1 + type=2；单 tab 失败走 partialLoaded）。
    /// spec §1 UI 态：`loading → loaded / partialLoaded / error`。已缓存 tab 复用不重拉。
    func loadRoomModeTemplates() async {
        // 若两 tab 都已缓存则直接切到 loaded 态（enterRoom 后二次打开面板时命中）
        if let voice = roomModeTemplates[.voiceOnly],
           let live = roomModeTemplates[.liveAndVoice] {
            roomModeTemplatesState = .loaded(voice: voice, live: live)
            return
        }
        roomModeTemplatesState = .loading

        // 并发 Promise.allSettled 语义
        async let voiceResult: [PartyRoomTemplate]? = fetchRoomTempListSafely(type: PartyRoomModeType.voiceOnly.rawValue)
        async let liveResult: [PartyRoomTemplate]? = fetchRoomTempListSafely(type: PartyRoomModeType.liveAndVoice.rawValue)
        let voice = await voiceResult
        let live = await liveResult

        if let v = voice { roomModeTemplates[.voiceOnly] = v }
        if let l = live { roomModeTemplates[.liveAndVoice] = l }

        switch (voice, live) {
        case (let v?, let l?):
            roomModeTemplatesState = .loaded(voice: v, live: l)
            AppLogger.party.info("[PartyStore] roomMode templates loaded voice=\(v.count, privacy: .public) live=\(l.count, privacy: .public)")
        case (nil, nil):
            // 两 tab 都失败 → error（依赖 APIClient 全局 toast；本地只落状态机）
            roomModeTemplatesState = .error(L10n.Party.roomModeLoadError)
            AppLogger.party.error("[PartyStore] roomMode templates all failed")
        default:
            // 单 tab 失败 → partialLoaded
            roomModeTemplatesState = .partialLoaded(voice: voice, live: live)
            AppLogger.party.notice("[PartyStore] roomMode templates partial voiceOk=\(voice != nil, privacy: .public) liveOk=\(live != nil, privacy: .public)")
        }
    }

    /// 单 tab 拉取，异常吞掉返 nil（partialLoaded 语义依赖此包装）
    private func fetchRoomTempListSafely(type: Int) async -> [PartyRoomTemplate]? {
        do {
            return try await PartyAPI.roomTempList(type: type)
        } catch {
            AppLogger.party.error("[PartyStore] roomTempList(type=\(type, privacy: .public)) failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// 房主切模板（spec §1）。isBusy 2000ms 幂等；成功后本地立即调 handleRoomModeChanged
    /// （不等 IM 1017 回执，云信可能不发自己回执导致状态分裂）。
    func switchRoomMode(to tempId: Int) async {
        guard !isBusySwitchRoomMode else {
            AppLogger.party.notice("[PartyStore] switchRoomMode skip: busy")
            return
        }
        guard let info = roomInfo, roomState == .joined else {
            AppLogger.party.notice("[PartyStore] switchRoomMode skip: not joined")
            return
        }
        // 幂等：当前模板 == 目标 → 直接 return
        if info.roomTempIdInt == tempId {
            AppLogger.party.info("[PartyStore] switchRoomMode noop: already tempId=\(tempId, privacy: .public)")
            return
        }
        isBusySwitchRoomMode = true
        defer { isBusySwitchRoomMode = false }

        do {
            try await PartyAPI.switchRoomTemp(
                roomId: info.id ?? "",
                roomTempId: tempId,
                yxRoomId: info.yxRoomId ?? ""
            )
            // 打时间戳用于 IM 1017 乱序判丢（spec §1 步骤 1）
            lastRoomTempSwitchAt = Date()
            AppLogger.party.info("[PartyStore] switchRoomTemp ok tempId=\(tempId, privacy: .public)")
            // 房主本地兜底：不等 IM 回执，立即触发 handleRoomModeChanged
            handleRoomModeChanged(newTempId: tempId, seats: nil, cause: .local)
        } catch {
            AppLogger.party.error("[PartyStore] switchRoomTemp failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// Room Mode 切换统一入口（spec §1 IM 1017 处理步骤 3-7）。
    /// - Parameters:
    ///   - newTempId: 新模板 ID
    ///   - seats: 若来自 IM 且 payload 含 seats，全量替换；nil 时触发 seat/list 重拉
    ///   - cause: `.local` 房主 API 成功兜底 / `.remote` 观众端 IM 到达
    func handleRoomModeChanged(newTempId: Int?, seats: [PartyRoomSeat]?, cause: PartyRoomModeChangeCause) {
        // 幂等保护（spec §1 步骤 2）：无论 .local 还是 .remote，若目标 tempId 已生效则短路，
        // 只增量刷 seats 不重复触发下麦/系统消息（防房主本地兜底后 IM 到达 double 触发）
        if let tempId = newTempId, roomInfo?.roomTempIdInt == tempId {
            AppLogger.party.info("[PartyStore] handleRoomModeChanged idempotent tempId=\(tempId, privacy: .public) cause=\(String(describing: cause), privacy: .public)")
            if let s = seats {
                seatList = s
                postMikeList()
            }
            return
        }

        // 步骤 3：全量替换 seatList + RTC bindings 对账（等价 postMikeList）
        if let s = seats {
            seatList = s
            postMikeList()
        } else {
            // IM payload 缺 seats（或本地兜底路径）→ 全量重拉兜底
            Task { [weak self] in await self?.reloadSeatListFromServer() }
        }

        // 步骤 4：自身分支——先前在麦上则触发下麦 hook + 视频停采
        // TODO(spec §1 step 4)：接入统一埋点框架后补 party_video_leave/voice_leave reason=modeChange
        let wasOnSeat = (selfSeat != nil)
        if wasOnSeat {
            disableLocalVideoCapture()
            AppLogger.party.info("[PartyStore] handleRoomModeChanged self was on seat, disable local video (reason=modeChange)")
        }

        // 步骤 5：公屏落系统消息
        chatRouter.postSystemMessage(L10n.Party.roomModeSystemMsg)

        // 步骤 6：清 Mic Application 相关状态（服务端切模板时会清队列）
        applyingTimeoutTask?.cancel()
        applyingTimeoutTask = nil
        myApplyInfo = .init()
        micApplicationsState = .empty
        queueSeatNum = 0
        pendingApproveSeatIndex = []

        // 步骤 7：更新 roomInfo.roomTempId（供后续 IM 幂等判断命中）
        // newTempId==nil 时（IM payload 无该字段）跳过 —— 后续同款切换会走完整路径不重复副作用无影响，只是幂等失效
        if let info = roomInfo, let tempId = newTempId {
            roomInfo = info.withUpdated(roomTempId: String(tempId))
        }
        AppLogger.party.info("[PartyStore] handleRoomModeChanged applied tempId=\(newTempId ?? -1, privacy: .public) cause=\(String(describing: cause), privacy: .public) hadSeats=\(seats != nil, privacy: .public)")
    }

    // MARK: - Mic Application (E v2 §2)

    /// 拉取排麦申请列表（房主/房管）。
    /// - `.initial`：首次开面板 → `.loading`
    /// - `.refresh`：下拉刷新 / 1018 op=1 触发 → 保留旧 items 视觉走 `.refreshing(items)`
    func loadMicApplications(reason: PartyMicApplicationsLoadReason) async {
        guard let info = roomInfo, roomState == .joined else { return }

        // list-refresh-preserve-items rule：refresh 时保留视觉
        switch (reason, micApplicationsState) {
        case (.refresh, .loaded(let old)):
            micApplicationsState = .refreshing(old)
        case (.refresh, .refreshing(let old)):
            micApplicationsState = .refreshing(old)
        default:
            micApplicationsState = .loading
        }

        do {
            let resp = try await PartyAPI.getQueueSeatList(roomId: info.id ?? "", pageSize: 99)
            queueSeatNum = resp.totalNum
            if resp.records.isEmpty {
                micApplicationsState = .empty
            } else {
                micApplicationsState = .loaded(resp.records)
            }
            AppLogger.party.info("[PartyStore] getQueueSeatList ok total=\(resp.totalNum, privacy: .public) rec=\(resp.records.count, privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyStore] getQueueSeatList failed: \(String(describing: error), privacy: .private)")
            micApplicationsState = .error(L10n.Party.errorNetworkLost)
        }
    }

    /// list-refresh-preserve-items rule：`.refreshable` closure 必须 await 到任务完成，
    /// 否则顶部 spinner 立即消失。
    func refreshMicApplications() async {
        await loadMicApplications(reason: .refresh)
    }

    /// 观众端申请上麦（spec §2 观众端）。30s 冷却 + 5min 超时兜底。
    func applyMic(seatIndex: Int) async {
        // spec §0 throttle：防 spam 双 tap 发重复 onSeat
        guard !isBusyApplyMic else {
            AppLogger.party.notice("[PartyStore] applyMic skip: busy")
            return
        }
        guard let info = roomInfo, roomState == .joined else { return }
        // 30s 冷却：拒后再次点空位 → toast + 不发接口（spec §2 R8）
        if let rejectedAt = myApplyInfo.rejectedAt,
           Date().timeIntervalSince(rejectedAt) < 30 {
            AppLogger.party.notice("[PartyStore] applyMic blocked by 30s cooldown")
            lastError = .underlying(.business(code: "MIC_APPLY_COOLDOWN", message: L10n.Party.micApplicationRejectedCooldown))
            return
        }
        isBusyApplyMic = true
        defer { isBusyApplyMic = false }

        do {
            _ = try await PartyAPI.onSeat(
                roomId: info.id ?? "",
                seatIndex: seatIndex,
                yxRoomId: info.yxRoomId ?? "",
                roomTempId: info.roomTempIdInt
            )
            // 分流：本地暂标 inIndex = 请求 seatIndex；后续 IM 1001（直接上麦）或 1018 op=1（真入队）分流
            myApplyInfo.inIndex = seatIndex
            AppLogger.party.info("[PartyStore] applyMic ok seatIndex=\(seatIndex, privacy: .public); waiting IM to disambiguate")
            startApplyingTimeoutTask()
        } catch let api as PartyAPIError {
            let mapped = PartyRoomErrorMapper.map(api)
            lastError = mapped
            AppLogger.party.error("[PartyStore] applyMic failed: \(String(describing: api), privacy: .private)")
        } catch {
            lastError = .underlying(.networkError)
        }
    }

    /// 观众端放弃排麦（spec §2）。成功后本地清 inIndex + 停超时 Task。
    func cancelMyMicApplication() async {
        guard !isBusyCancelMyMicApplication else {
            AppLogger.party.notice("[PartyStore] cancelMyMicApplication skip: busy")
            return
        }
        guard let info = roomInfo, myApplyInfo.inIndex > 0 else { return }
        isBusyCancelMyMicApplication = true
        defer { isBusyCancelMyMicApplication = false }
        do {
            try await PartyAPI.giveUpQueueSeat(
                roomId: info.id ?? "",
                yxRoomId: info.yxRoomId ?? ""
            )
            myApplyInfo.inIndex = 0
            applyingTimeoutTask?.cancel()
            applyingTimeoutTask = nil
            AppLogger.party.info("[PartyStore] cancelMyMicApplication ok")
        } catch {
            AppLogger.party.error("[PartyStore] giveUpQueueSeat failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// 房主/房管批准申请（spec §2）。seatIndex nil 时挑首空位（排除 pendingApproveSeatIndex 防并发冲突）。
    /// 无可用位 → toast + 不调接口（spec §2 R7）。
    func agreeMicApplication(userId: String, seatIndex: Int?) async {
        // spec §0 throttle（per-userId）：同一申请者防连点重复批准；不同 userId 允许并发（seat 占位靠 pendingApproveSeatIndex）
        guard !pendingApproveUserId.contains(userId) else {
            AppLogger.party.notice("[PartyStore] agreeMic skip: userId=\(userId, privacy: .public) already in-flight")
            return
        }
        guard let info = roomInfo, roomState == .joined else { return }
        // 目标 seatIndex：外部指定优先；否则挑首空位排除已占位
        let targetIndex: Int
        if let idx = seatIndex {
            targetIndex = idx
        } else if let idx = firstAvailableSeatIndexExcludingPending() {
            targetIndex = idx
        } else {
            AppLogger.party.notice("[PartyStore] agreeMic no available seat")
            lastError = .underlying(.business(code: "MIC_NO_SEAT", message: L10n.Party.micApplicationNoSeatAvailable))
            return
        }

        // 占位
        pendingApproveUserId.insert(userId)
        pendingApproveSeatIndex.insert(targetIndex)
        defer {
            pendingApproveUserId.remove(userId)
            pendingApproveSeatIndex.remove(targetIndex)
        }

        do {
            try await PartyAPI.agreeSeat(
                roomId: info.id ?? "",
                seatIndex: targetIndex,
                targetUserId: userId,
                operatorType: 1,  // 内圈硬编 1（房主）；房管路径中圈 TODO
                roomTempId: info.roomTempIdInt,
                yxRoomId: info.yxRoomId ?? ""
            )
            AppLogger.party.info("[PartyStore] agreeSeat ok user=\(userId, privacy: .public) seat=\(targetIndex, privacy: .public)")
            // 服务端下发 1018 op=2（出队）+ 1001/1012（麦位刷新）组合，本地不乐观更新
        } catch let api as PartyAPIError {
            AppLogger.party.error("[PartyStore] agreeSeat failed: \(String(describing: api), privacy: .private)")
            lastError = PartyRoomErrorMapper.map(api)
        } catch {
            lastError = .underlying(.networkError)
        }
    }

    /// 房主/房管拒绝申请（spec §2）。服务端下发 1018 op=3 → 被拒者本地设 rejectedAt 冷却。
    func refuseMicApplication(userId: String) async {
        guard !isBusyRefuseMicApplication else {
            AppLogger.party.notice("[PartyStore] refuseMic skip: busy")
            return
        }
        guard let info = roomInfo, roomState == .joined else { return }
        isBusyRefuseMicApplication = true
        defer { isBusyRefuseMicApplication = false }
        do {
            try await PartyAPI.refuseQueueSeat(
                roomId: info.id ?? "",
                targetUserId: userId,
                yxRoomId: info.yxRoomId ?? ""
            )
            AppLogger.party.info("[PartyStore] refuseQueueSeat ok user=\(userId, privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyStore] refuseQueueSeat failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// 房主切换 Mic Application 开关（spec §2）。isBusy 幂等。
    /// UI 层负责前置协议弹窗（首次切换时基于 autoEnter{On,Off}Application flag 判断）。
    /// 成功后**不本地乐观更新** `micApplicationSwitchOn`——等 1021 广播到达统一同步（避免与观众端不一致）。
    func toggleMicApplicationSwitch(enable: Bool) async {
        guard !isBusyMicSwitch else {
            AppLogger.party.notice("[PartyStore] toggleMicApplicationSwitch skip: busy")
            return
        }
        guard let info = roomInfo, roomState == .joined else { return }
        isBusyMicSwitch = true
        defer { isBusyMicSwitch = false }

        do {
            try await PartyAPI.updateOnSeatEnable(roomId: info.id ?? "", enable: enable ? 1 : 0)
            AppLogger.party.info("[PartyStore] updateOnSeatEnable ok enable=\(enable, privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyStore] updateOnSeatEnable failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    // MARK: - Blocklist (E spec §3)

    /// 拉取房间黑名单列表（房主/房管）。
    /// - `.initial`：首次开面板 → `.loading`
    /// - `.refresh`：下拉刷新 → 有 items 时保留视觉走 `.refreshing(items)`（list-refresh-preserve-items rule）
    ///
    /// roomId 传业务 db id（H5 `currentPartyInfo.id`，非云信 yxRoomId；spec §0 校验 point 7）。
    /// `roomInfo.id` 是 String? —— 转 Int64 传后端；转失败静默降为 error 态（防 crash）。
    ///
    /// spec §3：`loadBlocklistTask` cancel 上一次未完成的拉取，防 sheet 快关快开时旧 API cancel
    /// 抛错走 catch 分支污染新 sheet 状态（verify P1 #3 PLAUSIBLE）。CancellationError 静默丢弃。
    func loadBlocklist(reason: PartyBlocklistLoadReason) async {
        guard let info = roomInfo, roomState == .joined else { return }
        guard let idStr = info.id, let roomIdInt = Int(idStr) else {
            AppLogger.party.error("[PartyStore] loadBlocklist bad roomId=\(info.id ?? "nil", privacy: .public)")
            blocklistState = .error(L10n.Party.errorNetworkLost)
            return
        }

        // Cancel 上一个未完成 load Task，避免竞态（verify P1 #3）
        loadBlocklistTask?.cancel()

        // list-refresh-preserve-items rule：refresh 时保留视觉
        switch (reason, blocklistState) {
        case (.refresh, .loaded(let old)):
            blocklistState = .refreshing(old)
        case (.refresh, .refreshing(let old)):
            blocklistState = .refreshing(old)
        default:
            blocklistState = .loading
        }

        let task = Task { [weak self] () -> Result<[PartyBlocklistItem], Error> in
            do {
                let items = try await PartyAPI.getKickOutBlacklist(roomId: roomIdInt)
                try Task.checkCancellation()
                _ = self
                return .success(items)
            } catch {
                return .failure(error)
            }
        }
        loadBlocklistTask = task
        // 记录本次 Task 生成时的 state 序列号，便于后续判断"是否为最新"
        // Task 是 struct 不能用 === 比对；改用 Task.isCancelled 判定即可 —— 被 cancel 就丢弃结果
        let outcome = await task.value
        // 若本 task 已被更新的 load cancel（外层 cancel），outcome 是 CancellationError
        // 走下面 CancellationError 静默丢弃分支即可

        switch outcome {
        case .success(let items):
            if items.isEmpty {
                blocklistState = .empty
            } else {
                blocklistState = .loaded(items)
            }
            AppLogger.party.info("[PartyStore] getKickOutBlacklist ok count=\(items.count, privacy: .public)")
        case .failure(let error):
            // CancellationError 静默丢弃（旧 Task 被 cancel）—— 不覆盖新 state
            if error is CancellationError {
                AppLogger.party.info("[PartyStore] loadBlocklist cancelled (superseded)")
                return
            }
            AppLogger.party.error("[PartyStore] getKickOutBlacklist failed: \(String(describing: error), privacy: .private)")
            blocklistState = .error(L10n.Party.errorNetworkLost)
        }
    }

    /// list-refresh-preserve-items rule：`.refreshable` closure 必须 await 到任务完成，
    /// 否则顶部 spinner 立即消失。
    func refreshBlocklist() async {
        await loadBlocklist(reason: .refresh)
    }

    /// 解除封禁（房主/房管操作，spec §3）。
    /// - per-userId 幂等：`isBusyRemoveBlocklist` set 拦截同 userId 快速连点（spec §4 R3）
    /// - 成功后**乐观本地 filter** —— 无 IM 广播（spec §2），其他管理员端下次刷新才同步
    /// - 失败抛 throws 让 view 层做 error toast（与 H5 差异化：H5 无差别弹成功，spec §0 校验 point 6）
    func removeFromBlocklist(userId: String) async throws {
        // per-userId 幂等
        guard !isBusyRemoveBlocklist.contains(userId) else {
            AppLogger.party.notice("[PartyStore] removeFromBlocklist skip: userId=\(userId, privacy: .public) in-flight")
            return
        }
        guard let info = roomInfo, roomState == .joined else {
            // spec §4 R2：失败必走 error toast —— throw 而非静默 return，防 sheet 层
            // try await 认为成功误弹"解除成功"toast（verify P1 #2 CONFIRMED）
            AppLogger.party.notice("[PartyStore] removeFromBlocklist not joined; throw to view")
            throw PartyAPIError.networkError
        }
        guard let idStr = info.id, let roomIdInt = Int(idStr) else {
            AppLogger.party.error("[PartyStore] removeFromBlocklist bad roomId=\(info.id ?? "nil", privacy: .public)")
            throw PartyAPIError.networkError
        }

        isBusyRemoveBlocklist.insert(userId)
        defer { isBusyRemoveBlocklist.remove(userId) }

        do {
            let ok = try await PartyAPI.removeKickOutBlacklist(roomId: roomIdInt, targetUserId: userId)
            guard ok else {
                AppLogger.party.error("[PartyStore] removeKickOutBlacklist returned false userId=\(userId, privacy: .public)")
                throw PartyAPIError.networkError
            }
            // 乐观本地 filter：从 loaded/refreshing 里剔除该 userId；空则转 .empty
            switch blocklistState {
            case .loaded(let items):
                let next = items.filter { $0.userId != userId }
                blocklistState = next.isEmpty ? .empty : .loaded(next)
            case .refreshing(let items):
                let next = items.filter { $0.userId != userId }
                blocklistState = next.isEmpty ? .empty : .refreshing(next)
            default:
                break
            }
            AppLogger.party.info("[PartyStore] removeKickOutBlacklist ok userId=\(userId, privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyStore] removeKickOutBlacklist failed: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    // MARK: - Lock Room (E spec §3 Lock Room)

    /// 房主加锁房间（spec §3）。isBusy 幂等；成功后本地乐观回写 `lockFlag=1`。
    /// - 前端拦截：密码固定 4 位纯数字（对齐 H5 `van-password-input length=4`）
    /// - 无 IM 广播：加锁瞬间已在房观众不 kick（对齐 H5）；跨端一致靠 `enterRoom` 拦截返 10006
    /// - 失败 sheet 层需保持打开让用户可重试 → 错误通过 `lastError` 上抛让 view 层 toast
    func lockRoom(password: String) async {
        guard !isBusyLockRoom else {
            AppLogger.party.notice("[PartyStore] lockRoom skip: busy")
            return
        }
        guard let info = roomInfo, roomState == .joined else {
            AppLogger.party.notice("[PartyStore] lockRoom skip: not joined")
            return
        }
        // 前端拦截：4 位纯数字（H5 van-password-input length=4 兜底；UI 层 button.disabled 已挡）
        guard password.count == 4, password.allSatisfy(\.isNumber) else {
            AppLogger.party.notice("[PartyStore] lockRoom skip: password format invalid")
            return
        }
        guard let roomId = info.id, !roomId.isEmpty else {
            AppLogger.party.error("[PartyStore] lockRoom bad roomId")
            lastError = .underlying(.networkError)
            return
        }
        isBusyLockRoom = true
        defer { isBusyLockRoom = false }

        do {
            // 密码明文不落日志（安全）—— 仅记 roomId
            try await PartyAPI.lockRoom(roomId: roomId, password: password)
            // 乐观本地回写：lockFlag=1 + needPassword=true；下次 refresh 由服务端字段自然收敛
            roomInfo = info.withUpdated(lockFlag: 1, needPassword: true)
            AppLogger.party.info("[PartyStore] lockRoom ok roomId=\(roomId, privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyStore] lockRoom failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// 房主解锁房间（spec §3）。isBusy 幂等；成功后本地乐观回写 `lockFlag=0`。
    /// - 无二次确认：tap Lock Room 已锁态 → 直接调（对齐 H5 无二次确认弹窗）
    /// - 无密码字段：对齐 H5 `feachLockRoom({ lockFlag: 0 })` payload 省略 password
    func unlockRoom() async {
        guard !isBusyLockRoom else {
            AppLogger.party.notice("[PartyStore] unlockRoom skip: busy")
            return
        }
        guard let info = roomInfo, roomState == .joined else {
            AppLogger.party.notice("[PartyStore] unlockRoom skip: not joined")
            return
        }
        guard let roomId = info.id, !roomId.isEmpty else {
            AppLogger.party.error("[PartyStore] unlockRoom bad roomId")
            lastError = .underlying(.networkError)
            return
        }
        isBusyLockRoom = true
        defer { isBusyLockRoom = false }

        do {
            try await PartyAPI.lockRoom(roomId: roomId, password: nil)
            // 乐观本地回写：lockFlag=0 + needPassword=false
            roomInfo = info.withUpdated(lockFlag: 0, needPassword: false)
            AppLogger.party.info("[PartyStore] unlockRoom ok roomId=\(roomId, privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyStore] unlockRoom failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    // MARK: - MC Seat (E spec §3 MC Seat, 2026-07-14)

    /// 房主/房管设置接待位（E spec §3）。
    /// - 权限：Owner / PlatformAdmin（UI 层 tools sheet 已门控；后端强校验）
    /// - 幂等：`isBusyMCSeat` 房间级（set + close 共用；防 set A + set B / set + close race）
    /// - 成功后**不本地乐观更新**，等 IM 1001 广播回来自然刷新 seatList
    /// - **返回 Bool 明示成功/失败** —— verify P0 fix：sheet 用来做 toast 判定，
    ///   不再 lastError.localizedDescription diff（同错误消息连续两次会误判成功）
    @discardableResult
    func setMCSeat(seatIndex: Int) async -> Bool {
        guard !isBusyMCSeat else {
            AppLogger.party.notice("[PartyStore] setMCSeat skip: busy")
            return false
        }
        guard let info = roomInfo, roomState == .joined else {
            AppLogger.party.notice("[PartyStore] setMCSeat skip: not joined")
            return false
        }
        guard let roomId = info.id, !roomId.isEmpty else {
            AppLogger.party.error("[PartyStore] setMCSeat bad roomId")
            lastError = .underlying(.networkError)
            return false
        }
        isBusyMCSeat = true
        defer { isBusyMCSeat = false }
        do {
            try await PartyAPI.setMCSeat(
                roomId: roomId,
                seatIndex: seatIndex,
                yxRoomId: info.yxRoomId ?? "",
                roomTempId: info.roomTempIdInt
            )
            AppLogger.party.info("[PartyStore] setMCSeat ok seatIndex=\(seatIndex, privacy: .public)")
            return true
        } catch let api as PartyAPIError {
            AppLogger.party.error("[PartyStore] setMCSeat failed: \(String(describing: api), privacy: .private)")
            lastError = PartyRoomErrorMapper.map(api)
            return false
        } catch {
            AppLogger.party.error("[PartyStore] setMCSeat failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying(.networkError)
            return false
        }
    }

    /// 房主/房管关闭接待位（E spec §3）。
    /// - 权限：Owner / PlatformAdmin
    /// - 无二次确认：UI 层 tap ON cell 直接调（对齐 H5 无二次确认弹窗）
    /// - 幂等：与 setMCSeat 共用 `isBusyMCSeat` 房间级（防 set + close race）
    /// - 成功后**不本地乐观更新**，等 IM 1001 广播回来自然刷新 seatList
    /// - **返回 Bool 明示成功/失败**（verify P0 fix）
    @discardableResult
    func closeMCSeat() async -> Bool {
        guard !isBusyMCSeat else {
            AppLogger.party.notice("[PartyStore] closeMCSeat skip: busy")
            return false
        }
        guard let info = roomInfo, roomState == .joined else {
            AppLogger.party.notice("[PartyStore] closeMCSeat skip: not joined")
            return false
        }
        guard let roomId = info.id, !roomId.isEmpty else {
            AppLogger.party.error("[PartyStore] closeMCSeat bad roomId")
            lastError = .underlying(.networkError)
            return false
        }
        isBusyMCSeat = true
        defer { isBusyMCSeat = false }
        do {
            try await PartyAPI.closeMCSeat(
                roomId: roomId,
                yxRoomId: info.yxRoomId ?? "",
                roomTempId: info.roomTempIdInt
            )
            AppLogger.party.info("[PartyStore] closeMCSeat ok roomId=\(roomId, privacy: .public)")
            return true
        } catch let api as PartyAPIError {
            AppLogger.party.error("[PartyStore] closeMCSeat failed: \(String(describing: api), privacy: .private)")
            lastError = PartyRoomErrorMapper.map(api)
            return false
        } catch {
            AppLogger.party.error("[PartyStore] closeMCSeat failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying(.networkError)
            return false
        }
    }

    // MARK: - Mic Application helpers

    /// 挑首空位（排除 `pendingApproveSeatIndex` 已占位），供 `agreeMicApplication` seatIndex=nil 分支用。
    /// nil 表示无可用空位。
    private func firstAvailableSeatIndexExcludingPending() -> Int? {
        for seat in seatList {
            guard let idx = seat.seatIndex, idx > 0 else { continue }
            if seat.occupied { continue }
            if pendingApproveSeatIndex.contains(idx) { continue }
            return idx
        }
        return nil
    }

    /// 观众 applying 超时兜底 Task：5min 无 IM 到达 → 本地自动 giveUp（spec §2 R9）
    private func startApplyingTimeoutTask() {
        // 捕捉本次申请的 inIndex snapshot：5min 后若 IM 到达（批准/拒绝/放弃/直接上麦）已让 inIndex 变化，
        // 则本 Task 视为竞态失败者，静默 no-op（避免与其他路径重复弹 toast）
        let startInIndex = myApplyInfo.inIndex
        applyingTimeoutTask?.cancel()
        applyingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // 竞态判定：inIndex 必须与启动 Task 时一致且 > 0，才是真 timeout
                guard self.myApplyInfo.inIndex == startInIndex, self.myApplyInfo.inIndex > 0 else { return }
                AppLogger.party.notice("[PartyStore] applying 5min timeout, auto giveUp inIndex=\(self.myApplyInfo.inIndex, privacy: .public)")
                Task { [weak self] in
                    await self?.cancelMyMicApplication()
                    await MainActor.run { [weak self] in
                        self?.lastError = .underlying(.business(code: "MIC_APPLY_TIMEOUT", message: L10n.Party.micApplicationTimeoutAutoGiveUp))
                    }
                }
            }
        }
    }
}

// MARK: - Room Mode / Mic Application supporting enums (E v2)

/// `handleRoomModeChanged` 触发源：`.local` 房主 API 成功兜底 / `.remote` 观众端 IM 1017 到达
enum PartyRoomModeChangeCause {
    case local
    case remote
}

/// 排麦申请列表拉取 reason（配合 list-refresh-preserve-items rule）
enum PartyMicApplicationsLoadReason {
    case initial
    case refresh
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

    /// v15 声纹反馈：500ms 一次全量替换 speakingUids；空集合=全体静音。
    /// 用 Set 比较避免不必要的 objectWillChange 触发（同一集合内容不派发）。
    func partyRTCEngine(_ engine: PartyRTCEngine, didUpdateSpeakingUids uids: Set<UInt>) {
        if uids != speakingUids {
            speakingUids = uids
        }
    }
}

// MARK: - v15 声纹派生查询

extension PartyStore {
    /// 判断某个麦位当前是否正在说话（用于 SeatCell isSpeaking 参数派生）。
    /// 对齐 H5 `isVoicePrintFrameActive` 判定（简化版，省略 vfxUrl SVGA）：
    /// 1. seat.userId 存在且能转 UInt
    /// 2. uid 在 speakingUids 集合内（volume>5 阈值过滤后）
    /// 3. 用户自身麦克风开 (microphoneEnabled=1)
    /// 4. 座位未被房管禁麦 (seatMicrophoneEnabled=1)
    /// 缺一即不显示 pulse（H5 语义：静音/禁麦不应显声纹）
    func isSpeaking(seat: PartyRoomSeat) -> Bool {
        guard let uidStr = seat.userId,
              let uid = UInt(uidStr),
              uid > 0 else { return false }
        guard speakingUids.contains(uid) else { return false }
        guard (seat.microphoneEnabled ?? 0) == 1 else { return false }
        guard (seat.seatMicrophoneEnabled ?? 0) == 1 else { return false }
        return true
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
        // spec §0/§1 乱序判丢：切模板成功后 3s 内 1001 广播多为旧数据，直接覆盖会踩到旧 seatList
        if isWithinRoomTempSwitchGuard {
            AppLogger.party.notice("[PartyStore] 1001 dropped by roomTempSwitch 3s guard")
            return
        }
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
        // spec §2 观众端分流：本人出现在 seatList → 真上麦（非入队），清 inIndex + 停 timeout Task
        // 若 5min timeout task 已在跑，本次 IM 到达时手工触发 clearOnDirectOnSeat 避免误 giveUp
        clearApplyingIfDirectOnSeat()
    }

    /// spec §2 观众端分流兜底：本人已进 seatList（真上麦而非入队）时清 myApplyInfo.inIndex + 停 timeout Task。
    /// 由 1001 / 1012 处理路径末尾调用，防 5min timeout task 误触发 giveUp。
    private func clearApplyingIfDirectOnSeat() {
        guard myApplyInfo.inIndex > 0 else { return }
        guard selfSeat != nil else { return }
        AppLogger.party.info("[PartyStore] self on-seat detected while applying (inIndex=\(self.myApplyInfo.inIndex, privacy: .public)); clear + stop timeout Task")
        myApplyInfo.inIndex = 0
        applyingTimeoutTask?.cancel()
        applyingTimeoutTask = nil
    }

    /// spec §0 乱序保护：切模板成功后 3s 内所有 1001/1012 增量广播均视为旧数据丢弃
    /// （容差窗口对齐 §0 二次校验 "3s 容差" 语义；实操简化：不用 msgTimestamp 比对，
    /// 用切模板成功至今的秒数判断，前提是 IM 到达延迟远小于 3s）
    private var isWithinRoomTempSwitchGuard: Bool {
        guard let at = lastRoomTempSwitchAt else { return false }
        return Date().timeIntervalSince(at) < 3.0
    }

    func partyRoomChatDidRequireSeatListReload(_ chat: PartyRoomChatManager) {
        // spec §0/§1 乱序判丢：切模板成功后 3s 内 1012 全量重拉指令多来自旧上下文，丢弃避免覆盖
        if isWithinRoomTempSwitchGuard {
            AppLogger.party.notice("[PartyStore] 1012 dropped by roomTempSwitch 3s guard")
            return
        }
        AppLogger.party.notice("[PartyStore] 1012 require full seatList reload")
        Task { [weak self] in
            await self?.reloadSeatListFromServer()
            await MainActor.run { self?.clearApplyingIfDirectOnSeat() }
        }
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

        // Task 10：接入跨场景礼物特效引擎。payload 可能含 `gifts` 数组（compressed 批量）或单条；
        // GiftEffectIntake.ingest 内部按 giftId 校验，无效字段直接返 false 不打扰。
        let scopeId = roomInfo?.id ?? ""
        let mineYxAccid = SessionStore.shared.user?.yxAccid ?? ""
        if let gifts = payload["gifts"] as? [[String: Any]] {
            for gift in gifts {
                GiftEffectIntake.ingest(scene: .party, scopeId: scopeId, payload: gift, mineYxAccid: mineYxAccid)
            }
        } else {
            GiftEffectIntake.ingest(scene: .party, scopeId: scopeId, payload: payload, mineYxAccid: mineYxAccid)
        }
    }

    /// v23（2026-07-13）派对房用户进场座驾动画 attachType=1004 → EnterEffectCenter 全屏 SVGA/MP4 座驾特效
    /// 对齐直播 NIMChatroomManager v23 解析逻辑（Sources/Live/NIMChatroomManager.swift:693-745）：
    /// payload 结构假设：{ username, icon, userLevel, isVip, activeTycoon, list:[JSON string 含 itemImg] }
    /// - scopeId 与 .enterEffectScene modifier 同源用 roomInfo?.id
    /// - 主播自己进场 filter drop（防御性；派对房主播身份本就不发但保守）
    /// - vehicle URL 后缀 svga/mp4 白名单
    /// - TODO: [im-payload-real-log-over-code-assumption] 真机首次收到 attachType=1004 通过下方 🚗 log
    ///   校对 payloadKeys / dataKeys 真实字段名；当前基于直播 attachType=80 同款 fallback 假设
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveEnterAnimation payload: [String: Any], raw: NIMMessage) {
        // payload 已由 PartyRouter 走 unwrapDataField 解压过（gzip / JSON string 双兼容）
        // 但直播 chatroom attachType=80 的 payload 是 `{ data: {...}, attachType: 80 }` 二级 dict；
        // 派对房走 unwrapDataField 输出结构可能已经是 data 内层——先兼容两种
        var data: [String: Any] = payload
        if let inner = payload["data"] as? [String: Any] {
            data = inner
        }

        // 座驾 URL 提取（data.list[0] 是 JSON string 或 dict）
        var vehicleItemImg: String?
        if let listStr = data["list"] as? [String], let first = listStr.first,
           let d = first.data(using: .utf8),
           let itemDict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            vehicleItemImg = itemDict["itemImg"] as? String
        }
        // dict 数组兜底（部分后端可能不 stringify）
        if vehicleItemImg == nil,
           let listDict = data["list"] as? [[String: Any]], let first = listDict.first {
            vehicleItemImg = first["itemImg"] as? String
        }
        // 平铺字段兜底
        if vehicleItemImg == nil {
            vehicleItemImg = (data["itemImg"] as? String)
                ?? (data["itemSmallImg"] as? String)
                ?? (data["vehicleImg"] as? String)
        }

        // sender / isSelfSent 判定
        let mineYxAccid = SessionStore.shared.user?.yxAccid ?? ""
        let senderAccid = (data["senderYxAccid"] as? String)
            ?? (data["sendYxAccid"] as? String)
            ?? (payload["senderYxAccid"] as? String)
            ?? (payload["sendYxAccid"] as? String)
            ?? ""
        let isSelfSent = !senderAccid.isEmpty
            && !mineYxAccid.isEmpty
            && senderAccid == mineYxAccid

        // info 级 log 默认可见 (对齐 im-payload-real-log rule §首次接入必抓字段名验证)
        AppLogger.party.info("🚗 [Party] enterVehicle payloadKeys=\(Array(payload.keys), privacy: .public) dataKeys=\(Array(data.keys), privacy: .public) vehicle=\(vehicleItemImg ?? "nil", privacy: .public) sender=\(senderAccid, privacy: .public) self=\(isSelfSent, privacy: .public)")

        guard !isSelfSent else { return }
        guard let vehicleUrl = vehicleItemImg,
              let parsed = URL(string: vehicleUrl) else { return }
        let ext = parsed.pathExtension.lowercased()
        guard ext == "svga" || ext == "mp4" else { return }

        // v23（2026-07-13）code-review 修复：scopeId 必须 non-empty。若 roomInfo.id nil（后端 partial payload
        // 极端场景），此消息入队会与 PartyRoomView modifier 挂载的 scopeId (`??roomId`) 不同源 →
        // Center.enqueue rejected 静默 drop → 直接 return 免走无效路径。
        guard let scopeId = roomInfo?.id, !scopeId.isEmpty else {
            AppLogger.party.warning("[Party] didReceiveEnterAnimation drop: roomInfo.id nil/empty — partial payload?")
            return
        }
        let nickname = (data["username"] as? String)
            ?? (data["nickname"] as? String)
            ?? (data["nick"] as? String)
            ?? ""
        let avatar = (data["icon"] as? String)
            ?? (data["avatar"] as? String)
            ?? (data["headImg"] as? String)

        let item = GiftEffectItem(
            sceneKey: GiftEffectSceneKey(scene: .party, scopeId: scopeId),
            senderYxAccid: senderAccid,
            senderNickname: nickname,
            senderAvatarUrl: avatar,
            giftId: 0,
            giftName: "vehicle",
            giftCount: 1,
            giftPrice: 0,
            animationUrl: vehicleUrl,
            staticImgUrl: nil,
            timestamp: Int64(raw.timestamp * 1000),
            isSelfSent: false
        )
        EnterEffectCenter.shared.enqueue(item)
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveVideoSeatInvite invite: PartyVideoSeatInvite) {
        // 仅当邀请对象是自己（房间匹配）才弹窗——roomId 已在 chat 双过滤；
        // seatIndex 范围由 chat 内 handleVideoSeatInvite 校验过。
        pendingVideoSeatInvite = invite
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveInviteResult result: PartyVideoSeatInviteResult) {
        lastInviteResult = result
    }

    // MARK: - E v2 §1/§2 Room Mode + Mic Application IM 消费

    /// 1017 Room Mode 切模板广播（spec §1）。步骤 1 乱序判丢：msgTimestamp < lastRoomTempSwitchAt-3s → drop
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveModeChange payload: [String: Any], msgTimestampMs: Int64) {
        // 步骤 1：乱序判丢（3s 容差；房主切模板成功后旧 1001/1012 排队晚到）
        if let switchedAt = lastRoomTempSwitchAt {
            let switchedAtMs = Int64(switchedAt.timeIntervalSince1970 * 1000)
            if msgTimestampMs < switchedAtMs - 3000 {
                AppLogger.party.notice("[PartyStore] 1017 dropped by lastRoomTempSwitchAt-3s guard (msgAt=\(msgTimestampMs, privacy: .public) switchedAt=\(switchedAtMs, privacy: .public))")
                return
            }
        }

        // 提取字段（真机 log 验证前先按 spec §1 起草字段名）
        // spec §0 二次校验：payload 只必含 seats/currentSeatIndex/currentUserId/seatOperate，
        // roomTempId 可能不在 payload —— 缺失时不 fallback，继续走 seats + 下麦 + 系统消息全流程，
        // 只跳过 §1 步骤 7 roomInfo.roomTempId 更新（幂等判断失效但不阻塞主路径）
        let newTempIdOpt = PartyValueNormalizer.intify(payload["roomTempId"])

        // 尝试解 seats 数组（若 payload 内含）
        var seats: [PartyRoomSeat]? = nil
        if let arr = payload["seats"] as? [[String: Any]] {
            if let jsonData = try? JSONSerialization.data(withJSONObject: arr),
               let decoded = try? JSONDecoder().decode([PartyRoomSeat].self, from: jsonData) {
                seats = decoded
            } else {
                AppLogger.party.error("[PartyStore] 1017 seats decode failed; will fallback via reload")
            }
        }

        AppLogger.party.info("[PartyStore] 1017 changeMode tempId=\(newTempIdOpt ?? -1, privacy: .public) hasSeats=\(seats != nil, privacy: .public)")
        handleRoomModeChanged(newTempId: newTempIdOpt, seats: seats, cause: .remote)
    }

    /// 1018 排麦通知（spec §2）。4 分支：1=申请 / 2=同意 / 3=拒绝 / 4=放弃
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveQueueSeatUpdate payload: [String: Any], raw: NIMMessage) {
        _ = raw
        let operation = PartyValueNormalizer.intify(payload["operation"]) ?? 0
        let num = PartyValueNormalizer.intify(payload["num"]) ?? 0
        let userId = PartyValueNormalizer.stringify(payload["userId"]) ?? ""
        queueSeatNum = num

        let mine = (myUserIdString ?? "") == userId && !userId.isEmpty

        switch operation {
        case 1:
            // 申请：非本人 → 面板已开就重拉（保留旧视觉 refresh）；本人不动 inIndex（本地 applyMic 已设）
            if !mine {
                // 面板 open 状态：micApplicationsState 已经是 loaded/empty/refreshing 之一
                let panelOpen: Bool
                switch micApplicationsState {
                case .loaded, .empty, .refreshing, .error: panelOpen = true
                case .idle, .loading: panelOpen = false
                }
                if panelOpen {
                    Task { [weak self] in await self?.refreshMicApplications() }
                }
            }
            AppLogger.party.info("[PartyStore] 1018 op=1 apply user=\(userId, privacy: .public) mine=\(mine, privacy: .public) num=\(num, privacy: .public)")
        case 2:
            // 同意：申请者被批准出队 → 面板 splice；本人则清 inIndex + 停 Task
            spliceMicApplicationsRecord(userId: userId)
            if mine {
                myApplyInfo.inIndex = 0
                applyingTimeoutTask?.cancel()
                applyingTimeoutTask = nil
            }
            AppLogger.party.info("[PartyStore] 1018 op=2 agree user=\(userId, privacy: .public) mine=\(mine, privacy: .public)")
        case 3:
            // 拒绝：面板 splice；本人则清 inIndex + 停 Task + 设 rejectedAt 冷却 + toast
            spliceMicApplicationsRecord(userId: userId)
            if mine {
                myApplyInfo.inIndex = 0
                myApplyInfo.rejectedAt = Date()
                applyingTimeoutTask?.cancel()
                applyingTimeoutTask = nil
                lastError = .underlying(.business(code: "MIC_APPLY_REJECTED", message: L10n.Party.micApplicationRejectedByHost))
            }
            AppLogger.party.info("[PartyStore] 1018 op=3 refuse user=\(userId, privacy: .public) mine=\(mine, privacy: .public)")
        case 4:
            // 放弃：面板 splice；本人 giveUp 已在 cancelMyMicApplication 里清过 inIndex，这里幂等
            spliceMicApplicationsRecord(userId: userId)
            if mine {
                myApplyInfo.inIndex = 0
                applyingTimeoutTask?.cancel()
                applyingTimeoutTask = nil
            }
            AppLogger.party.info("[PartyStore] 1018 op=4 giveUp user=\(userId, privacy: .public) mine=\(mine, privacy: .public)")
        default:
            AppLogger.party.notice("[PartyStore] 1018 unknown operation=\(operation, privacy: .public) num=\(num, privacy: .public)")
        }
    }

    /// 1021 Mic Application 开关广播（spec §2）。同步 `micApplicationSwitchOn` + 公屏系统消息。
    /// 关闭时若面板打开 → 顺手切回 empty（体验：状态清空避免观众卡在旧列表上）
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveMicApplicationSwitch payload: [String: Any], raw: NIMMessage) {
        _ = raw
        let enable = PartyValueNormalizer.intify(payload["enable"]) ?? 0
        let on = (enable == 1)
        micApplicationSwitchOn = on
        AppLogger.party.info("[PartyStore] 1021 micApplicationSwitch enable=\(enable, privacy: .public)")

        // 关时顺手关面板旧列表（避免观众端卡在旧数据）
        if !on {
            micApplicationsState = .empty
            queueSeatNum = 0
        }

        // 公屏系统消息
        chatRouter.postSystemMessage(on
            ? L10n.Party.micApplicationSwitchOnSystemMsg
            : L10n.Party.micApplicationSwitchOffSystemMsg
        )
    }

    /// 从 `micApplicationsState` 已加载列表里 splice 掉指定 userId（1018 op=2/3/4 触发）
    private func spliceMicApplicationsRecord(userId: String) {
        guard !userId.isEmpty else { return }
        let updated: (([PartyMicApplication]) -> [PartyMicApplication]) = { list in
            list.filter { $0.userId != userId }
        }
        switch micApplicationsState {
        case .loaded(let items):
            let next = updated(items)
            micApplicationsState = next.isEmpty ? .empty : .loaded(next)
        case .refreshing(let items):
            let next = updated(items)
            // refreshing 是刷新中间态，splice 后 loader 完成时会覆盖，这里保持 refreshing 视觉
            micApplicationsState = next.isEmpty ? .empty : .refreshing(next)
        default:
            // idle / loading / empty / error 无需 splice
            break
        }
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
