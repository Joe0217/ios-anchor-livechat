import Combine
import AVFoundation
import Foundation
import NIMSDK
import SwiftUI  // @AppStorage（E v2 §3 partySaveInfo.autoEnter{On,Off}Application 本地持久化）

/// 主 Tab 壳的小窗窄观察源。避免主壳直接订阅 PartyStore 的麦位/公屏等高频状态。
@MainActor
final class PartyMinimizedBridge: ObservableObject {
    @Published fileprivate(set) var isVisible = false
    @Published fileprivate(set) var roomAvatarURL: String?

    func show(roomAvatarURL: String?) {
        self.roomAvatarURL = roomAvatarURL
        isVisible = true
    }

    func hide() {
        isVisible = false
        roomAvatarURL = nil
    }
}

/// 派对房全局房间状态（spec §1.4.2 + §1.4.5 + §1.4.6）。
///
/// 对齐安卓 `PartyRoomDataManager`，但**职责仅限房间状态**——拆分三对象避免巨石（spec §1.0.2）：
/// - `PartyStore`：房间信息 / 麦位 / 在线人数 / 送礼事件 / 进出房编排
/// - `PartyRTCEngine`：声网封装
/// - `PartyRoomChatManager`：NIM 公屏 + attachType 分发
///
/// 单例语义（一次只能在一个房）；多次进退房会先 `forceLeaveRoom(.userRequest)` 清残留。
/// **禁止字段**：`weak var liveStore`（spec §1.0.3 验证；E 期完全不与 B 耦合）。
///
/// **F 期铁律修订**（F-PartyCall-spec §0.4 P0-3）：
/// - 保留：禁止 `weak var liveStore` 直接引用直播 store
/// - 修订：允许 conform `CallStoreObserver` + 通过 `CallStore.shared.attach/detach` 观察通话事件
///   （不使用 `weak var callStore` 字段，仍避免强 store-to-store 耦合；通过 P0-2 多观察者数组解耦）
@MainActor
final class PartyStore: ObservableObject {
    static let shared = PartyStore()
    let minimizedBridge = PartyMinimizedBridge()

    // MARK: - 状态字段

    @Published private(set) var roomInfo: PartyRoomInfo?
    /// 麦位列表。F 期麦时统计 didSet：`selfSeat` 从无到有触发 `onMikeStartTime = now`；
    /// 从有到无触发 `accumulatedMikeSeconds += now - onMikeStartTime`（对齐蓝本 02-04 §2.6
    /// mOnMikeStartTime 语义 —— 上麦/下麦/被抱下/切模版/退房/被踢全靠 seatList 变更承接）。
    @Published private(set) var seatList: [PartyRoomSeat] = [] {
        didSet {
            giftEffects.updateVisibleRecipientIds(Set(seatList.compactMap(\.userId)))
            trackMikeTimeIfNeeded(previous: oldValue)
        }
    }
    @Published private(set) var onlineUserCount: Int = 0
    @Published private(set) var isJoinedChannel: Bool = false   // RTC joined
    @Published private(set) var imAlive: Bool = false           // NIM chatroom enterOK
    @Published private(set) var lastGiftEvent: PartyGiftEvent?
    /// 1014 鉴黄告警。非 nil 时房间页展示提示；带时长的禁令会先强制本人下麦。
    @Published private(set) var partyAuditWarningMessage: String?
    /// attachType 197 首礼时刻顶部飘屏队列（与 H5 Party `firstGiftFloatList` 对齐）。
    let firstGiftFloatQueue = FirstGiftFloatQueue()
    /// 1052 幸运数字中奖个人弹窗；只在当前 Party 房已加入且房间匹配时写入。
    @Published private(set) var luckyNumberWinPayload: PartyLuckyNumberWinPayload?
    /// Party 房静态礼物效果专用状态机；SVGA/MP4 仍由 GiftEffectCenter 跨场景播放。
    let giftEffects = PartyGiftEffectCoordinator.shared
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
    /// 1024 在当前 Party 会话内覆盖进房响应里的平台管理员标志。
    /// nil 表示尚未收到变更，继续使用 `roomInfo.isPlatformAdmin`。
    @Published private var platformAdminOverride: Bool?
    /// 房间内角色的实时覆盖。setAdmin 成功响应与 1019 广播都会写入，
    /// 使未上麦用户也能立刻反映管理员任免，不必等待详情接口或下一次全量座位广播。
    @Published private var partyRoleOverrides: [String: PartyRoomRoleType] = [:]
    private var pendingAdminUserIds: Set<String> = []
    private var partyAuditWarningDismissTask: Task<Void, Never>?
    /// H5 Party 小窗态：仅卸载房间页面，不离开 RTC/NIM 聊天室；主壳展示悬浮球供恢复或退出。
    @Published private(set) var isMinimized: Bool = false
    /// Party 会话持有一次自动离线暂停，避免小窗恢复时因视图重新出现重复 suspend。
    private var isAutoOfflineMonitorSuspended = false
    @Published private(set) var pendingVideoSeatInvite: PartyVideoSeatInvite?
    @Published private(set) var lastInviteResult: PartyVideoSeatInviteResult?
    @Published private(set) var lastError: PartyRoomError?

    /// 密码房预校验成功后的单次 enter 响应。列表页必须在 push 前完成密码校验；
    /// PartyRoomView 随后消费此响应继续 RTC/NIM 入房，避免对 `/room/enter` 重复请求。
    private var prevalidatedRoomEntry: (roomId: String, info: PartyRoomInfo)?
    /// 每次入房分配独立 generation。退房期间 HTTP 回包可能迟到，必须先作废旧 generation，
    /// 否则旧回包会在已退出后重新写入 roomInfo 并启动 RTC/NIM。
    private var roomEntryGeneration: UInt = 0
    private var pendingRoomEntryId: String?
    /// 入房来源只由路由写入；成功埋点在 RTC/NIM 双就绪后读取，避免把点击误记为入房成功。
    private var currentEntryPath: PartyRoomEntryPath = .standard
    /// 仅在正式 joined 后赋值，用于离房时长与跨多次 leave 调用的去重。
    private var partyJoinedAt: Date?
    /// 设备权限不足时由 PartyRoomView 弹窗；确认成功后继续用户原本的上麦/开媒体动作。
    @Published var mediaPermissionAlertRequirement: MediaPermissionGate.Requirement?
    private var pendingMediaPermissionAction: (() async -> Void)?
    /// H5 同款视频位邀请 30 秒冷却，防止对同一普通用户重复发送 1040。
    private var videoSeatInviteCooldowns: [String: Date] = [:]

    /// 是否已关注当前房主（对齐 H5 `currentPartyInfo.isFollowOwner`）。
    /// 进房时初始化自 `roomInfo.isFollowOwner`；`toggleFollowAnchor()` 后翻转。
    @Published private(set) var isFollowingAnchor: Bool = false
    /// 关注切换请求是否在飞（防连点重复请求）
    @Published private(set) var isTogglingFollow: Bool = false
    /// 名片卡/个人页等外部入口成功关注后，按 userId 同步当前房主的顶部关注态。
    private var followRelationObserver: NSObjectProtocol?

    /// v12：房主头像装饰框 URL（对齐 H5 `ownerInfo.headFrame` = `apiPartyGetUser.headFrameSmallImg`）。
    /// enterRoom 完成后 async 拉；`.svga` 结尾 iOS 暂 fallback 到无装饰（G/H 期接 SVGA 播放器）。
    @Published private(set) var ownerHeadFrameURL: String?
    private var didLoadOwnerInfo = false

    /// v15 声纹反馈：正在说话的 Agora uid 集合（对齐 H5 `volumeList`）。
    /// 数据源：Agora 本地/远端音量回调先在 RTC 层合并 → 阈值 volume>5 → 500ms 更新。
    /// UI 层：`isSpeaking(seat:)` 派生,seat.userId String → UInt 转换后查集合命中。
    @Published private(set) var speakingUids: Set<UInt> = []

    /// 主播端 Party 右下角半屏游戏 Banner（使用 anchor 游戏池）。
    @Published private(set) var partyBannerGames: [PartyBannerGame] = []
    private var partyBannerGamesEpoch = 0

    /// H5 `highLevelUserEnterRoomList` 的当前进场条。由聊天室成员进入通知的
    /// `notificationExtension` 驱动，座驾用户不进入此队列。
    @Published private(set) var enterFloatingMessage: PartyEnterFloatingMessage?
    private var enterFloatingQueue: [PartyEnterFloatingMessage] = []
    private var enterFloatingTask: Task<Void, Never>?
    private let enterFloatingQueueLimit = 20

    /// v16.4 房间背景（房主设置的自定义背景）。
    /// **重要**：enterRoom response 里的 bigImgUrl / bgImgUrl 通常为 null（后端不在 enter 返），
    /// 需要独立调 `getRoomBgImage` 接口拉当前房间已设背景。
    /// 更新时机：enterRoom 成功后主动拉；F 期可加 IM 1025 广播实时刷新。
    @Published private(set) var currentRoomBackground: PartyBackground?

    /// v18：`loadCurrentRoomBackground` / `updateCurrentRoomBackground` 竞态守卫。
    /// 每次外部主动 update（Settings 层回流）或 leave 时 &+= 1；载入前后对比 → mismatch 丢写。
    /// 防两种真机可复现的 race：
    /// 1. load 首个 await 后用户在 Settings 选了新背景 → 后续 await 拿到旧 idOnly → match 后覆写用户新选（真机可 100% 复现）
    /// 2. 房间 A 进房 → load 起 → 用户切到房间 B → A 的 load stale resume 后写入 B 的 store
    /// 会话级、单调递增；session 生命周期内不需要重置。
    private var backgroundEpoch: Int = 0
    /// v18：会话级缓存 backgroundList（近似静态目录，进房不再重拉整份）
    private var backgroundListCache: [PartyBackground]?

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
    /// 音乐的实际启用状态。`roomMusicSwitc` 仅表示该房支持音乐，不能用于展示 ON/OFF。
    @Published private(set) var isRoomMusicEnabled: Bool = false
    /// H5 `currentMusicInfo` 的单一真值，供右下角音乐组件和管理面板共同观察。
    @Published private(set) var roomMusicSettings: PartyMusicSettings = .empty
    /// 普通用户本地的音乐收听开关（H5 `userMusicSwitch`）；不影响其他麦位声音。
    @Published private(set) var isRoomMusicAudible: Bool = true
    /// 队列总长度（1018 payload num 消费；用于外部 badge/系统消息计数）
    @Published private(set) var queueSeatNum: Int = 0
    /// 观众端 "我的申请"（inIndex 排队位序 + rejectedAt 30s 冷却）
    @Published private(set) var myApplyInfo: PartyMyApplyInfo = .init()
    /// agreeSeat 并发占位集合：房主快速批准两申请时排除已挑走的 seatIndex 防冲突（spec §2 R6）
    private var pendingApproveSeatIndex: Set<Int> = []
    /// 只读快照供 UI 选座 sheet 过滤已挑走的位（对齐安卓 SeatRosterDialog 排除同时批准冲突）
    var pendingApproveSeatIndexSet: Set<Int> { pendingApproveSeatIndex }
    /// applying 超时兜底 Task：inIndex > 0 持续 5min 无 IM → 本地自动 giveUp（spec §2 R9）
    private var applyingTimeoutTask: Task<Void, Never>? = nil
    /// 开关 API 幂等 flag（防连点，与 Confirm 分开 flag 隔离）
    private var isBusyMicSwitch: Bool = false
    private var isBusyRoomMusicSwitch: Bool = false
    private var isBusyRoomMusicControl: Bool = false
    @Published private(set) var isUploadingRoomMusic: Bool = false
    /// spec §0 throttle：所有 Mic Application 类 mutating async 用 isBusy flag 幂等（防 spam 双请求）
    private var isBusyApplyMic: Bool = false
    private var isBusyCancelMyMicApplication: Bool = false
    /// 对齐 approve 路径 per-userId 幂等（房主快速拒绝 A/B 两条时不阻塞跨 userId）
    private var isBusyRefuseUserIds: Set<String> = []
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

    /// F 期房主管理批（2026-07-17）：房间通告编辑防连点 flag。
    /// - 幂等：`updateAnnouncement` 期间二次调用直接短路返回 false
    /// - 权限：selfRole == .owner（平台超管已在 selfRole 层提权，无需额外判 isPlatformAdmin）
    private var isBusyAnnouncement: Bool = false

    /// F 期便利功能（2026-07-17）Room Mute 全房静音状态。
    /// - 本地状态，非服务端字段（Agora `adjustPlaybackSignalVolume` 是本端 SDK 行为）
    /// - 退房 resetState 归 false；不需持久化（每次进房从默认状态开始)
    @Published private(set) var isRoomMuted: Bool = false
    /// H5 `partyBaseConfig.kickOutInterval` 的小时显示值；未加载时为 0，名片卡只提供永久踢出。
    @Published private(set) var kickOutHours: Int = 0

    // MARK: - Expression / Emoji Panel (F 里程碑 · 2026-07-17)

    /// 表情面板分类 list 加载状态机。
    /// - 首次面板 onAppear 拉一次；`.loaded` 后不重拉（面板反复开关不重复请求）
    /// - error 态面板中央显 retry 按钮
    /// - 退房 resetState 归 idle（不清 loaded 数据 · 表情列表跨房通用 · 但状态机重置避免 UI 残留）
    @Published private(set) var expressionListState: PartyEmojiListState = .idle

    /// 麦位 SVGA 播放队列（key = 发送者 sendUserId · 值 = 该麦位待播 emoji 列表）。
    /// - **同一麦位串行播放**：SVGA player onFinish → `dequeueEmoji(seatUserId:)` 弹队首
    /// - **跨麦位并行**：多个 seat 同时收到 -10/-11 → 分别独立 enqueue 并行播
    /// - **队列上限 20**：对齐 H5 `QUEUE_MAX_SIZE = 20`（`usePartyHooks.js` · `party-expression-popup.vue`）·
    ///   超上限 shift 队首（防单麦位刷屏 SVGA 引起内存/GPU 压力）
    /// - 退房 resetState 清空
    @Published private(set) var emojiQueueMap: [String: [PartyEmojiPayload]] = [:]

    /// 单麦位 emoji 队列上限（对齐 H5 `QUEUE_MAX_SIZE = 20`）
    private let emojiQueueMaxSize: Int = 20

    /// `loadExpressionList` in-flight 防连点（首次面板 onAppear 期间 tab 切换/快速开关不重复请求）
    private var isLoadingExpressionList: Bool = false

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
    /// 本地主动下麦后，服务端 seatList 尚未同步（或 downSeat 失败）期间不能由旧数据重新打开媒体。
    @Published private var isLocalSeatExitPending = false
    /// 用户主动关闭媒体后保留本地优先级，直到服务端确认下一个麦位状态或用户明确重新开启。
    @Published private var isLocalMicrophoneDisabled = false
    @Published private var isLocalCameraDisabled = false

    // MARK: - F PartyCall 私 call 开关（spec §5.3）

    /// 私 call 开关选中礼物的 icon URL 缓存（浮动按钮开启态 preview 用）。
    /// setPrivateCall(enable=true) 成功时更新；enable=false 时保留（下次打开预选记忆）。
    /// 必须在 class 主体（stored property + property wrapper 不能放 extension）
    @Published private(set) var partyCallGiftIcon: String?
    /// 私 call 开关选中礼物的价格缓存（蓝钻显示用）。
    @Published private(set) var partyCallGiftPrice: Int?
    /// v5-需求 2：私 call 开关切换 API 在飞标志 —— UI 层按钮显示 ProgressView 并屏蔽 tap 防重复点击。
    @Published private(set) var isTogglingPrivateCall: Bool = false
    /// PK 期间私 call 入口必须隐藏；退出 PK 后恢复进入前的开关快照。
    @Published private(set) var partyPrivateCallHiddenForPK: Bool = false
    private var partyPrivateCallWasEnabledBeforePK = false
    private var partyPrivateCallGiftIdBeforePK: String?
    /// PK 开始和结束可能紧邻发生，关闭/恢复请求必须按顺序发送，避免后端最终停在关闭态。
    private var partyPrivateCallPKSyncTask: Task<Void, Never>?
    private var partyPrivateCallPKSyncRevision: UInt = 0

    // MARK: - 衍生

    /// 自己当前所在麦位（衍生：seatList.first { userId == 自己 }）
    var selfSeat: PartyRoomSeat? {
        guard let me = myUserIdString else { return nil }
        return seatList.first { $0.userId == me }
    }

    /// 自己角色（owner / admin / audience）。
    /// 派生顺序：
    /// 1) `roomInfo.isPlatformAdmin==true` → **提权等同房主**（差异文档 §4 明示：seat 侧无 isPlatformAdmin
    ///    字段，超管特权只在 roomInfo 层，若不优先判超管，超管上麦后 selfRole 会退化为麦位真实角色）
    /// 2) `selfSeat.roomRoleType` —— 房主 setRoomAdmin 后 IM 1001 seatList 广播会 update seat.roomRoleType，
    ///    实时反映房管任免（无需重进房）
    /// 3) fallback 到 `roomInfo.selfRoleType(...)` 覆盖未在麦上时的初始状态
    var selfRole: PartyRoomRoleType {
        if isPlatformAdmin { return .owner }
        if let seat = selfSeat,
           let raw = seat.roomRoleType,
           let role = PartyRoomRoleType(rawValue: raw) {
            return role
        }
        return roomInfo?.selfRoleType(myUserId: myUserIdString) ?? .audience
    }

    var isPlatformAdmin: Bool {
        platformAdminOverride ?? roomInfo?.isPlatformAdmin ?? false
    }

    /// 名片卡、榜单等非麦位入口查询目标用户在当前 Party 房的实时角色。
    /// 覆盖值优先于 seatList，避免 setAdmin 成功到服务端座位广播抵达之间显示旧按钮。
    func partyRole(for userId: String) -> PartyRoomRoleType? {
        guard !userId.isEmpty else { return nil }
        return partyRoleOverrides[userId]
            ?? seatList.first(where: { $0.userId == userId })?.typedRole
    }

    /// 设置页的管理员管理与名片卡共用同一实时角色状态；只接受当前已加入房间的回调，
    /// 防止退出后旧设置页的异步完成结果污染下一间房。
    func applyAdminRoleUpdate(roomId: String, userId: String, role: PartyRoomRoleType) {
        guard roomState == .joined, roomInfo?.id == roomId else { return }
        applyPartyRoleUpdate(targetUserId: userId, role: role)
    }

    /// 本人麦克风的有效本地状态：服务端麦位字段 + 本地先行关闭意图。
    /// 普通 toggle 的接口失败时，SDK 可能已按用户意图先关；UI 必须读这里，避免按钮仍显示“关麦”导致无法恢复。
    var effectiveSelfMicrophoneEnabled: Bool {
        guard let me = selfSeat else { return false }
        return (me.microphoneEnabled ?? 0) == 1
            && (me.seatMicrophoneEnabled ?? 0) == 1
            && !isLocalMicrophoneDisabled
            && !isLocalSeatExitPending
    }

    /// 本人摄像头的有效本地状态：服务端 cameraEnabled + 本地先行关闭意图。
    var effectiveSelfCameraEnabled: Bool {
        guard let me = selfSeat, me.seatType == 1 else { return false }
        return (me.cameraEnabled ?? 0) == 1
            && !isLocalCameraDisabled
            && !isLocalSeatExitPending
    }

    /// 当前登录 userId 的字符串形式（用于 seatList.userId 比较）
    var myUserIdString: String? { SessionStore.shared.user?.userId.map(String.init) }

    /// 是否为当前房间的**房主本人**（对比：`selfRole == .owner` 会把平台超管一起算进来，
    /// 用作管理权限判定正确；但"关注房主""是否自己的房间"这类**身份判定**必须区分。
    /// 参考 party-user-vs-anchor-comparison §1：关注是所有非房主账号的通用能力）。
    var isSelfRoomOwner: Bool {
        guard let owner = roomInfo?.ownerId, !owner.isEmpty,
              let me = myUserIdString, !me.isEmpty else { return false }
        return owner == me
    }

    /// 幸运数字的“房主专属”能力（历史记录与 `adminCanSet`）。
    /// 不复用 `selfRole == .owner`：后者为管理动作把平台管理员提权为 owner，
    /// 而 H5 只允许真实房主进入历史并修改“允许房管设置”。
    var isLuckyNumberRoomOwner: Bool {
        if roomInfo?.roomRoleType == PartyRoomRoleType.owner.rawValue {
            return true
        }
        return isSelfRoomOwner
    }

    /// H5 `feachOnSeat` / `feachExchangeSeat` 同款门禁：普通用户不能进入 MC 位。
    /// 放在 Store 层，保证排麦 CTA、切麦确认等其他入口不会绕过点击层判断。
    private func isAudienceMCSeat(_ seatIndex: Int) -> Bool {
        selfRole == .audience
            && seatList.first(where: { $0.seatIndex == seatIndex })?.isMCSeat == true
    }

    /// 普通用户只能通过 1040 视频位邀请进入视频位，不能自行上麦、换位或排麦申请。
    private func isAudienceVideoSeat(_ seatIndex: Int) -> Bool {
        selfRole == .audience
            && seatList.first(where: { $0.seatIndex == seatIndex })?.isVideoSeat == true
    }

    private func mediaRequirement(forSeatType seatType: Int?) -> MediaPermissionGate.Requirement {
        // RTC 语音位仅发布 microphone track；只有视频位会启用相机采集和自定义视频轨。
        // seatType 缺失时与 `PartyRoomSeat.typed ?? .voice` 的默认语义一致，按语音位处理。
        seatType == PartyRoomSeatType.video.rawValue ? .liveStream : .microphone
    }

    private func requireMediaAccess(
        _ requirement: MediaPermissionGate.Requirement,
        retry: @escaping () async -> Void
    ) async -> Bool {
        guard await MediaPermissionGate.requestAccess(for: requirement) else {
            mediaPermissionAlertRequirement = requirement
            pendingMediaPermissionAction = retry
            return false
        }
        return true
    }

    func retryMediaPermissionFromAlert(_ requirement: MediaPermissionGate.Requirement) async {
        let action = pendingMediaPermissionAction
        mediaPermissionAlertRequirement = nil
        pendingMediaPermissionAction = nil
        if await MediaPermissionGate.requestAccess(for: requirement) {
            await action?()
        } else {
            MediaPermissionGate.openAppSettings()
        }
    }

    /// 当前登录 userId 的 UInt 形式（用于声网 uid 比较）
    var myRtcUid: UInt? {
        guard let id = SessionStore.shared.user?.userId, id > 0 else { return nil }
        return UInt(id)
    }

    // MARK: - 麦时统计（F 期蓝本 02-04 §2.6 · 2026-07-17）

    /// 上麦起始时间戳（对齐安卓 `mOnMikeStartTime`）。
    /// - 上麦（selfSeat nil→有）时置 `Date()`；下麦/被抱下/切模版/退房/被踢时置 nil。
    /// - 累加值写入 `accumulatedMikeSeconds`。
    private var onMikeStartTime: Date?
    /// 本端发起的上麦/换麦请求在服务端座位广播确认后才消费，不能把 HTTP 已受理误记为上麦成功。
    /// 请求发出前即写入，避免 1001 广播先于 HTTP 回包抵达时丢失用户实际操作路径。
    private struct PendingMicEntryAnalytics: Equatable {
        let id = UUID()
        let path: String
        let expectedSeatIndex: Int?
    }
    private var pendingMicEntry: PendingMicEntryAnalytics?
    /// 本端主动下麦或切模板时写入；实际 seatList 移除时才消费并上报。
    private struct PendingMicLeaveAnalytics: Equatable {
        let id = UUID()
        let reason: String
        let expectedSeatIndex: Int?
    }
    private var pendingMicLeave: PendingMicLeaveAnalytics?

    /// 本次进房累计麦时（秒，对齐安卓 `accumulatedDuration`）。
    /// 退房 resetState 时归零；埋点框架就位后由 `PartyRoomDataActivity` 等价页面上报。
    /// TODO(埋点框架 · spec §1 step 4)：Points/Track SDK wire 到位后补上报调用点。
    @Published private(set) var accumulatedMikeSeconds: TimeInterval = 0

    /// selfSeat 前后对比处理麦时累加。挂在 `seatList.didSet`。
    /// - prev 无 curr 有 → 上麦，记 `onMikeStartTime = now`
    /// - prev 有 curr 无 → 下麦（含被抱下 / 被踢 / 切模版清空 / 退房 resetState），累加秒数
    /// - 其他情形（都在麦或都不在麦、换麦 exchangeSeat）→ 保持不动
    private func trackMikeTimeIfNeeded(previous: [PartyRoomSeat]) {
        guard let me = myUserIdString, !me.isEmpty else { return }
        let previousSeat = previous.first { $0.userId == me }
        let currentSeat = seatList.first { $0.userId == me }
        if previousSeat == nil, let currentSeat {
            onMikeStartTime = Date()
            AppLogger.party.info("[PartyStore] mikeTime: onSeat startAt=\(self.onMikeStartTime?.timeIntervalSince1970 ?? 0, privacy: .public)")
            if roomState == .joined {
                trackSelfMicEnter(currentSeat, path: consumePendingMicEntry(for: currentSeat) ?? "invite")
            }
        } else if let previousSeat, currentSeat == nil {
            trackSelfMicLeave(previousSeat, reason: consumePendingMicLeave(for: previousSeat) ?? "quit")
        } else if let previousSeat, let currentSeat {
            // 模板切换重拉成功但本人仍在麦位时，不能把后续正常下麦误记为 modeChange。
            if pendingMicLeave?.reason == "modeChange" {
                pendingMicLeave = nil
            }
            if previousSeat.seatIndex != currentSeat.seatIndex,
               roomState == .joined {
                trackSelfMicEnter(currentSeat, path: consumePendingMicEntry(for: currentSeat) ?? "change_mic")
            }
        }
    }

    /// 任何本人上麦/下麦的座位变更都会消费当前待定项，避免超时或乱序回包污染后续事件。
    private func consumePendingMicEntry(for seat: PartyRoomSeat) -> String? {
        guard let pending = pendingMicEntry else { return nil }
        pendingMicEntry = nil
        guard pending.expectedSeatIndex == nil || pending.expectedSeatIndex == seat.seatIndex else { return nil }
        return pending.path
    }

    private func consumePendingMicLeave(for seat: PartyRoomSeat) -> String? {
        guard let pending = pendingMicLeave else { return nil }
        pendingMicLeave = nil
        guard pending.expectedSeatIndex == nil || pending.expectedSeatIndex == seat.seatIndex else { return nil }
        return pending.reason
    }

    private func trackSelfMicEnter(_ seat: PartyRoomSeat, path: String) {
        guard let info = roomInfo else { return }
        var properties = PartyAnalytics.roomProperties(
            roomId: info.id,
            ownerId: info.ownerId,
            roomTempId: info.roomTempId
        )
        properties["path"] = path
        properties["result"] = "success"
        properties["seat_num"] = seat.seatIndex ?? -1
        PartyAnalytics.track(seat.isVideoSeat ? "party_video_click" : "party_voice_click", properties: properties)
    }

    private func trackSelfMicLeave(_ seat: PartyRoomSeat, reason: String) {
        let duration: Int
        if let start = onMikeStartTime {
            let delta = max(0, Date().timeIntervalSince(start))
            accumulatedMikeSeconds += delta
            duration = Int(delta)
            AppLogger.party.info("[PartyStore] mikeTime: offSeat +\(duration, privacy: .public)s total=\(Int(self.accumulatedMikeSeconds), privacy: .public)s")
        } else {
            duration = 0
        }
        onMikeStartTime = nil

        guard let info = roomInfo else { return }
        var properties = PartyAnalytics.roomProperties(
            roomId: info.id,
            ownerId: info.ownerId,
            roomTempId: info.roomTempId
        )
        properties["reason"] = reason
        properties["duration"] = duration
        properties["seat_num"] = seat.seatIndex ?? -1
        PartyAnalytics.track(seat.isVideoSeat ? "party_video_leave" : "party_voice_leave", properties: properties)
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
        chat.outgoingTextMetadataProvider = { [weak self] in
            guard let self else { return (.audience, false) }
            return (self.selfRole, self.isPlatformAdmin)
        }
        // M5 备用路径：上游 NIMChatroomManager 改走 NIMService.dispatch(context: .liveChatroom) 时，
        // 本 router 在直播聊天室通道短路（避免下游意外消费派对房 attachType）；
        // 派对房通道仍由 chat.processIncoming → chatRouter.processCustom 单一路径维持。
        NIMService.shared.registerRouter(chatRouter)
        followRelationObserver = NotificationCenter.default.addObserver(
            forName: .followRelationChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let userId = userInfo["userId"] as? Int,
                  let followFlag = userInfo["followFlag"] as? Int else { return }
            Task { @MainActor [weak self] in
                self?.syncFollowRelation(userId: userId, followFlag: followFlag)
            }
        }
    }

    /// E-spec §0.2 F-05：登出时切断 chatRouter 全局注册。
    /// 用户 A 登出 → NIMOnlineKeeper.stop → 用户 B 登录 → NIMService 重连；chatRouter 仍是 A 时代实例、
    /// delegate 仍是本单例 → 派对房消息若从 B 账号收到，会误触发 delegate 调用 UI 状态。
    /// 由 RootView.syncSessionDependent 登出分支调用。
    func detachChatRouter() {
        NIMService.shared.unregisterRouter(chatRouter)
    }

    // MARK: - enterRoom

    /// H5 密码房流程：输入完整 4 位密码后先请求 `/room/enter`，只有成功才允许导航进房。
    /// 成功响应暂存为一次性结果，供紧接着的 `enterRoom` 消费并继续完整入房链路。
    func validateRoomEntryPassword(roomId: String, password: String) async -> PartyRoomError? {
        prevalidatedRoomEntry = nil
        guard password.count == 4, password.allSatisfy(\.isNumber) else {
            return .passwordWrong
        }

        do {
            let info = try await PartyAPI.enterRoom(roomId: roomId, password: password)
            prevalidatedRoomEntry = (roomId, info)
            return nil
        } catch let api as PartyAPIError {
            return PartyRoomErrorMapper.map(api)
        } catch {
            return .enterFailed(underlying: error.localizedDescription)
        }
    }

    func enterRoom(
        roomId: String,
        password: String? = nil,
        entryPath: PartyRoomEntryPath = .standard
    ) async {
        // P 项目权限管理：三层防护 Store 层 · 走统一 gate helper（v2 code-review 补迁移 · 与其他 5 处对齐）
        guard SelfPermissionBridge.shared.gate(.party, action: "enterRoom(\(roomId))") else { return }
        // 残留检查：state != idle/ended → 先强清
        if roomState != .idle && roomState != .ended {
            AppLogger.party.notice("[PartyStore] enterRoom while state=\(self.roomState.debugDesc, privacy: .public), force leave first")
            await forceLeaveRoom(.userRequest)
        }
        roomEntryGeneration &+= 1
        let entryGeneration = roomEntryGeneration
        pendingRoomEntryId = roomId
        currentEntryPath = entryPath
        partyJoinedAt = nil
        roomState = .preparing
        lastError = nil
        AppLogger.party.info("[PartyStore] enterRoom roomId=\(roomId, privacy: .public)")

        // Step 1: HTTP enter
        let info: PartyRoomInfo
        if let prevalidated = prevalidatedRoomEntry, prevalidated.roomId == roomId {
            prevalidatedRoomEntry = nil
            info = prevalidated.info
        } else {
            prevalidatedRoomEntry = nil
            do {
                info = try await PartyAPI.enterRoom(roomId: roomId, password: password)
            } catch let api as PartyAPIError {
                guard isCurrentRoomEntry(entryGeneration, roomId: roomId) else { return }
                pendingRoomEntryId = nil
                let mapped = PartyRoomErrorMapper.map(api)
                roomState = .ended
                lastError = mapped
                AppLogger.party.error("[PartyStore] enter HTTP failed: \(api.localizedDescription, privacy: .private)")
                return
            } catch let dec as DecodingError {
                guard isCurrentRoomEntry(entryGeneration, roomId: roomId) else { return }
                pendingRoomEntryId = nil
                roomState = .ended
                let detail = "enter 解码: \(dec)"
                lastError = .enterFailed(underlying: detail)
                AppLogger.party.error("[PartyStore] enter decoding error: \(String(describing: dec), privacy: .public)")
                return
            } catch {
                guard isCurrentRoomEntry(entryGeneration, roomId: roomId) else { return }
                pendingRoomEntryId = nil
                roomState = .ended
                lastError = .enterFailed(underlying: error.localizedDescription)
                AppLogger.party.error("[PartyStore] enter unknown error: \(String(describing: error), privacy: .public)")
                return
            }
        }

        guard isCurrentRoomEntry(entryGeneration, roomId: roomId) else {
            await exitStaleRoomEntryIfNeeded(info, generation: entryGeneration)
            return
        }

        // Step 2: 写入本地状态 + 预对账
        roomInfo = info
        seatList = info.roomSeatList ?? []
        onlineUserCount = info.onlineCount
        // 初始化关注态（对齐 H5 `currentPartyInfo.isFollowOwner`；nil 视为未关注）
        isFollowingAnchor = info.isFollowOwner ?? false
        // 初始化排麦申请开关（对齐安卓 PartyRoomVM.setPartyRoomInfo 同步 onSeatApplySwitch；
        // 1021 广播只在切换时下发，进房初始态必须从 enter response 拉；nil fallback 到 false）
        micApplicationSwitchOn = info.onSeatApplySwitch ?? false
        isRoomMusicEnabled = false
        roomMusicSettings = .empty
        isRoomMusicAudible = true
        // 对齐安卓 PartyRoomInfo.queueSeatNum：进房 badge 初始态从 enter 响应拉，避免"进已有排队房 badge 显示 0"
        queueSeatNum = info.queueSeatNum ?? 0
        // v16：字段真机对齐诊断 —— 若后端 `isFollowOwner` 字段名不匹配 / 不返回，
        // 用户报"已关注房间重进显示未关注"时可查此 log 确认后端行为
        AppLogger.party.info("[PartyStore] enter isFollowOwner raw=\(String(describing: info.isFollowOwner), privacy: .public) → isFollowingAnchor=\(self.isFollowingAnchor, privacy: .public)")
        // v12：房主头像框 async 拉（不阻塞进房主流程）
        Task { [weak self] in await self?.loadOwnerInfoIfNeeded() }
        // v16.4：房间背景 async 拉（enterRoom response 不返 bigImgUrl，需独立接口获取房主已设背景）
        Task { [weak self] in await self?.loadCurrentRoomBackground() }
        // H5 也在进房后单独拉 music/settings；roomMusicSwitc 只控制入口可见性。
        Task { [weak self] in await self?.loadRoomMusicSettings() }
        // 半屏游戏暂不接入：当前环境未部署 anchor/list，先不在进房时发起请求。
        partyBannerGamesEpoch &+= 1
        partyBannerGames = []
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
                guard isCurrentRoomEntry(entryGeneration, roomId: roomId) else {
                    return
                }
                rtcToken = r.rtcToken ?? ""
            } catch {
                guard isCurrentRoomEntry(entryGeneration, roomId: roomId) else {
                    return
                }
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

        // Step 7 (F-spec)：进房若后端返回上次记忆的私 call 礼物 giftId，异步拉 CALL 礼物面板匹配 icon/price
        // 让浮动开关按钮开启态能立即显示"上次选的礼物"预览（用户诉求 · 减少重选负担）
        Task { @MainActor in await loadPartyCallGiftMetaIfNeeded() }

        // roomState = .joined 由 RTC didJoin + Chat didEnter 双就绪后回调 markJoinedIfReady() 设置
    }

    private func isCurrentRoomEntry(_ generation: UInt, roomId: String) -> Bool {
        roomEntryGeneration == generation && pendingRoomEntryId == roomId
    }

    private func invalidateRoomEntry() {
        roomEntryGeneration &+= 1
        pendingRoomEntryId = nil
    }

    /// 已被本端放弃的 enter 请求仍可能在服务端成功。若没有新会话接管同一房间，
    /// 用 enter 响应里的真实 roomId/yxRoomId 补偿退房，避免服务端留下幽灵 Party 状态。
    private func exitStaleRoomEntryIfNeeded(_ info: PartyRoomInfo, generation: UInt) async {
        guard roomEntryGeneration != generation,
              let roomId = info.id, !roomId.isEmpty,
              let yxRoomId = info.yxRoomId, !yxRoomId.isEmpty,
              pendingRoomEntryId != roomId,
              roomInfo?.id != roomId
        else { return }
        _ = try? await PartyAPI.exitRoom(roomId: roomId, seatIndex: -1, yxRoomId: yxRoomId)
    }

    /// 进房时，私 call 礼物价格必须以私 call 选择器（CALL 场景）的礼物面板价格为准。
    /// `room/enter` 的同名字段是用户付款价格，不能写入浮动卡片；面板加载期间保持价格为空。
    private func loadPartyCallGiftMetaIfNeeded() async {
        guard let info = roomInfo,
              let roomId = info.id, !roomId.isEmpty,
              let giftId = info.partyCallGiftId, !giftId.isEmpty else {
            return
        }
        let entryGeneration = roomEntryGeneration

        // 进房响应的价格是付款价格。无论之前的缓存状态如何，先隐藏，直到面板收益价格匹配成功。
        partyCallGiftPrice = nil
        if let image = info.partyCallGiftImg, !image.isEmpty {
            partyCallGiftIcon = image
        }

        do {
            // 私 call 的设置入口是 CommonGiftPanel.callGate，使用同一 CALL 数据源；
            // Party 房送礼面板的目录不同，不能用它反查私 call 礼物。
            let groups = try await DefaultGiftDataSource(scene: .call).loadGifts()
            let match = groups.lazy
                .flatMap(\.gifts)
                .first { String($0.id) == giftId }

            // 请求可能在切房或重新设置私 call 礼物后才返回，不能覆盖当前房间的展示状态。
            guard roomEntryGeneration == entryGeneration,
                  roomInfo?.id == roomId,
                  roomInfo?.partyCallGiftId == giftId else {
                return
            }

            if let match {
                if partyCallGiftIcon?.isEmpty != false {
                    partyCallGiftIcon = match.giftSmallImg.isEmpty ? match.giftImg : match.giftSmallImg
                }
                partyCallGiftPrice = match.giftPrice > 0 ? Int(exactly: match.giftPrice) : nil
                AppLogger.party.info("[PartyStore] loadPartyCallGiftMeta matched giftId=\(giftId, privacy: .public) price=\(match.giftPrice, privacy: .public)")
            } else {
                AppLogger.party.notice("[PartyStore] loadPartyCallGiftMeta giftId=\(giftId, privacy: .public) NOT FOUND in CALL gift panel")
            }
        } catch {
            guard roomEntryGeneration == entryGeneration,
                  roomInfo?.id == roomId,
                  roomInfo?.partyCallGiftId == giftId else {
                return
            }
            AppLogger.party.notice("[PartyStore] loadPartyCallGiftMeta CALL gift panel failed err=\(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - leaveRoom

    /// 用户主动退房（HTTP + RTC + Chat 串行；spec §1.4.6）
    func leaveRoom() async {
        guard roomState == .preparing || roomState == .joined || roomState == .entering else {
            AppLogger.party.notice("[PartyStore] leaveRoom skip state=\(self.roomState.debugDesc, privacy: .public)")
            return
        }
        invalidateRoomEntry()
        let roomIdBiz = roomInfo?.id ?? ""
        let yxRoomId = roomInfo?.yxRoomId ?? ""
        // `exitRoom` 由服务端统一完成退房及麦位释放；未上麦时与安卓/H5 一致传 -1。
        let mySeatIndex = selfSeat?.seatIndex ?? -1
        let wasOnVideoSeat = selfSeat?.isVideoSeat == true
        let wasTopX = PartyHotRoomTaskStore.shared.isTopRoom
        trackRoomLeaveIfNeeded(reason: "leave")
        trackHotTaskLeaveIfNeeded(
            roomId: roomIdBiz,
            seatIndex: mySeatIndex,
            wasOnVideoSeat: wasOnVideoSeat,
            wasTopX: wasTopX
        )

        roomState = .leaving
        endPartySessionDependencies(roomId: roomInfo?.id)
        chat.clearDeferredMessages()
        isMinimized = false
        minimizedBridge.hide()

        // 退房的本地媒体释放独立于 HTTP；接口失败时也必须立刻关摄像头和麦克风。
        deactivateLocalSeatMediaForExit()

        // 退出 RTC 不阻塞后续服务端退房。
        await rtc.leave()

        if !roomIdBiz.isEmpty, !yxRoomId.isEmpty {
            do {
                try await PartyAPI.exitRoom(roomId: roomIdBiz, seatIndex: mySeatIndex, yxRoomId: yxRoomId)
            } catch {
                AppLogger.party.notice("[PartyStore] exitRoom HTTP failed: \(String(describing: error), privacy: .private)")
            }
        }

        // HTTP 已完成，再清 WS 上下文并退出 Party 聊天室。
        // 即使 HTTP 失败也要清上下文，避免本端继续续期已经离开的 Party 房。
        WSHeartbeat.shared.clearPartyContext()
        chat.leave()

        resetState()
        roomState = .ended
        AppLogger.party.info("[PartyStore] leaveRoom done")
    }

    /// 强制退房（被踢 / 进房失败 / 网络断 / 用户主动；spec §1.4.6 异常分流）
    /// 所有步骤 try? 容错；不阻塞 reset 链路。
    func forceLeaveRoom(_ reason: PartyForceLeaveReason) async {
        AppLogger.party.notice("[PartyStore] forceLeaveRoom reason=\(String(describing: reason), privacy: .public)")
        invalidateRoomEntry()
        // 在 roomState 变为 .ended 前写入，供房间页识别强制退出并返回列表。
        if reason == .kicked {
            lastError = .kicked
        }
        let roomIdBiz = roomInfo?.id ?? ""
        let yxRoomId = roomInfo?.yxRoomId ?? ""
        let mySeatIndex = selfSeat?.seatIndex ?? -1
        let wasOnVideoSeat = selfSeat?.isVideoSeat == true
        let wasTopX = PartyHotRoomTaskStore.shared.isTopRoom
        trackRoomLeaveIfNeeded(reason: analyticsLeaveReason(for: reason))
        trackHotTaskLeaveIfNeeded(
            roomId: roomIdBiz,
            seatIndex: mySeatIndex,
            wasOnVideoSeat: wasOnVideoSeat,
            wasTopX: wasTopX
        )

        roomState = .leaving
        endPartySessionDependencies(roomId: roomInfo?.id)
        chat.clearDeferredMessages()
        isMinimized = false
        minimizedBridge.hide()

        // 强制退房同样先收本地媒体，不能等待 exitRoom 的网络结果。
        deactivateLocalSeatMediaForExit()

        // 与正常退房保持同序。
        await rtc.leave()

        if !roomIdBiz.isEmpty, !yxRoomId.isEmpty {
            _ = try? await PartyAPI.exitRoom(roomId: roomIdBiz, seatIndex: mySeatIndex, yxRoomId: yxRoomId)
        }
        WSHeartbeat.shared.clearPartyContext()
        chat.leave()
        resetState()
        roomState = .ended

    }
    private func resetState() {
        // 小窗退出时 PartyRoomView 已卸载，不能依赖其 onDisappear 清理会话外资源。
        // 普通退房会先由视图清理一次；以下接口均幂等，集中在 Store 兜底所有退出路径。
        endPartySessionDependencies(roomId: roomInfo?.id)
        chat.clearDeferredMessages()
        if let roomId = roomInfo?.id, !roomId.isEmpty {
            PartyStore.announcementShownRoomIds.remove(roomId)
        }

        isMinimized = false
        minimizedBridge.hide()
        resetLocalMediaOverrides()
        partyJoinedAt = nil
        currentEntryPath = .standard
        pendingMicEntry = nil
        pendingMicLeave = nil
        roomInfo = nil
        seatList = []
        // F 期麦时统计：seatList = [] 触发 didSet → trackMikeTimeIfNeeded 累加最后一段麦时；
        // TODO(埋点框架 · spec §1 step 4)：上报调用点插入此处；随后归零，避免下次进房带入
        AppLogger.party.info("[PartyStore] party ended totalMikeTime=\(Int(self.accumulatedMikeSeconds), privacy: .public)s (report pending 埋点框架)")
        accumulatedMikeSeconds = 0
        onMikeStartTime = nil
        // F 期 Room Mute 状态回归默认；SDK 层无需显式复位（engine 也会随下次 join 重建）
        isRoomMuted = false
        isRoomMusicEnabled = false
        roomMusicSettings = .empty
        isRoomMusicAudible = true
        onlineUserCount = 0
        isJoinedChannel = false
        imAlive = false
        lastGiftEvent = nil
        clearPartyAuditWarning()
        platformAdminOverride = nil
        partyRoleOverrides = [:]
        pendingAdminUserIds = []
        firstGiftFloatQueue.clear()
        luckyNumberWinPayload = nil
        giftEffects.reset()
        PartySuperWheelStore.shared.reset()
        pendingVideoSeatInvite = nil
        lastInviteResult = nil
        videoSeatInviteCooldowns = [:]
        isFollowingAnchor = false
        isTogglingFollow = false
        // v12：房主头像框 state 清（退房后下次进新房需重拉）
        ownerHeadFrameURL = nil
        didLoadOwnerInfo = false
        // v16.4：房间背景 state 清 —— 新房需重拉，否则会带入上一房的背景
        // v18：bump epoch 让上一房 in-flight `loadCurrentRoomBackground` 恢复时对比 epoch → 丢写
        backgroundEpoch &+= 1
        currentRoomBackground = nil
        speakingUids = []
        partyBannerGamesEpoch &+= 1
        partyBannerGames = []
        resetEnterFloatingEffects()
        // E v2：Room Mode / Mic Application 状态清 —— 退房需清残留，避免下次进房带入旧队列
        roomModeTemplates = [:]
        roomModeTemplatesState = .idle
        lastRoomTempSwitchAt = nil
        isBusySwitchRoomMode = false
        micApplicationsState = .idle
        micApplicationSwitchOn = false
        isRoomMusicEnabled = false
        roomMusicSettings = .empty
        isRoomMusicAudible = true
        queueSeatNum = 0
        myApplyInfo = .init()
        pendingApproveSeatIndex = []
        applyingTimeoutTask?.cancel()
        applyingTimeoutTask = nil
        isBusyMicSwitch = false
        isBusyRoomMusicSwitch = false
        isBusyRoomMusicControl = false
        isUploadingRoomMusic = false
        // E spec §3：黑名单状态清 —— 退房需清残留，避免下次进新房带入旧列表
        blocklistState = .idle
        isBusyRemoveBlocklist = []
        loadBlocklistTask?.cancel()
        loadBlocklistTask = nil
        // E spec §3 Lock Room：幂等 flag 清（退房若正好卡在请求中，下次进新房重置为可用）
        isBusyLockRoom = false
        // E spec §3 MC Seat：幂等 flag 清（退房重置）
        isBusyMCSeat = false
        // F-spec 私 call：gift cache + toggle flag 清 —— 跨房间避免旧数据残留导致新房按钮显示上一房的礼物
        partyCallGiftIcon = nil
        partyCallGiftPrice = nil
        isTogglingPrivateCall = false
        // F 里程碑：Expression 状态清 —— 退房重置状态机 + 清麦位队列
        // 注意：expressionListState 数据本身跨房通用，但状态机 idle 让下次面板 onAppear 重新走 loading 走查一次
        // （避免上一房数据错乱 · 且 loadExpressionList 有 in-flight guard 不重复请求）
        expressionListState = .idle
        emojiQueueMap = [:]
        isLoadingExpressionList = false

        // F-1a v4 (2026-07-18)：退房清 Battle Team PK 残留 state（对齐 H5 usePartyHooks.js:181 + g-agora-party.vue:586）
        // 不清则下次进新房上一场 PK sheet / 冷却入口 / pending 申请脏读污染
        PartyBattleStore.shared.reset()
    }

    /// 安卓在主播位于 TOPx 房间时为退房/下视频麦埋点携带 `isTopX` 标记。
    private func trackHotTaskLeaveIfNeeded(
        roomId: String,
        seatIndex: Int,
        wasOnVideoSeat: Bool,
        wasTopX: Bool
    ) {
        guard wasTopX else { return }
        let properties: [String: Any] = [
            "roomId": roomId,
            "seatIndex": seatIndex,
            "isTopX": true,
        ]
        PartyAnalytics.track("partyRoomLeave", properties: properties)
        if wasOnVideoSeat {
            PartyAnalytics.track("partyRoomVideoLeave", properties: properties)
        }
    }

    private func trackRoomLeaveIfNeeded(reason: String) {
        guard let joinedAt = partyJoinedAt, let info = roomInfo else { return }
        // 退房、切房、强制退出可能依次经过多个清理入口，只允许当前会话上报一次。
        partyJoinedAt = nil

        var properties = PartyAnalytics.roomProperties(
            roomId: info.id,
            ownerId: info.ownerId,
            roomTempId: info.roomTempId
        )
        properties["duration"] = max(0, Int(Date().timeIntervalSince(joinedAt)))
        properties["Gems"] = info.gemsTotal ?? 0
        properties["reason"] = reason
        PartyAnalytics.track("partyRoom_leave", properties: properties)

        if let status = PartyBattleStore.shared.state?.status,
           status == .selecting || status == .running {
            PartyAnalytics.track(
                "partroom_pk_leave",
                properties: [
                    "duration": properties["duration"] ?? 0,
                    "logotype": "pk",
                ]
            )
        }
    }

    private func analyticsLeaveReason(for reason: PartyForceLeaveReason) -> String {
        switch reason {
        case .kicked: return "kick out"
        case .entryFailed, .networkLost: return "error"
        case .userRequest: return "reset"
        }
    }

    /// 进入 H5 同款 Party 小窗态。会话保持 `.joined`，由 `PartyRoomView.onDisappear` 识别该状态后
    /// 跳过 leave 流程；恢复时重新 push 同一房间路由即可复用既有 RTC/NIM 状态。
    func minimizeRoom() -> Bool {
        guard roomState == .joined, roomInfo?.id?.isEmpty == false else { return false }
        isMinimized = true
        // H5 小窗态停止当前与后续的房内动效；RTC/NIM 会话和音频保持，不下麦、不退房。
        chat.beginDeferringMessages()
        giftEffects.reset()
        resetEnterFloatingEffects()
        emojiQueueMap = [:]
        speakingUids = []
        disableLocalVideoCapture()
        rtc.disableVideoSeat()
        minimizedBridge.show(roomAvatarURL: roomInfo?.roomAvatar)
        AppLogger.party.info("[PartyStore] room minimized")
        return true
    }

    func restoreMinimizedRoom() {
        guard isMinimized else { return }
        isMinimized = false
        minimizedBridge.hide()
        chat.flushDeferredMessages()
        giftEffects.updateVisibleRecipientIds(Set(seatList.compactMap(\.userId)))
        // 复用完整麦位对账恢复本地视频采集/推流，也同步小窗期间发生的麦位变更。
        postMikeList()
        AppLogger.party.info("[PartyStore] room restored from minimized state")
    }

    /// 小窗浮球的退出入口。先同步撤销小窗态，关闭恢复入口后再走完整退房链路。
    func leaveMinimizedRoom() async {
        guard isMinimized else {
            await leaveRoom()
            return
        }
        isMinimized = false
        minimizedBridge.hide()
        chat.clearDeferredMessages()
        await leaveRoom()
    }

    /// 任务轮询、通话观察和自动离线监测均由整个 Party 会话拥有，而非房间页视图拥有。
    private func endPartySessionDependencies(roomId: String?) {
        if let roomId, !roomId.isEmpty {
            PartyWeeklyTaskStore.shared.stopTracking(roomId: roomId)
        }
        PartyHotRoomTaskStore.shared.stopTracking()
        CallStore.shared.detach(self)
        resumeAutoOfflineMonitorIfNeeded()
    }

    /// 自动离线暂停的会话级幂等封装。小窗恢复会重新创建 PartyRoomView，不能重复累加引用计数。
    func suspendAutoOfflineMonitorIfNeeded() {
        guard !isAutoOfflineMonitorSuspended else { return }
        isAutoOfflineMonitorSuspended = true
        AutoOfflineMonitor.shared.suspend()
    }

    /// 与 `suspendAutoOfflineMonitorIfNeeded()` 成对调用；所有退房路径均可安全重复执行。
    func resumeAutoOfflineMonitorIfNeeded() {
        guard isAutoOfflineMonitorSuspended else { return }
        isAutoOfflineMonitorSuspended = false
        AutoOfflineMonitor.shared.resume()
    }

    private func resetEnterFloatingEffects() {
        enterFloatingTask?.cancel()
        enterFloatingTask = nil
        enterFloatingQueue.removeAll()
        enterFloatingMessage = nil
    }

    private func loadPartyBannerGames() async {
        let roomId = roomInfo?.id
        guard let roomId, !roomId.isEmpty else { return }
        let epoch = partyBannerGamesEpoch
        do {
            let games = try await PartyAPI.anchorPartyBannerGames()
            // 进房期间切换/退出后，旧请求回包不可污染当前房间。
            guard self.roomInfo?.id == roomId,
                  self.partyBannerGamesEpoch == epoch,
                  self.roomState == .entering || self.roomState == .joined else { return }
            partyBannerGames = games.filter(\.isDisplayable)
        } catch is CancellationError {
            return
        } catch {
            AppLogger.party.notice("[PartyGame] load anchor banners failed roomId=\(roomId, privacy: .public) err=\(String(describing: error), privacy: .private)")
        }
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

    // MARK: - Expression / Emoji Panel (F 里程碑 · 2026-07-17)

    /// 表情面板打开时拉分类列表（对齐 H5 `usePartyHooks.js` `feachEmojiList()` on popup show）。
    /// `.loaded` 后不重拉（面板反复开关只请求一次 · 由 in-flight flag + state 双守）；error 时可 retry。
    func loadExpressionList() async {
        // in-flight 防连点（面板 onAppear 快速多次触发 · 或 retry 中重复点）
        if isLoadingExpressionList { return }
        // loaded 短路（对齐 [list-refresh-preserve-items] 精神 · 首次拉过就不重拉；如需强制刷新走单独 API）
        if case .loaded = expressionListState { return }

        isLoadingExpressionList = true
        expressionListState = .loading
        do {
            let list = try await PartyAPI.getPartyRoomEmojis()
            // 过滤：emojisList 为空的分类不显示（H5 侧默认过滤空 tab）
            let nonEmpty = list.filter { !$0.emojisList.isEmpty }
            expressionListState = .loaded(nonEmpty)
            AppLogger.party.info("[PartyStore] expression list loaded classifications=\(nonEmpty.count, privacy: .public)")
        } catch {
            let msg = (error as? PartyAPIError)?.localizedDescription
                ?? (error as? DecodingError).map { String(describing: $0) }
                ?? error.localizedDescription
            expressionListState = .error(msg)
            AppLogger.party.error("[PartyStore] loadExpressionList failed: \(msg, privacy: .private)")
        }
        isLoadingExpressionList = false
    }

    /// 用户点选面板某个表情后发送 IM 消息 + 本地立即入队（对齐 H5 `sendExpressionMsg` / `sendPlayEmoji`）。
    ///
    /// **上麦门槛**（对齐 H5 `usePartyHooks.js:1783` `inPartyRole > -1` guard）：
    /// 未上麦时 return（UI 层 PartyRoomInputBar emoji 按钮已 opacity=0/allowsHitTesting=false 门控 ·
    /// 此处二重防御防未来 UI refactor 门控失守 · 参 [prefer-shared-component-over-adhoc] 精神）。
    ///
    /// **静态 vs 玩法**（对齐 H5 `party-expression-popup.vue:92-95`）：
    /// - `!item.isPlayEmoji` → attachType -10 · payload `{id, minImage, playUrl: gifImage, sendUserId}`
    /// - `item.isPlayEmoji` + `resultImages` 非空 → attachType -11 · **客户端随机抽 picked** ·
    ///   payload `{id, minImage, playUrl: picked.image, sendUserId, playType, resultKey, timestamp}`
    ///
    /// `resultImages` 空的玩法 emoji：拒送 + log（H5 侧同款拒送逻辑 · 防播空 URL 崩）。
    func sendEmoji(_ item: PartyEmojiItem) {
        guard let myUserId = myUserIdString, !myUserId.isEmpty else {
            AppLogger.party.notice("[PartyStore] sendEmoji skip: no userId")
            return
        }
        // 玩法 -11 门槛：仅上麦者可发（对齐 H5 `usePartyHooks.js:1783` `inPartyRole > 0`）
        // 静态 -10 无门槛（对齐权限矩阵"emoji 全员基础能力"）
        if item.isPlayEmoji, selfSeat == nil {
            AppLogger.party.notice("[PartyStore] sendEmoji play skip: not on seat emojiId=\(item.id, privacy: .public)")
            return
        }

        let playUrl: String
        var payloadData: [String: Any] = [
            "id": item.id,
            "sendUserId": myUserId,
        ]
        if let mi = item.minImage, !mi.isEmpty { payloadData["minImage"] = mi }

        let attachType: Int
        if item.isPlayEmoji {
            // -11 玩法表情：resultImages 空 → 拒送
            guard let pool = item.resultImages, !pool.isEmpty,
                  let picked = pool.randomElement() else {
                AppLogger.party.error("[PartyStore] sendEmoji play emoji has no resultImages emojiId=\(item.id, privacy: .public)")
                return
            }
            playUrl = picked.image
            attachType = PartyAttachType.emojiPlay.rawValue
            payloadData["playUrl"] = playUrl
            if let pt = item.playType, !pt.isEmpty { payloadData["playType"] = pt }
            payloadData["resultKey"] = picked.key
            payloadData["timestamp"] = Int64(Date().timeIntervalSince1970 * 1000)
        } else {
            // -10 静态表情
            guard let gif = item.gifImage, !gif.isEmpty else {
                AppLogger.party.error("[PartyStore] sendEmoji static emoji has no gifImage emojiId=\(item.id, privacy: .public)")
                return
            }
            playUrl = gif
            attachType = PartyAttachType.emojiStatic.rawValue
            payloadData["playUrl"] = playUrl
        }

        // 本地立即入队（不等云信回环 · 与 H5 pushPlayEmojiMsg pattern 一致 · router 的 self-echo skip 会阻止双入队）
        let local = PartyEmojiPayload(
            uuid: UUID(),
            emojiId: item.id,
            playUrl: playUrl,
            playType: item.isPlayEmoji ? item.playType : nil,
            resultKey: (payloadData["resultKey"] as? String),
            timestamp: (payloadData["timestamp"] as? Int64),
            sendUserId: myUserId
        )
        enqueueEmoji(seatUserId: myUserId, payload: local)

        // 走 chatroom IM 发消息
        chat.sendCustomMessage(attachType: attachType, data: payloadData)
        var properties = PartyAnalytics.roomProperties(
            roomId: roomInfo?.id,
            ownerId: roomInfo?.ownerId,
            roomTempId: roomInfo?.roomTempId
        )
        properties["operation_id"] = myUserId
        properties["emoji_id"] = item.id
        if item.isPlayEmoji {
            properties["playType"] = item.playType ?? ""
            properties["resultKey"] = payloadData["resultKey"] as? String ?? ""
        }
        PartyAnalytics.track(
            item.isPlayEmoji ? "b_playEmoji_success" : "b_sentEmoji_success",
            properties: properties
        )
        AppLogger.party.info("[PartyStore] sendEmoji ok attachType=\(attachType, privacy: .public) emojiId=\(item.id, privacy: .public) isPlay=\(item.isPlayEmoji, privacy: .public)")
    }

    /// 单麦位队列入队 + 上限 shift（对齐 H5 `QUEUE_MAX_SIZE = 20`）。
    func enqueueEmoji(seatUserId: String, payload: PartyEmojiPayload) {
        var queue = emojiQueueMap[seatUserId] ?? []
        queue.append(payload)
        // 超上限 shift 队首（对齐 H5：防单麦位刷屏 SVGA 引起 GPU 卡顿）
        while queue.count > emojiQueueMaxSize {
            queue.removeFirst()
        }
        emojiQueueMap[seatUserId] = queue
    }

    /// 单麦位 SVGA 播完后出队队首（player onFinish 回调驱动）。
    /// - 队首 payload 应等于 `expected`（防迟到的 onFinish 出队新 payload · SVGA 播放器实例复用竞态防御）
    /// - 队列空清 key（避免 dict 长期堆积空 array · @Published 变化频率也降）
    func dequeueEmoji(seatUserId: String, expected: PartyEmojiPayload) {
        guard var queue = emojiQueueMap[seatUserId], !queue.isEmpty else { return }
        // 幂等：只在队首 UUID 匹配时才出队（防迟到 onFinish 误吞新入队的 payload）
        if queue.first?.uuid == expected.uuid {
            queue.removeFirst()
            if queue.isEmpty {
                emojiQueueMap.removeValue(forKey: seatUserId)
            } else {
                emojiQueueMap[seatUserId] = queue
            }
        } else {
            AppLogger.party.debug("[PartyStore] dequeueEmoji uuid mismatch (head=\(queue.first?.uuid.uuidString ?? "nil", privacy: .public) expected=\(expected.uuid.uuidString, privacy: .public)) drop")
        }
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

    /// v16.4：enterRoom 完成后主动拉房间**已设背景**（对齐 H5 room-bg.vue 数据源）。
    ///
    /// **必要性**：enterRoom response 里的 `bigImgUrl / bgImgUrl` 大多返 null（后端不在 enter 里返），
    /// 房主实际设置的背景需通过独立 `room/getRoomBgImage` 接口拉。iOS PartyRoomSettingsView
    /// 已在用同一 API 显示"当前已选背景"。
    ///
    /// **v17 真根因修复（对齐 H5 create.vue:216 精神）**：后端 `getRoomBgImage` 只返 `{id: X}`
    /// 无 URL 字段（PartyAPI.swift:150 早有注释警告）。仅靠此接口，`bigImgUrl/imgUrl` decode 恒 nil
    /// → PartyRoomView 永远显示 DEFAULT_BG 静态兜底 → 用户报"选完动图仍显示静态图"。
    /// 修复：拿到 id 后拉 `getBgImages` 全列表按 id 匹配拿完整对象（含真实 bigImgUrl 动图 URL）。
    /// 匹配失败退化为 id-only 对象（现状兼容）。
    ///
    /// 更新 `currentRoomBackground` @Published → backgroundLayer 自动派生新 URL 显示。
    /// 失败静默：backgroundLayer fallback 到 H5 DEFAULT_BG 网络图。
    func loadCurrentRoomBackground() async {
        guard let info = roomInfo, let id = info.id, !id.isEmpty else { return }
        // Snapshot：入口锁定 room-id + epoch，写入前 double-check 防两种 race（见字段声明）
        let expectedRoomId = id
        let expectedEpoch = backgroundEpoch

        // 独立守卫：写入前必须 (a) 当前房间未变，(b) epoch 未被外部 update 抢先
        func canWrite() -> Bool {
            guard roomInfo?.id == expectedRoomId else {
                AppLogger.party.notice("[PartyStore] loadCurrentRoomBackground stale: roomId changed from=\(expectedRoomId, privacy: .public) to=\(self.roomInfo?.id ?? "nil", privacy: .public), drop write")
                return false
            }
            guard backgroundEpoch == expectedEpoch else {
                AppLogger.party.notice("[PartyStore] loadCurrentRoomBackground stale: epoch bumped by external update (my=\(expectedEpoch, privacy: .public) cur=\(self.backgroundEpoch, privacy: .public)), drop write")
                return false
            }
            return true
        }

        // v18 并发拉：getRoomBgImage 与 backgroundList 相互独立（match 本地做），
        // `async let` 让两者并行，省一个 RTT。backgroundList 会话内缓存，多次进房只拉一次。
        async let idOnlyTask: PartyBackground? = PartyAPI.getRoomBgImage(roomId: id)
        async let listTask: [PartyBackground] = self.fetchBackgroundListCached()

        let idOnly: PartyBackground?
        do {
            idOnly = try await idOnlyTask
        } catch {
            _ = await listTask   // 收尾 async let 避免 warning
            AppLogger.party.notice("[PartyStore] loadCurrentRoomBackground getRoomBgImage failed: \(String(describing: error), privacy: .private)")
            return
        }

        guard let idOnly else {
            _ = await listTask
            guard canWrite() else { return }
            currentRoomBackground = nil
            AppLogger.party.info("[PartyStore] loadCurrentRoomBackground: no bg set")
            return
        }

        let list = await listTask
        guard canWrite() else { return }
        if let full = list.first(where: { $0.id == idOnly.id }) {
            currentRoomBackground = full
            AppLogger.party.info("[PartyStore] loadCurrentRoomBackground matched id=\(full.id, privacy: .public) bigImgUrl=\(full.bigImgUrl ?? "nil", privacy: .public)")
        } else {
            currentRoomBackground = idOnly
            AppLogger.party.notice("[PartyStore] loadCurrentRoomBackground id=\(idOnly.id, privacy: .public) not in backgroundList (list size=\(list.count, privacy: .public)); fallback id-only")
        }
    }

    /// v18：backgroundList 会话缓存（近似静态目录，多次进房只拉一次）。
    /// 失败退化空数组不 throw，让 loadCurrentRoomBackground 走 fallback（id-only）。
    private func fetchBackgroundListCached() async -> [PartyBackground] {
        if let cached = backgroundListCache { return cached }
        let fresh = (try? await PartyAPI.backgroundList()) ?? []
        backgroundListCache = fresh
        return fresh
    }

    /// v17：由 Settings 层选完背景后回流完整对象（对齐 H5 create.vue:200-203
    /// `apiSetPartyBgImage.then → partyStore.currentPartyInfo.bigImgUrl = selectedBg.bigImgUrl`）。
    ///
    /// 必要性：`getRoomBgImage` 只返 id 无 URL；只有前端选背景那一刻手里握着完整 `PartyBackground`
    /// （从 `getBgImages` 列表来）—— 必须此刻主动回流，否则 PartyRoomView 只能等下一次 `loadCurrentRoomBackground`
    /// 全流程 refresh（成本高 + UX 延迟）。
    func updateCurrentRoomBackground(_ bg: PartyBackground) {
        // v18 竞态守卫：bump epoch → 任何 in-flight `loadCurrentRoomBackground` 恢复时对比 epoch
        // 发现不匹配 → 丢写，避免用户新选被 stale load 覆盖回旧背景
        backgroundEpoch &+= 1
        currentRoomBackground = bg
        AppLogger.party.info("[PartyStore] updateCurrentRoomBackground id=\(bg.id, privacy: .public) bigImgUrl=\(bg.bigImgUrl ?? "nil", privacy: .public) epoch=\(self.backgroundEpoch, privacy: .public)")
    }

    /// 删除 Party 房公屏文本消息。服务端成功后立即移除本地副本，等待云信撤回时不重复处理。
    /// 对齐 H5 `party-msg-delete-popup.vue`；仅管理角色且仅远端文本消息可操作。
    func deletePartyMessage(_ message: UnifiedPublicChatMessage) async -> Bool {
        guard selfRole == .owner || selfRole == .admin,
              let roomId = roomInfo?.id, !roomId.isEmpty,
              let source = message.source,
              case .text = message.variant else {
            return false
        }
        do {
            try await PartyAPI.deletePartyMessage(
                roomId: roomId,
                messageId: source.messageId,
                timetag: source.timetag,
                fromAccid: source.fromAccid
            )
            chat.removeMessage(id: message.id)
            var properties = PartyAnalytics.roomProperties(
                roomId: roomId,
                ownerId: roomInfo?.ownerId,
                roomTempId: roomInfo?.roomTempId
            )
            // H5 uses the historical capitalized roomID field for this event.
            properties["roomID"] = roomId
            properties["type"] = selfRole == .owner ? "roomOwner" : "roomAdmin"
            properties["isPlatformAdmin"] = roomInfo?.isPlatformAdmin == true
            PartyAnalytics.track("b_party_singlemsg_delete", properties: properties)
            return true
        } catch {
            AppLogger.party.error("[PartyStore] deletePartyMessage failed: \(String(describing: error), privacy: .private)")
            return false
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

    /// 消费跨页面关注关系广播；仅目标为当前房主时更新，其他用户的变更不影响房间顶部。
    private func syncFollowRelation(userId: Int, followFlag: Int) {
        guard let ownerId = roomInfo?.ownerId,
              ownerId == String(userId),
              followFlag == 0 || followFlag == 1 else { return }
        isFollowingAnchor = followFlag == 1
        AppLogger.party.info("[PartyStore] synced owner follow uid=\(userId, privacy: .public) isFollowing=\(self.isFollowingAnchor, privacy: .public)")
    }

    /// RTC + Chat 双 ready 才标 .joined
    private func markJoinedIfReady() {
        guard roomState == .entering else { return }
        guard isJoinedChannel, imAlive else { return }
        roomState = .joined
        partyJoinedAt = Date()
        if let info = roomInfo {
            var properties = PartyAnalytics.roomProperties(
                roomId: info.id,
                ownerId: info.ownerId,
                roomTempId: info.roomTempId
            )
            properties["path"] = currentEntryPath.rawValue
            properties["logotype"] = (info.pkStatus ?? 0) > 0 ? "pk" : "normal"
            PartyAnalytics.track("partyRoom_enter", properties: properties)
        }
        if let seat = selfSeat {
            trackSelfMicEnter(seat, path: consumePendingMicEntry(for: seat) ?? "restore")
        }
        AppLogger.party.info("[PartyStore] markJoinedIfReady → state=joined")
        if let roomId = roomInfo?.id, !roomId.isEmpty {
            Task {
                do {
                    try await PartyAPI.openEnterEffect(roomId: roomId)
                } catch {
                    // 进场效果失败不能影响已经建立的 RTC/聊天室会话；与 H5 fire-and-forget 语义一致。
                    AppLogger.party.notice("[PartyStore] open enter effect failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
        // 房主进入自己已开启私 call 的房间 → 自动上线（对齐直播/匹配的自动上线行为）
        // 观众进这种房间不触发（私 call 是房主专属功能，房间态与观众无关）
        if selfRole == .owner,
           roomInfo?.partyPrivateCallOpen == 1,
           !OnlineStatusStore.shared.userSetOnline {
            OnlineStatusStore.shared.setUserSetOnline(true)
        }
        // F-1a v3 (2026-07-18)：进房完成时拉 PK 全局开关（对齐 H5 usePartyHooks.js:609
        // `_battleStore.loadGlobalConfig().catch(() => {})`），关闭态隐藏 PK 入口
        // + refresh 兜底 state（对齐 usePartyHooks.js :607 `_battleStore.refresh(_rid)`）
        let rid = roomInfo?.id ?? ""
        Task { [weak self] in
            guard let self else { return }
            await PartyBattleStore.shared.loadGlobalConfig()
            if !rid.isEmpty {
                await PartyBattleStore.shared.refreshIfNeeded(roomId: rid)
                PartySuperWheelStore.shared.beginTracking(roomId: rid)
                await PartySuperWheelStore.shared.loadState(roomId: rid, presentWhenActive: true)
            }
            await self.loadPartyBaseConfigIfNeeded()
        }
    }

    private func loadPartyBaseConfigIfNeeded() async {
        guard kickOutHours == 0 else { return }
        do {
            let config = try await PartyAPI.getPartyBaseConfig()
            let seconds = max(0, config.kickOutInterval ?? 0)
            kickOutHours = seconds / 3_600
        } catch {
            AppLogger.party.warning("[PartyStore] getPartyBaseConfig failed: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - 上下麦 / 媒体切换

    func requestOnSeat(seatIndex: Int) async {
        guard !isAudienceMCSeat(seatIndex) else {
            lastError = .underlying(.business(
                code: "MC_SEAT_RESTRICTED",
                message: L10n.Party.mcSeatCannotTake
            ))
            return
        }
        guard !isAudienceVideoSeat(seatIndex) else {
            lastError = .underlying(.business(
                code: "VIDEO_SEAT_INVITE_ONLY",
                message: L10n.PartyRoom.videoSeatNeedsInviteToast
            ))
            return
        }
        let requirement = mediaRequirement(forSeatType: seatList.first(where: { $0.seatIndex == seatIndex })?.seatType)
        guard await requireMediaAccess(requirement, retry: { [weak self] in
            await self?.requestOnSeat(seatIndex: seatIndex)
        }) else { return }
        guard let info = roomInfo, roomState == .joined else { return }
        let pendingEntry = PendingMicEntryAnalytics(path: "proactive", expectedSeatIndex: seatIndex)
        pendingMicEntry = pendingEntry
        do {
            _ = try await PartyAPI.onSeat(
                roomId: info.id ?? "",
                seatIndex: seatIndex,
                yxRoomId: info.yxRoomId ?? "",
                roomTempId: info.roomTempIdInt
            )
            // 成功后等服务端下发 1001 → seatList 更新触发 postMikeList；不乐观更新
        } catch let api as PartyAPIError {
            if pendingMicEntry?.id == pendingEntry.id { pendingMicEntry = nil }
            let mapped = PartyRoomErrorMapper.map(api)
            lastError = mapped
            // 占用 / 空位错误码 → 全量重拉对账（02-04 §5）
            if case .seatOccupied = mapped { await reloadSeatListFromServer() }
            if case .seatEmpty = mapped { await reloadSeatListFromServer() }
        } catch {
            if pendingMicEntry?.id == pendingEntry.id { pendingMicEntry = nil }
            lastError = .underlying(.networkError)
        }
    }

    func requestDownSeat() async {
        guard let info = roomInfo, let me = selfSeat, let idx = me.seatIndex, roomState == .joined else { return }
        // 先停本地采集/发布，再尽力通知服务端下麦。失败时也维持本地关闭状态。
        deactivateLocalSeatMediaForExit()
        let pendingLeave = PendingMicLeaveAnalytics(reason: "leave", expectedSeatIndex: idx)
        pendingMicLeave = pendingLeave
        do {
            try await PartyAPI.downSeat(
                roomId: info.id ?? "",
                seatIndex: idx,
                yxRoomId: info.yxRoomId ?? "",
                roomTempId: info.roomTempIdInt
            )
        } catch {
            if pendingMicLeave?.id == pendingLeave.id { pendingMicLeave = nil }
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// 切麦：从当前麦位切换到目标 seatIndex（对齐 H5 feachExchangeSeat）。
    /// - 前置：selfSeat 存在且已 joined
    /// - targetSeatType 取自目标麦位 seatType（1=video / 2=voice），后端需知道目标位类型做校验
    /// - 成功后等服务端 1001 seat/update 广播 → seatList 更新触发 postMikeList，不乐观更新
    func requestExchangeSeat(targetSeatIndex: Int, targetSeatType: Int) async {
        guard !isAudienceMCSeat(targetSeatIndex) else {
            lastError = .underlying(.business(
                code: "MC_SEAT_RESTRICTED",
                message: L10n.Party.mcSeatCannotTake
            ))
            return
        }
        guard !isAudienceVideoSeat(targetSeatIndex) else {
            lastError = .underlying(.business(
                code: "VIDEO_SEAT_INVITE_ONLY",
                message: L10n.PartyRoom.videoSeatNeedsInviteToast
            ))
            return
        }
        let requirement = mediaRequirement(forSeatType: targetSeatType)
        guard await requireMediaAccess(requirement, retry: { [weak self] in
            await self?.requestExchangeSeat(targetSeatIndex: targetSeatIndex, targetSeatType: targetSeatType)
        }) else { return }
        guard let info = roomInfo, selfSeat != nil, roomState == .joined else { return }
        let pendingEntry = PendingMicEntryAnalytics(path: "change_mic", expectedSeatIndex: targetSeatIndex)
        pendingMicEntry = pendingEntry
        do {
            try await PartyAPI.exchangeSeat(
                roomId: info.id ?? "",
                seatIndex: targetSeatIndex,
                yxRoomId: info.yxRoomId ?? "",
                seatType: targetSeatType,
                roomTempId: info.roomTempIdInt
            )
        } catch let api as PartyAPIError {
            if pendingMicEntry?.id == pendingEntry.id { pendingMicEntry = nil }
            let mapped = PartyRoomErrorMapper.map(api)
            lastError = mapped
            if case .seatOccupied = mapped { await reloadSeatListFromServer() }
            if case .seatEmpty = mapped { await reloadSeatListFromServer() }
        } catch {
            if pendingMicEntry?.id == pendingEntry.id { pendingMicEntry = nil }
            lastError = .underlying(.networkError)
        }
    }

    /// v15 房主/房管：禁 / 解禁他人麦位（对齐 H5 feachProhibitSeat + usePartyHooks.js:1157）。
    /// - mute=true → operatorType=6（禁麦）；mute=false → operatorType=7（解禁麦）
    /// - 前置：selfRole==.owner || .admin；服务端可对语音空位预设 `seatMicrophoneEnabled`
    /// - 视频位不允许禁麦；若历史脏数据已使视频位处于禁麦，仅允许 operatorType=7 解禁
    /// - 服务端下发 1008 广播 → seat.seatMicrophoneEnabled 切换 → isSpeaking 派生自动过滤禁麦位不显 pulse
    func requestProhibitSeat(seatIndex: Int, mute: Bool) async {
        guard let info = roomInfo, roomState == .joined else { return }
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] prohibitSeat rejected: not owner/admin")
            return
        }
        guard let seat = seatList.first(where: { $0.seatIndex == seatIndex }) else {
            AppLogger.party.notice("[PartyStore] prohibitSeat rejected: seat missing index=\(seatIndex, privacy: .public)")
            return
        }
        if seat.isVideoSeat {
            guard !mute else {
                AppLogger.party.notice("[PartyStore] prohibitSeat rejected: video seat cannot be muted index=\(seatIndex, privacy: .public)")
                return
            }
            guard seat.isSeatMicrophoneProhibited else {
                AppLogger.party.notice("[PartyStore] prohibitSeat skip: video seat is already unmuted index=\(seatIndex, privacy: .public)")
                return
            }
        }
        var properties = PartyAnalytics.roomProperties(
            roomId: info.id,
            ownerId: info.ownerId,
            roomTempId: info.roomTempId
        )
        properties["seat_num"] = seatIndex
        let event = mute ? "mute_Mic" : "Unmute_Mic"
        do {
            try await PartyAPI.prohibitSeat(
                roomId: info.id ?? "",
                seatIndex: seatIndex,
                yxRoomId: info.yxRoomId ?? "",
                operatorType: mute ? 6 : 7,
                roomTempId: info.roomTempIdInt
            )
            PartyAnalytics.track(event, properties: properties)
        } catch let api as PartyAPIError {
            PartyAnalytics.track(event, properties: properties)
            lastError = PartyRoomErrorMapper.map(api)
        } catch {
            PartyAnalytics.track(event, properties: properties)
            lastError = .underlying(.networkError)
            AppLogger.party.error("[PartyStore] prohibitSeat failed: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - 房主/房管 名片卡 admin 操作(对齐 H5 party-user-card.vue)

    /// 抱上麦。对齐 H5 `feachHoldSeat({operatorType: 4, seatIndex, targetUserId})` + Android `holdSeat opType=4`
    /// - 前置:selfRole owner/admin;seatIndex 是**空位**(caller 已挑选)
    /// - 被抱上者收 IM `HOLD_ON_MIKE(4)` → updateMedia 推流
    func requestTakeToMic(seatIndex: Int, targetUserId: String) async {
        guard let info = roomInfo, roomState == .joined else { return }
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] holdSeat(take) rejected: not owner/admin")
            return
        }
        do {
            try await PartyAPI.holdSeat(
                roomId: info.id ?? "",
                seatIndex: seatIndex,
                targetUserId: targetUserId,
                yxRoomId: info.yxRoomId ?? "",
                operatorType: 4,
                roomTempId: info.roomTempIdInt
            )
        } catch let api as PartyAPIError {
            lastError = PartyRoomErrorMapper.map(api)
        } catch {
            lastError = .underlying(.networkError)
            AppLogger.party.error("[PartyStore] holdSeat(take) failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// H5 空麦位 Invite 分流：视频位邀请普通用户先发 1040；其他情况直接抱上麦。
    /// 返回 true 表示请求已成功发出，供邀请列表关闭面板。
    func requestInviteToSeat(seat: PartyRoomSeat, candidate: PartySeatInviteCandidate) async -> Bool {
        guard let info = roomInfo,
              roomState == .joined,
              let seatIndex = seat.seatIndex else { return false }
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] inviteToSeat rejected: not owner/admin")
            return false
        }
        guard let currentSeat = seatList.first(where: { $0.seatIndex == seatIndex }), !currentSeat.occupied else {
            lastError = .seatOccupied
            return false
        }
        guard !seatList.contains(where: { $0.userId == candidate.userId }) else {
            AppLogger.party.notice("[PartyStore] inviteToSeat rejected: user already on seat")
            return false
        }

        let requiresVideoInvite = currentSeat.seatType == PartyRoomSeatType.video.rawValue
            && candidate.userType == 1
        if requiresVideoInvite, isVideoSeatInviteCoolingDown(candidate.userId) {
            AppLogger.party.notice("[PartyStore] inviteToSeat rejected: video invite cooling down")
            return false
        }

        do {
            if requiresVideoInvite {
                try await PartyAPI.inviteOnSeat(
                    roomId: info.id ?? "",
                    yxRoomId: info.yxRoomId ?? "",
                    seatIndex: seatIndex,
                    targetUserId: candidate.userId,
                    roomTempId: info.roomTempIdInt
                )
                videoSeatInviteCooldowns[candidate.userId] = Date().addingTimeInterval(30)
            } else {
                try await PartyAPI.holdSeat(
                    roomId: info.id ?? "",
                    seatIndex: seatIndex,
                    targetUserId: candidate.userId,
                    yxRoomId: info.yxRoomId ?? "",
                    operatorType: 4,
                    roomTempId: info.roomTempIdInt
                )
            }
            return true
        } catch let api as PartyAPIError {
            lastError = PartyRoomErrorMapper.map(api)
        } catch {
            lastError = .underlying(.networkError)
            AppLogger.party.error("[PartyStore] inviteToSeat failed: \(String(describing: error), privacy: .private)")
        }
        return false
    }

    func isVideoSeatInviteCoolingDown(_ userId: String, now: Date = .now) -> Bool {
        guard let expiry = videoSeatInviteCooldowns[userId] else { return false }
        return expiry > now
    }

    /// 抱下麦(仅"抱下"分支)。对齐 H5 `feachHoldSeat({operatorType: 3, seatIndex, targetUserId})`
    /// - 前置:selfRole owner/admin;目标已在麦位(seatIndex/targetUserId 双传)
    /// - 主态无 toast;被抱下者收 IM "You're off mic."
    func requestKickFromMic(seatIndex: Int, targetUserId: String) async {
        guard let info = roomInfo, roomState == .joined else { return }
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] holdSeat rejected: not owner/admin")
            return
        }
        do {
            try await PartyAPI.holdSeat(
                roomId: info.id ?? "",
                seatIndex: seatIndex,
                targetUserId: targetUserId,
                yxRoomId: info.yxRoomId ?? "",
                operatorType: 3,
                roomTempId: info.roomTempIdInt
            )
        } catch let api as PartyAPIError {
            lastError = PartyRoomErrorMapper.map(api)
        } catch {
            lastError = .underlying(.networkError)
            AppLogger.party.error("[PartyStore] holdSeat failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 设置/移除房管(仅房主)。对齐 H5 `apiPartySetAdmin({roomId, userId, operationType})`
    /// - operationType 1 = 添加, 2 = 移除
    /// - API 成功后立即更新本地角色；1019/1001 广播到达后以同一状态机幂等覆盖。
    @discardableResult
    func requestSetAdmin(userId: String, add: Bool) async -> Bool {
        guard !userId.isEmpty, let info = roomInfo, roomState == .joined else { return false }
        guard selfRole == .owner else {
            AppLogger.party.notice("[PartyStore] setAdmin rejected: not owner")
            return false
        }
        guard !pendingAdminUserIds.contains(userId) else { return false }
        // 详情/座位列表可能在请求期间刷新，成功埋点使用发起动作时的目标身份快照。
        let targetUserType = seatList.first(where: { $0.userId == userId })?.userType
        pendingAdminUserIds.insert(userId)
        defer { pendingAdminUserIds.remove(userId) }
        do {
            try await PartyAPI.setAdmin(
                roomId: info.id ?? "",
                userId: userId,
                operationType: add ? 1 : 2
            )
            applyPartyRoleUpdate(
                targetUserId: userId,
                role: add ? .admin : .audience
            )
            var properties = PartyAnalytics.roomProperties(
                roomId: info.id,
                ownerId: info.ownerId,
                roomTempId: info.roomTempId
            )
            properties["admin_id"] = userId
            properties["admin_role"] = targetUserType == 2 ? "host" : "user"
            PartyAnalytics.track(add ? "b_setAdmin_success" : "b_removeAdmin_success", properties: properties)
            return true
        } catch let api as PartyAPIError {
            lastError = PartyRoomErrorMapper.map(api)
        } catch {
            lastError = .underlying(.networkError)
            AppLogger.party.error("[PartyStore] setAdmin failed: \(String(describing: error), privacy: .private)")
        }
        return false
    }

    /// 踢出房间。对齐 H5 `feachKickOutRoom({seatIndex, targetUserId, banType})`
    /// - banType 1 = 有限时长(kickOutInterval 秒), 2 = 永久
    /// - seatIndex -1 表示目标不在麦位;>=0 表示目标麦位号
    /// - 只能踢普通用户(caller 已过滤 targetRole==.audience)
    func requestKickOutRoom(seatIndex: Int, targetUserId: String, banType: Int) async {
        guard let info = roomInfo, roomState == .joined else { return }
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] kickOutRoom rejected: not owner/admin")
            return
        }
        do {
            try await PartyAPI.kickOutRoom(
                roomId: info.id ?? "",
                yxRoomId: info.yxRoomId ?? "",
                seatIndex: seatIndex,
                targetUserId: targetUserId,
                banType: banType
            )
            var properties = PartyAnalytics.roomProperties(
                roomId: info.id,
                ownerId: info.ownerId,
                roomTempId: info.roomTempId
            )
            properties["kick_userid"] = targetUserId
            properties["kick_type"] = banType == 2 ? "permanent" : "temporary"
            PartyAnalytics.track("b_kick_success", properties: properties)
        } catch let api as PartyAPIError {
            lastError = PartyRoomErrorMapper.map(api)
        } catch {
            lastError = .underlying(.networkError)
            AppLogger.party.error("[PartyStore] kickOutRoom failed: \(String(describing: error), privacy: .private)")
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
        var properties = PartyAnalytics.roomProperties(
            roomId: info.id,
            ownerId: info.ownerId,
            roomTempId: info.roomTempId
        )
        properties["seat_num"] = seatIndex
        let event = lock ? "lock_Mic" : "Unlock_Mic"
        do {
            try await PartyAPI.lockSeat(
                roomId: info.id ?? "",
                seatIndex: seatIndex,
                yxRoomId: info.yxRoomId ?? "",
                operatorType: lock ? 8 : 9,
                roomTempId: info.roomTempIdInt
            )
            PartyAnalytics.track(event, properties: properties)
        } catch let api as PartyAPIError {
            PartyAnalytics.track(event, properties: properties)
            let mapped = PartyRoomErrorMapper.map(api)
            lastError = mapped
            // 麦位状态可能已变（并发有人上麦）→ 触发 reload 对账
            if case .seatOccupied = mapped { await reloadSeatListFromServer() }
        } catch {
            PartyAnalytics.track(event, properties: properties)
            lastError = .underlying(.networkError)
            AppLogger.party.error("[PartyStore] lockSeat failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 切换自己麦克风（type=1）或摄像头（type=2）开关。
    /// 本地立即更新中间态（UI 立即反馈），服务端下发 1008 后由 reload 同步 seatList 持久态。
    func toggleSelfMedia(type: Int, enable: Bool) async {
        guard type == 1 || type == 2 || type == 3 else {
            AppLogger.party.notice("[PartyStore] updateMedia rejected: unknown type=\(type, privacy: .public)")
            return
        }
        guard let currentSeat = selfSeat else {
            AppLogger.party.notice("[PartyStore] updateMedia rejected: self is not on seat")
            return
        }
        guard type != 2 || currentSeat.isVideoSeat else {
            AppLogger.party.notice("[PartyStore] updateMedia rejected: voice seat cannot enable camera")
            return
        }
        // 视频位必须持续开麦。仅允许开启动作修复历史 `microphoneEnabled=0` 脏数据。
        if type == 1, !enable, currentSeat.isVideoSeat {
            AppLogger.party.notice("[PartyStore] updateMedia rejected: video seat cannot mute microphone")
            return
        }
        if enable {
            let requirement = mediaRequirement(forSeatType: currentSeat.seatType)
            guard await requireMediaAccess(requirement, retry: { [weak self] in
                await self?.toggleSelfMedia(type: type, enable: enable)
            }) else { return }
        }
        guard let info = roomInfo, let me = selfSeat, let idx = me.seatIndex else { return }
        applyLocalMediaIntent(type: type, enable: enable)
        postMikeList()
        var properties = PartyAnalytics.roomProperties(
            roomId: info.id,
            ownerId: info.ownerId,
            roomTempId: info.roomTempId
        )
        properties["Operation"] = enable ? "turnon" : "turnoff"
        // 对齐 H5：这是已生效的本地用户点击，不以异步接口成功与否定义点击漏斗。
        PartyAnalytics.track(type == 1 ? "microphone_click" : "camera_click", properties: properties)
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
        guard await requireMediaAccess(.liveStream, retry: { [weak self] in
            await self?.acceptVideoSeatInvite()
        }) else { return }
        guard let invite = pendingVideoSeatInvite, let info = roomInfo else { return }
        pendingVideoSeatInvite = nil
        let pendingEntry = PendingMicEntryAnalytics(path: "invite", expectedSeatIndex: invite.seatIndex)
        pendingMicEntry = pendingEntry
        var didAcceptInvite = false
        do {
            try await PartyAPI.respondInvite(
                roomId: info.id ?? "",
                yxRoomId: info.yxRoomId ?? "",
                seatIndex: invite.seatIndex,
                inviteId: invite.inviteId,
                action: 1,
                roomTempId: info.roomTempIdInt
            )
            didAcceptInvite = true
            // 接受成功 → 自动开麦+摄像头（安卓 PartyRoomDataManager 行为）
            try await PartyAPI.updateMedia(
                roomId: info.id ?? "",
                seatIndex: invite.seatIndex,
                type: 3,
                enable: true,
                yxRoomId: info.yxRoomId ?? ""
            )
            trackVideoCameraAutoOn(info: info, invite: invite, status: "OpenSuccess")
        } catch {
            if didAcceptInvite {
                // H5 在邀请接受成功但自动开摄像头失败时上报 DeviceError；不重试或改变已上麦状态。
                trackVideoCameraAutoOn(info: info, invite: invite, status: "DeviceError")
            }
            if pendingMicEntry?.id == pendingEntry.id { pendingMicEntry = nil }
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
            AppLogger.party.error("[PartyStore] acceptInvite failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func trackVideoCameraAutoOn(
        info: PartyRoomInfo,
        invite: PartyVideoSeatInvite,
        status: String
    ) {
        var properties = PartyAnalytics.roomProperties(
            roomId: info.id,
            ownerId: info.ownerId,
            roomTempId: info.roomTempId
        )
        properties["user_id"] = SessionStore.shared.user?.userId.map(String.init) ?? ""
        properties["seat_index"] = invite.seatIndex
        properties["camera_status"] = status
        properties["from_invite"] = true
        PartyAnalytics.track("b_video_camera_auto_on", properties: properties)
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

    /// 视频位邀请倒计时结束：主动回传 `action=3`，让服务端清理 token 并向邀请方发送 1043。
    /// 与 H5 `video-seat-invite-popup` 一致；请求失败时仍关闭本地弹窗，后端 TTL 是最终兜底。
    func timeoutVideoSeatInvite() async {
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
                action: 3,
                roomTempId: info.roomTempIdInt
            )
        } catch {
            AppLogger.party.error("[PartyStore] timeoutInvite failed: \(String(describing: error), privacy: .private)")
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
            replaceSeatListPreservingGiftValues(seats)
            postMikeList()
            AppLogger.party.info("[PartyStore] seatList reloaded count=\(seats.count, privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyStore] reload seatList failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// F-1a Task 9 v2 (2026-07-17)：PartyBattle SELECTING 开始 / PK ENDED 时清**所有已占麦位** giftValueCount
    ///
    /// 对齐 H5 partyBattle.ts:332-336 + :541-543 注释：
    /// > "原先只清红/蓝队快照成员，遗漏中立位、以及 SELECTING 之后经 1101/审批中途入队的人，
    /// >  导致这些麦位残留历史累计值。改为清全部已占麦位，覆盖所有参与展示的麦位。"
    ///
    /// 调用点：`PartyBattleStore.onSelectingStart` + `PartyBattleStore.onEnd`
    ///
    /// PartyRoomSeat 所有字段 `let`（immutable struct），通过 Codable round-trip 覆盖 `giftValueCount`
    /// 后 replace seatList[i]（保持 model 定义不动，避免侵入其他模块字段可变性契约）。
    func resetAllSeatGiftValue() {
        var updated = 0
        for i in seatList.indices {
            guard seatList[i].userId != nil else { continue }
            let curr = seatList[i].giftValueCount ?? 0
            guard curr != 0 else { continue }
            guard let reset = try? Self.replaceGiftValueCount(seatList[i], with: 0) else {
                continue
            }
            seatList[i] = reset
            updated += 1
        }
        AppLogger.party.info(
            "[PartyStore] resetAllSeatGiftValue updated=\(updated, privacy: .public)")
    }

    /// Codable round-trip 覆盖 seat 单字段（let 字段替代方案）
    private static func replaceGiftValueCount(_ seat: PartyRoomSeat, with newValue: Double) throws -> PartyRoomSeat {
        let data = try JSONEncoder().encode(seat)
        var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        dict["giftValueCount"] = newValue
        let updated = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(PartyRoomSeat.self, from: updated)
    }

    /// 服务端的 seat/list / 1001 全量麦位消息通常不包含 `giftValueCount`。
    /// 同一用户仍在麦时保留本地 2049 累加值；换人或新上麦不迁移，确保从 0 开始。
    private func replaceSeatListPreservingGiftValues(_ incomingSeats: [PartyRoomSeat]) {
        seatList = PartySeatGiftValue.preservingLocalValues(
            from: seatList,
            in: incomingSeats
        )
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

        // 小窗期间仍保持远端音频/麦位对账，但不能被后续的 1001 或 RTC 回调重新打开本地相机和视频推流。
        guard !isMinimized else {
            disableLocalVideoCapture()
            rtc.disableVideoSeat()
            return
        }

        // 本地主动下麦的请求还未被服务端确认（含接口失败）时，旧 seatList 不得重新启用媒体。
        if isLocalSeatExitPending, mySelf != nil {
            deactivateLocalSeatMediaForExit()
            return
        }
        if mySelf == nil {
            resetLocalMediaOverrides()
        }

        // 2. 自己在麦 / 不在麦
        if let me = mySelf {
            // 服务端抱上麦/模板切换也会直接更新 seatList，不能只依赖点击上麦入口。
            // 未授权时保持本地 RTC 下麦，确认授权后重跑对账再开启采集。
            let requirement = mediaRequirement(forSeatType: me.seatType)
            guard MediaPermissionGate.hasAccess(for: requirement) else {
                mediaPermissionAlertRequirement = requirement
                pendingMediaPermissionAction = { [weak self] in
                    await self?.resumeLocalMediaAfterPermissionGranted()
                }
                rtc.downSeat()
                disableLocalVideoCapture()
                return
            }
            // 上麦 = 主播工作态；对齐直播/匹配的自动上线行为
            // （LiveSettingsView.onAppear / RootView.ensureUserOnlineHook）
            if !OnlineStatusStore.shared.userSetOnline {
                OnlineStatusStore.shared.setUserSetOnline(true)
            }
            let seatType = me.typed ?? .voice
            rtc.upperSeat(seatType: seatType)
            let micEnabled = (me.microphoneEnabled ?? 0) == 1
                && (me.seatMicrophoneEnabled ?? 0) == 1
                && !isLocalMicrophoneDisabled
            rtc.muteLocalMicrophone(!micEnabled)
            // 视频位：启 RTC 视频通道 + CameraManager 订阅推帧；
            // 摄像头开关由 microphoneEnabled 同侪字段 cameraEnabled 决定（M5 接入）
            if seatType == .video {
                let camEnabled = (me.cameraEnabled ?? 0) == 1
                if camEnabled && !isLocalCameraDisabled {
                    rtc.enableVideoSeat()
                    enableLocalVideoCapture()
                } else {
                    disableLocalVideoCapture()
                    rtc.disableVideoSeat()
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

    private func resumeLocalMediaAfterPermissionGranted() async {
        postMikeList()
    }

    /// 下麦/退房前的本地优先收尾。该方法不发网络请求，且可安全重复调用。
    private func deactivateLocalSeatMediaForExit() {
        isLocalSeatExitPending = true
        isLocalMicrophoneDisabled = true
        isLocalCameraDisabled = true
        disableLocalVideoCapture()
        rtc.downSeat()
    }

    /// 媒体开关的本地意图优先于尚未同步的服务端麦位数据。
    private func applyLocalMediaIntent(type: Int, enable: Bool) {
        switch type {
        case 1:
            isLocalMicrophoneDisabled = !enable
            rtc.muteLocalMicrophone(!enable)
        case 2:
            isLocalCameraDisabled = !enable
            if !enable {
                disableLocalVideoCapture()
                rtc.disableVideoSeat()
            }
        case 3:
            isLocalMicrophoneDisabled = !enable
            isLocalCameraDisabled = !enable
            rtc.muteLocalMicrophone(!enable)
            if !enable {
                disableLocalVideoCapture()
                rtc.disableVideoSeat()
            }
        default:
            AppLogger.party.notice("[PartyStore] applyLocalMediaIntent ignored unknown type=\(type, privacy: .public)")
        }
    }

    private func resetLocalMediaOverrides() {
        isLocalSeatExitPending = false
        isLocalMicrophoneDisabled = false
        isLocalCameraDisabled = false
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

    /// 热门任务仅在本人位于视频麦且摄像头实际开启时本地递增倒计时。
    /// Android 的任务计时门控只依赖视频麦和 `cameraEnabled`；`seatCameraEnabled`
    /// 并非该任务接口的条件，额外判断会让正常推流中的主播无法获得本地进度刷新。
    var isEligibleForHotTaskTiming: Bool {
        guard roomState == .joined,
              let seat = selfSeat,
              seat.isVideoSeat,
              (seat.cameraEnabled ?? 0) == 1,
              isLocalCameraActive,
              !isLocalCameraDisabled
        else { return false }
        return true
    }

    /// 取当前视频麦的美颜后帧供热门任务服务端进行露脸校验。
    func hotTaskFaceSnapshot() async -> PartyHotTaskFaceSnapshot? {
        guard isEligibleForHotTaskTiming,
              let roomId = roomInfo?.id, !roomId.isEmpty,
              let seatIndex = selfSeat?.seatIndex,
              let camera,
              let imageData = await camera.latestFrameJPEGData()
        else { return nil }
        return PartyHotTaskFaceSnapshot(roomId: roomId, seatIndex: seatIndex, imageData: imageData)
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
        guard selfRole == .owner else {
            AppLogger.party.notice("[PartyStore] switchRoomMode rejected: not owner/platformAdmin")
            return
        }
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
            var properties = PartyAnalytics.roomProperties(
                roomId: info.id,
                ownerId: info.ownerId,
                roomTempId: String(tempId)
            )
            PartyAnalytics.track("b_changeMode", properties: properties)
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
                replaceSeatListPreservingGiftValues(s)
                postMikeList()
            }
            return
        }

        // 模板广播会直接替换整张麦位表。先记录旧状态，didSet 才能在本次替换把实际被移除的
        // 麦位记为 modeChange；若新模板仍保留本人麦位，随后会清掉该 pending 原因。
        if let selfSeat {
            pendingMicLeave = PendingMicLeaveAnalytics(
                reason: "modeChange",
                expectedSeatIndex: selfSeat.seatIndex
            )
            // seats 可能要通过异步 seat/list 重拉才能确定。先停止旧视频位采集，避免旧模板的
            // CameraManager 在网络往返期间继续推帧；postMikeList 会按新座位表按需恢复。
            disableLocalVideoCapture()
            rtc.disableVideoSeat()
        }

        // 步骤 3：全量替换 seatList + RTC bindings 对账（等价 postMikeList）
        if let s = seats {
            replaceSeatListPreservingGiftValues(s)
            postMikeList()
            if selfSeat != nil {
                pendingMicLeave = nil
            }
        } else {
            // IM payload 缺 seats（或本地兜底路径）→ 全量重拉兜底
            Task { [weak self] in await self?.reloadSeatListFromServer() }
        }

        // 步骤 4：公屏落系统消息（v3：kind = .mode → PublicChatVariant.partyModeSwitch）
        chatRouter.postSystemMode(L10n.Party.roomModeSystemMsg)

        // 步骤 5：清 Mic Application 相关状态（服务端切模板时会清队列）
        applyingTimeoutTask?.cancel()
        applyingTimeoutTask = nil
        myApplyInfo = .init()
        micApplicationsState = .empty
        queueSeatNum = 0
        pendingApproveSeatIndex = []

        // 步骤 6：更新 roomInfo.roomTempId（供后续 IM 幂等判断命中）
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
            // 对齐安卓 §3.3「按钮态按 myIndex > 0 显示"申请/放弃"」+ §5「弹窗以 myIndex > 0 为准」：
            // 服务端权威 myIndex 覆盖本地（kill app 重进 myApplyInfo 已 reset 但服务端队列还在时恢复）；
            // 仅在服务端 > 0 时覆盖以避免刚 applyMic 完的本地 inIndex 被"records 空 → myIndex 0"清掉
            if resp.myIndex > 0, myApplyInfo.inIndex == 0 {
                myApplyInfo.inIndex = resp.myIndex
            }
            if resp.records.isEmpty {
                micApplicationsState = .empty
            } else {
                micApplicationsState = .loaded(resp.records)
            }
            AppLogger.party.info("[PartyStore] getQueueSeatList ok total=\(resp.totalNum, privacy: .public) rec=\(resp.records.count, privacy: .public) myIndex=\(resp.myIndex, privacy: .public)")
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
        guard !isAudienceMCSeat(seatIndex) else {
            lastError = .underlying(.business(
                code: "MC_SEAT_RESTRICTED",
                message: L10n.Party.mcSeatCannotTake
            ))
            return
        }
        guard !isAudienceVideoSeat(seatIndex) else {
            lastError = .underlying(.business(
                code: "VIDEO_SEAT_INVITE_ONLY",
                message: L10n.PartyRoom.videoSeatNeedsInviteToast
            ))
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
        let pendingEntry = PendingMicEntryAnalytics(path: "proactive", expectedSeatIndex: seatIndex)
        pendingMicEntry = pendingEntry

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
            var properties = PartyAnalytics.roomProperties(
                roomId: info.id,
                ownerId: info.ownerId,
                roomTempId: info.roomTempId
            )
            properties["seat_num"] = seatIndex
            PartyAnalytics.track("b_applySeat", properties: properties)
            startApplyingTimeoutTask()
        } catch let api as PartyAPIError {
            if pendingMicEntry?.id == pendingEntry.id { pendingMicEntry = nil }
            let mapped = PartyRoomErrorMapper.map(api)
            lastError = mapped
            AppLogger.party.error("[PartyStore] applyMic failed: \(String(describing: api), privacy: .private)")
            // 对齐安卓 MicApplicationListDialog §3.3：10008(麦位被占)/10009(麦位空) → 全量重拉对账
            // （复用 requestOnSeat 的 pattern；不重试，仅刷新麦位）
            if case .seatOccupied = mapped { await reloadSeatListFromServer() }
            if case .seatEmpty = mapped { await reloadSeatListFromServer() }
        } catch {
            if pendingMicEntry?.id == pendingEntry.id { pendingMicEntry = nil }
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
            pendingMicEntry = nil
            applyingTimeoutTask?.cancel()
            applyingTimeoutTask = nil
            AppLogger.party.info("[PartyStore] cancelMyMicApplication ok")
            PartyAnalytics.track(
                "b_applySeat_cancel",
                properties: PartyAnalytics.roomProperties(
                    roomId: info.id,
                    ownerId: info.ownerId,
                    roomTempId: info.roomTempId
                )
            )
        } catch {
            AppLogger.party.error("[PartyStore] giveUpQueueSeat failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// 房主/房管批准申请（spec §2）。seatIndex nil 时挑首空位（排除 pendingApproveSeatIndex 防并发冲突）。
    /// 无可用位 → toast + 不调接口（spec §2 R7）。
    func agreeMicApplication(userId: String, seatIndex: Int?) async {
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] agreeMic rejected: not owner/admin")
            return
        }
        // spec §0 throttle（per-userId）：同一申请者防连点重复批准；不同 userId 允许并发（seat 占位靠 pendingApproveSeatIndex）
        guard !pendingApproveUserId.contains(userId) else {
            AppLogger.party.notice("[PartyStore] agreeMic skip: userId=\(userId, privacy: .public) already in-flight")
            return
        }
        guard let info = roomInfo, roomState == .joined else { return }
        // 目标 seatIndex：外部指定优先；否则挑首空位排除已占位
        // 对齐安卓 MicApplicationInfo.canOnHostSeat：从当前列表拿申请人对应 flag；true 允许挑接待位
        let allowHostSeat: Bool = {
            let items: [PartyMicApplication]
            switch micApplicationsState {
            case .loaded(let arr), .refreshing(let arr): items = arr
            default: items = []
            }
            return items.first { $0.userId == userId }?.canOnHostSeat ?? false
        }()
        let targetIndex: Int
        if let idx = seatIndex {
            targetIndex = idx
        } else if let idx = firstAvailableSeatIndexExcludingPending(allowHostSeat: allowHostSeat) {
            targetIndex = idx
        } else {
            AppLogger.party.notice("[PartyStore] agreeMic no available seat")
            lastError = .underlying(.business(code: "MIC_NO_SEAT", message: L10n.Party.micApplicationNoSeatAvailable))
            return
        }

        // 排麦批准只允许进入语音位。视频位必须改走 1040 邀请流程，避免外部调用绕过选座页禁用态。
        guard let targetSeat = seatList.first(where: { $0.seatIndex == targetIndex }),
              !targetSeat.occupied,
              !targetSeat.isVideoSeat,
              !pendingApproveSeatIndex.contains(targetIndex),
              allowHostSeat || !targetSeat.isMCSeat else {
            AppLogger.party.notice("[PartyStore] agreeMic invalid target seat=\(targetIndex, privacy: .public)")
            lastError = .underlying(.business(
                code: "MIC_INVALID_APPROVE_SEAT",
                message: L10n.Party.micApplicationNoSeatAvailable
            ))
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
                operatorType: 1,  // agreeSeat 固定操作码 1（对齐 H5 apiPartyAgreeSeat）；服务端从 token role 判权限，不按角色变化
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
    /// 幂等 per-userId：同 userId 快速连点只发一次；不同 userId 允许并发（对齐 approve 路径）
    func refuseMicApplication(userId: String) async {
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] refuseMic rejected: not owner/admin")
            return
        }
        guard !isBusyRefuseUserIds.contains(userId) else {
            AppLogger.party.notice("[PartyStore] refuseMic skip: userId=\(userId, privacy: .public) already in-flight")
            return
        }
        guard let info = roomInfo, roomState == .joined else { return }
        isBusyRefuseUserIds.insert(userId)
        defer { isBusyRefuseUserIds.remove(userId) }
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

    /// 房主/房管切换 Mic Application 开关（spec §2）。isBusy 幂等。
    /// UI 层负责前置协议弹窗（首次切换时基于 autoEnter{On,Off}Application flag 判断）。
    /// 成功后立即回写本地状态（对齐 H5），1021 广播作为跨端最终同步。
    func toggleMicApplicationSwitch(enable: Bool) async {
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] toggleMicApplicationSwitch rejected: not room manager")
            return
        }
        guard !isBusyMicSwitch else {
            AppLogger.party.notice("[PartyStore] toggleMicApplicationSwitch skip: busy")
            return
        }
        guard let info = roomInfo, roomState == .joined else { return }
        isBusyMicSwitch = true
        defer { isBusyMicSwitch = false }

        do {
            try await PartyAPI.updateOnSeatEnable(roomId: info.id ?? "", enable: enable ? 1 : 0)
            guard roomInfo?.id == info.id else { return }
            micApplicationSwitchOn = enable
            roomInfo = info.withUpdated(onSeatApplySwitch: enable)
            AppLogger.party.info("[PartyStore] updateOnSeatEnable ok enable=\(enable, privacy: .public)")
            PartyAnalytics.track(
                enable ? "b_applySeat_open" : "b_applySeat_close",
                properties: PartyAnalytics.roomProperties(
                    roomId: info.id,
                    ownerId: info.ownerId,
                    roomTempId: info.roomTempId
                )
            )
        } catch {
            AppLogger.party.error("[PartyStore] updateOnSeatEnable failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    // MARK: - Room Music (H5 room-mana-popup.vue)

    /// 拉取房间音乐的实际 ON/OFF 状态。进房时调用；仅在音乐功能对当前房开放时请求。
    func loadRoomMusicSettings() async {
        guard let info = roomInfo,
              let roomId = info.id,
              !roomId.isEmpty,
              info.isRoomMusicAvailable else {
            isRoomMusicEnabled = false
            roomMusicSettings = .empty
            return
        }

        do {
            let settings = try await PartyAPI.getMusicSettings(roomId: roomId)
            // 进房/退房期间的旧请求不能覆盖新房状态。
            guard roomInfo?.id == roomId else { return }
            applyRoomMusicSettings(settings)
            AppLogger.party.info("[PartyStore] music settings loaded enabled=\(settings.isEnabled, privacy: .public)")
        } catch is CancellationError {
            return
        } catch {
            // 读取失败时保持保守 OFF；入口仍保留，房主可以重试切换。
            AppLogger.party.notice("[PartyStore] load music settings failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 房主/房管切换房间音乐。成功后乐观回写，与 H5 `switchEnableMusic` 一致。
    func toggleRoomMusic() async {
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] toggleRoomMusic rejected: not room manager")
            return
        }
        guard !isBusyRoomMusicSwitch,
              let info = roomInfo,
              roomState == .joined,
              info.isRoomMusicAvailable,
              let roomId = info.id,
              !roomId.isEmpty else {
            return
        }

        let targetEnabled = !isRoomMusicEnabled
        isBusyRoomMusicSwitch = true
        defer { isBusyRoomMusicSwitch = false }
        do {
            try await PartyAPI.setMusicEnabled(
                roomId: roomId,
                yxRoomId: info.yxRoomId ?? "",
                enabled: targetEnabled
            )
            guard roomInfo?.id == roomId else { return }
            applyRoomMusicSettings(roomMusicSettings.updating(
                playStatus: 0,
                isEnabled: targetEnabled
            ))
            AppLogger.party.info("[PartyStore] music enabled=\(targetEnabled, privacy: .public)")
        } catch {
            AppLogger.party.error("[PartyStore] toggle music failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// 普通用户只控制自己的音乐流收听；房主/房管打开的是管理面板，不调用本方法。
    func toggleRoomMusicAudible() {
        guard roomState == .joined,
              roomMusicSettings.isEnabled,
              roomMusicSettings.playStatus == 1,
              let roomId = roomInfo?.id,
              let agoraUID = UInt(roomId) else {
            return
        }
        isRoomMusicAudible.toggle()
        rtc.setRemoteAudio(uid: agoraUID, enabled: isRoomMusicAudible)
        AppLogger.party.info("[PartyStore] room music audible=\(self.isRoomMusicAudible, privacy: .public)")
    }

    /// 管理员从音乐面板选中歌曲。与 H5 一致，先乐观更新，接口失败再回滚。
    func playRoomMusic(_ item: PartyMusicItem) async {
        guard let info = roomInfo,
              let roomId = info.id,
              !roomId.isEmpty,
              roomState == .joined,
              isRoomMusicEnabled,
              isRoomManager,
              !isBusyRoomMusicControl else { return }
        let previous = roomMusicSettings
        let musicType = item.musicType == 0 ? 1 : item.musicType
        let next = previous.updating(
            currentSongId: item.id,
            songName: item.songName,
            musicType: musicType,
            playStatus: 1
        )
        isBusyRoomMusicControl = true
        applyRoomMusicSettings(next)
        defer { isBusyRoomMusicControl = false }
        do {
            try await PartyAPI.playMusic(
                songId: item.id,
                roomId: roomId,
                musicType: musicType,
                playMode: next.playMode,
                volume: next.volume,
                actionType: 1
            )
        } catch {
            guard roomInfo?.id == roomId else { return }
            applyRoomMusicSettings(previous)
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
            AppLogger.party.error("[PartyStore] play room music failed: \(String(describing: error), privacy: .private)")
        }
    }

    func toggleRoomMusicPlayback() async {
        guard let songId = roomMusicSettings.currentSongId,
              !songId.isEmpty else { return }
        let actionType = roomMusicSettings.playStatus == 1 ? 2 : 1
        await updateRoomMusicPlayback(songId: songId, actionType: actionType)
    }

    func updateRoomMusicVolume(_ volume: Int) async {
        await updateRoomMusicConfiguration(volume: volume)
    }

    func cycleRoomMusicPlayMode() async {
        let nextMode = roomMusicSettings.playMode == 3 ? 1 : max(roomMusicSettings.playMode + 1, 1)
        await updateRoomMusicConfiguration(playMode: nextMode)
    }

    /// 本地音乐上传：校验格式/大小，上传 OSS 后写入 Party 音乐库。
    @discardableResult
    func uploadLocalRoomMusic(fileURL: URL) async -> Bool {
        guard isRoomManager,
              let roomId = roomInfo?.id,
              !roomId.isEmpty,
              !isUploadingRoomMusic else { return false }

        let extensionName = fileURL.pathExtension.lowercased()
        let allowedExtensions: Set<String> = ["mp3", "wav", "flac", "aac", "m4a", "ogg"]
        guard allowedExtensions.contains(extensionName) else {
            AppToastCenter.shared.show(L10n.Party.musicInvalidFormat)
            return false
        }

        isUploadingRoomMusic = true
        defer { isUploadingRoomMusic = false }
        do {
            let payload = try await Self.readLocalMusicFile(fileURL: fileURL, fileFormat: extensionName)
            guard payload.data.count <= 10 * 1024 * 1024 else {
                AppToastCenter.shared.show(L10n.Party.musicFileTooLarge)
                return false
            }
            let credential = try await OssCredentialService.shared.getOssUploadParam()
            let remoteURL = try await OssUploadService.shared.uploadPublicFile(
                fileData: payload.data,
                credential: credential,
                objectKey: Self.roomMusicObjectKey(fileFormat: extensionName),
                contentType: Self.musicContentType(fileFormat: extensionName)
            )
            try await PartyAPI.addLocalMusic(
                roomId: roomId,
                music: PartyLocalMusicUpload(
                    songName: payload.songName,
                    musicURL: remoteURL,
                    durationSeconds: payload.durationSeconds,
                    fileFormat: extensionName
                )
            )
            AppToastCenter.shared.show(L10n.Party.musicUploadSucceeded)
            return true
        } catch is CancellationError {
            return false
        } catch {
            AppLogger.party.error("[PartyStore] upload local music failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.Party.musicUploadFailed)
            return false
        }
    }

    func deleteLocalRoomMusic(ids: [String]) async -> Bool {
        guard isRoomManager,
              let roomId = roomInfo?.id,
              !roomId.isEmpty,
              !ids.isEmpty else { return false }
        do {
            try await PartyAPI.deleteLocalMusic(roomId: roomId, musicIDs: ids)
            AppToastCenter.shared.show(L10n.Party.musicDeleteSucceeded)
            return true
        } catch {
            AppLogger.party.error("[PartyStore] delete local music failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.Party.musicDeleteFailed)
            return false
        }
    }

    func applyRoomMusicUpdate(_ payload: [String: Any], switchOnly: Bool) {
        let next = roomMusicSettings.applying(payload: payload)
        applyRoomMusicSettings(next)
        AppLogger.party.info("[PartyStore] music IM switchOnly=\(switchOnly, privacy: .public) enabled=\(next.isEnabled, privacy: .public) play=\(next.playStatus, privacy: .public)")
    }

    func applyRoomMusicAvailability(_ payload: [String: Any]) {
        guard let enabled = PartyValueNormalizer.intify(payload["roomMusicSwitch"] ?? payload["roomMusicSwitc"]),
              let info = roomInfo else { return }
        roomInfo = info.withUpdated(roomMusicSwitc: enabled)
        if enabled == 0 {
            applyRoomMusicSettings(roomMusicSettings.updating(playStatus: 0, isEnabled: false))
        }
    }

    private var isRoomManager: Bool {
        selfRole == .owner || selfRole == .admin
    }

    private func updateRoomMusicPlayback(songId: String, actionType: Int) async {
        guard let info = roomInfo,
              let roomId = info.id,
              !roomId.isEmpty,
              roomState == .joined,
              isRoomManager,
              isRoomMusicEnabled,
              !isBusyRoomMusicControl else { return }
        let previous = roomMusicSettings
        let next = previous.updating(playStatus: actionType == 1 ? 1 : 0)
        isBusyRoomMusicControl = true
        applyRoomMusicSettings(next)
        defer { isBusyRoomMusicControl = false }
        do {
            try await PartyAPI.playMusic(
                songId: songId,
                roomId: roomId,
                musicType: next.musicType,
                playMode: next.playMode,
                volume: next.volume,
                actionType: actionType
            )
        } catch {
            guard roomInfo?.id == roomId else { return }
            applyRoomMusicSettings(previous)
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    private func updateRoomMusicConfiguration(volume: Int? = nil, playMode: Int? = nil) async {
        guard let info = roomInfo,
              let roomId = info.id,
              !roomId.isEmpty,
              let songId = roomMusicSettings.currentSongId,
              !songId.isEmpty,
              roomState == .joined,
              isRoomManager,
              isRoomMusicEnabled,
              !isBusyRoomMusicControl else { return }
        let previous = roomMusicSettings
        let next = previous.updating(volume: volume, playMode: playMode)
        isBusyRoomMusicControl = true
        applyRoomMusicSettings(next)
        defer { isBusyRoomMusicControl = false }
        do {
            try await PartyAPI.updateMusic(
                songId: songId,
                roomId: roomId,
                volume: next.volume,
                playMode: next.playMode,
                playStatus: next.playStatus
            )
        } catch {
            guard roomInfo?.id == roomId else { return }
            applyRoomMusicSettings(previous)
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    private func applyRoomMusicSettings(_ settings: PartyMusicSettings) {
        roomMusicSettings = settings
        isRoomMusicEnabled = settings.isEnabled
        if (!settings.isEnabled || settings.playStatus != 1), let agoraUID = roomMusicAgoraUID {
            rtc.setRemoteAudio(uid: agoraUID, enabled: false)
        } else if let agoraUID = roomMusicAgoraUID {
            rtc.setRemoteAudio(uid: agoraUID, enabled: isRoomMusicAudible)
        }
    }

    private var roomMusicAgoraUID: UInt? {
        guard let roomId = roomInfo?.id else { return nil }
        return UInt(roomId)
    }

    private struct LocalMusicFilePayload: Sendable {
        let data: Data
        let songName: String
        let durationSeconds: Int
    }

    private nonisolated static func readLocalMusicFile(fileURL: URL, fileFormat: String) async throws -> LocalMusicFilePayload {
        try await Task.detached(priority: .userInitiated) {
            let accessGranted = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessGranted { fileURL.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: fileURL)
            let asset = AVURLAsset(url: fileURL)
            let duration = try await asset.load(.duration)
            let stem = fileURL.deletingPathExtension().lastPathComponent
            return LocalMusicFilePayload(
                data: data,
                songName: stem.isEmpty ? "music" : stem,
                durationSeconds: max(Int(duration.seconds.rounded()), 0)
            )
        }.value
    }

    private nonisolated static func roomMusicObjectKey(fileFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let date = formatter.string(from: Date())
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "party/music/\(date)/\(uuid).\(fileFormat)"
    }

    private nonisolated static func musicContentType(fileFormat: String) -> String {
        switch fileFormat {
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "m4a": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        default: return "audio/mpeg"
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
        guard selfRole == .owner || selfRole == .admin else { return }
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
        guard selfRole == .owner || selfRole == .admin else {
            AppLogger.party.notice("[PartyStore] removeFromBlocklist rejected: not owner/admin")
            throw PartyAPIError.networkError
        }
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
        guard selfRole == .owner else {
            AppLogger.party.notice("[PartyStore] lockRoom rejected: not owner/platformAdmin")
            return
        }
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
            trackLockRoomSetting(info: info, result: "success")
        } catch {
            trackLockRoomSetting(info: info, result: "error")
            AppLogger.party.error("[PartyStore] lockRoom failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// 房主解锁房间（spec §3）。isBusy 幂等；成功后本地乐观回写 `lockFlag=0`。
    /// - 无二次确认：tap Lock Room 已锁态 → 直接调（对齐 H5 无二次确认弹窗）
    /// - 无密码字段：对齐 H5 `feachLockRoom({ lockFlag: 0 })` payload 省略 password
    func unlockRoom() async {
        guard selfRole == .owner else {
            AppLogger.party.notice("[PartyStore] unlockRoom rejected: not owner/platformAdmin")
            return
        }
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
            trackLockRoomSetting(info: info, result: "success")
        } catch {
            trackLockRoomSetting(info: info, result: "error")
            AppLogger.party.error("[PartyStore] unlockRoom failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// 锁房密码属于凭据，事件仅上报结果和房间上下文，绝不复制 H5 的明文 password 字段。
    private func trackLockRoomSetting(info: PartyRoomInfo, result: String) {
        var properties = PartyAnalytics.roomProperties(
            roomId: info.id,
            ownerId: info.ownerId,
            roomTempId: info.roomTempId
        )
        properties["result"] = result
        PartyAnalytics.track("lockRoom_setting", properties: properties)
    }

    // MARK: - Room Mute (F 期便利功能, 2026-07-17)

    /// F 期便利功能：Room Mute 全房静音切换（本地 SDK 行为，无接口）。
    /// - 幂等：直接翻转 `isRoomMuted` + 调 RTC `setMuteAllRemoteAudio`
    /// - 权限：任何观众都可静音自己听到的房间音频（对齐 H5 room-mana-popup 中的 mute 项无角色限制）
    /// - 退房 resetState 时自动归 false（顺带重置 SDK 本地音量到 100）
    func toggleRoomMute() {
        guard roomState == .joined else { return }
        isRoomMuted.toggle()
        rtc.setMuteAllRemoteAudio(isRoomMuted)
        AppLogger.party.info("[PartyStore] toggleRoomMute -> \(self.isRoomMuted, privacy: .public)")
    }

    // MARK: - Room Announcement Edit (F 期房主管理批, 2026-07-17)

    /// 房主/平台超管编辑房间通告（对齐 H5 announcement-popup.vue 房主编辑分支 + 差异文档 §权限矩阵
    /// "修改房间信息/公告/背景 仅房主+超管"）。
    ///
    /// - 权限：`selfRole == .owner`（平台超管已在 selfRole 层提权，不需额外 isPlatformAdmin 判定）
    /// - API：走独立 `editAnnouncement`，不能复用 Settings 的 `updateRoom(greetingMessage:)`
    /// - 幂等：`isBusyAnnouncement` 防连点
    /// - 成功后本地回写 `roomInfo.announcement`；服务端会以 1049 广播到公屏
    /// - **返回 Bool**：view 层用于 toast + 关闭编辑态判定（对齐 setMCSeat 同款 verify P0 fix）
    ///
    @discardableResult
    func updateAnnouncement(text: String) async -> Bool {
        guard selfRole == .owner else {
            AppLogger.party.notice("[PartyStore] updateAnnouncement rejected: not owner/platformAdmin")
            return false
        }
        guard !isBusyAnnouncement else {
            AppLogger.party.notice("[PartyStore] updateAnnouncement skip: busy")
            return false
        }
        guard let info = roomInfo, roomState == .joined else {
            AppLogger.party.notice("[PartyStore] updateAnnouncement skip: not joined")
            return false
        }
        guard let roomId = info.id, !roomId.isEmpty else {
            AppLogger.party.error("[PartyStore] updateAnnouncement bad roomId")
            lastError = .underlying(.networkError)
            return false
        }
        let announcement = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !announcement.isEmpty, announcement != info.announcement else {
            return false
        }
        isBusyAnnouncement = true
        defer { isBusyAnnouncement = false }
        do {
            try await PartyAPI.editAnnouncement(roomId: roomId, announcement: announcement)
            roomInfo = info.withUpdated(announcement: announcement)
            AppLogger.party.info("[PartyStore] updateAnnouncement ok len=\(announcement.count, privacy: .public)")
            return true
        } catch {
            AppLogger.party.error("[PartyStore] updateAnnouncement failed: \(String(describing: error), privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
            return false
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
        guard selfRole == .owner else {
            AppLogger.party.notice("[PartyStore] setMCSeat rejected: not owner/platformAdmin")
            return false
        }
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
        guard selfRole == .owner else {
            AppLogger.party.notice("[PartyStore] closeMCSeat rejected: not owner/platformAdmin")
            return false
        }
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
    /// - Parameter allowHostSeat: 是否允许挑接待位（对齐安卓 MicApplicationInfo.canOnHostSeat 语义）；
    ///   默认 false（接待位是 MC 专用位；房主批准普通申请不应自动挑到接待位）
    private func firstAvailableSeatIndexExcludingPending(allowHostSeat: Bool = false) -> Int? {
        for seat in seatList {
            guard let idx = seat.seatIndex, idx > 0 else { continue }
            if seat.occupied { continue }
            if pendingApproveSeatIndex.contains(idx) { continue }
            if seat.isVideoSeat { continue }
            if !allowHostSeat, (seat.isHostSeat ?? 0) == 1 { continue }
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

struct PartyHotTaskFaceSnapshot: Sendable {
    let roomId: String
    let seatIndex: Int
    let imageData: Data
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
        // 音乐流使用 roomId 作为 Agora uid，且通常不在 seatList 中；因此必须单独恢复
        // 该流的本端收听状态。与 H5 在 user-published 后调用 switchMusicSound 的时机一致。
        if uid == roomMusicAgoraUID {
            applyRoomMusicSettings(roomMusicSettings)
        }
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

    /// v15 声纹反馈：RTC 已合并同周期本地/远端音量回调后再全量替换；空集合=全体静音。
    /// 用 Set 比较避免不必要的 objectWillChange 触发（同一集合内容不派发）。
    func partyRTCEngine(_ engine: PartyRTCEngine, didUpdateSpeakingUids uids: Set<UInt>) {
        guard !isMinimized else { return }
        if uids != speakingUids {
            speakingUids = uids
        }
    }

    /// F 期断线重连（2026-07-17）：Agora 从 `.disconnected/.reconnecting` 回到 `.connected` 时触发。
    /// 蓝本 02-04-派对房.md §5 明示"NIM UNLOGIN/NET_BROKEN 置 mLoadMikeList=false，LOGINED 重连后自动
    /// 重拉全量麦位"。iOS 侧同时对 Agora 侧做全量重拉 seatList → postMikeList 对账，避免断线期间
    /// 错过 1001/1012 广播导致麦位视图 stale。
    ///
    /// 仅在 roomState == .joined 时才重拉，避免 entering / leaving 中间态误触发。
    func partyRTCEngineDidReconnect(_ engine: PartyRTCEngine) {
        guard roomState == .joined else {
            AppLogger.party.notice("[PartyStore] RTC reconnect ignored: roomState=\(String(describing: self.roomState), privacy: .public)")
            return
        }
        AppLogger.party.notice("[PartyStore] RTC reconnected; reloading seatList for reconciliation")
        Task { [weak self] in
            await self?.reloadSeatListFromServer()
        }
    }
}

// MARK: - v15 声纹派生查询

extension PartyStore {
    /// 判断某个麦位当前是否正在说话。普通声波只依赖 Agora 音量列表，对齐 H5 `PlayVolume`。
    func isSpeaking(seat: PartyRoomSeat) -> Bool {
        guard let uidStr = seat.userId,
              let uid = UInt(uidStr),
              uid > 0 else { return false }
        return speakingUids.contains(uid)
    }

    /// 声纹需要额外满足用户开麦、且未被房管禁麦，对齐 H5 `isVoicePrintFrameActive`。
    /// 麦位媒体字段可能在部分服务端推送中缺失，缺失按开麦处理，与禁麦图标保持同一语义。
    func isVoicePrintActive(seat: PartyRoomSeat) -> Bool {
        guard isSpeaking(seat: seat) else { return false }
        return !seat.isMicrophoneMuted
    }
}

// MARK: - PartyRoomChatManagerDelegate

extension PartyStore: PartyRoomChatManagerDelegate {

    func partyRoomChatDidEnter(_ chat: PartyRoomChatManager) {
        imAlive = true
        markJoinedIfReady()

        // 进房首次插入房间公告到公屏（对齐 H5 party.js:416-425）。
        if let text = roomInfo?.announcement,
           !text.isEmpty,
           let rid = roomInfo?.id,
           !rid.isEmpty,
           !PartyStore.announcementShownRoomIds.contains(rid) {
            PartyStore.announcementShownRoomIds.insert(rid)
            chatRouter.postAnnouncement(String(format: L10n.Party.roomAnnouncementFormat, text))
        }
    }

    /// 房间公告首次插入去重集合；离房后会清掉对应 roomId，与 H5 会话语义一致。
    private static var announcementShownRoomIds: Set<String> = []

    func partyRoomChat(_ chat: PartyRoomChatManager, didFailToEnter reason: String) {
        AppLogger.party.error("[PartyStore] chat enter fail: \(reason, privacy: .public)")
        Task { [weak self] in await self?.forceLeaveRoom(.entryFailed) }
        lastError = .enterFailed(underlying: reason)
    }

    func partyRoomChatDidReconnect(_ chat: PartyRoomChatManager) {
        guard isJoinedChannel else { return }
        AppLogger.party.notice("[PartyStore] chat reconnect → reload seatList")
        let roomId = roomInfo?.id ?? ""
        Task { [weak self] in
            await self?.reloadSeatListFromServer()
            if !roomId.isEmpty {
                await PartySuperWheelStore.shared.loadState(roomId: roomId, presentWhenActive: false)
            }
        }
    }

    func partyRoomChatDidKickOut(_ chat: PartyRoomChatManager) {
        Task { [weak self] in await self?.forceLeaveRoom(.kicked) }
    }

    /// 1009 房间关闭/白名单限制：H5 收到后立即退出 Party 房。
    /// 该通知由当前聊天室分发，仍守当前会话状态，避免退房后的延迟消息影响下一个房间。
    func partyRoomChatDidCloseOrWhitelist(_ chat: PartyRoomChatManager) {
        guard chat.roomId == roomInfo?.yxRoomId,
              roomState == .entering || roomState == .joined else { return }
        AppLogger.party.notice("[PartyStore] 1009 room closed or whitelist restricted; leaving room")
        Task { [weak self] in await self?.forceLeaveRoom(.kicked) }
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveAuditWarning payload: [String: Any]) {
        guard roomState == .entering || roomState == .joined else { return }
        let content = (payload["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (content?.isEmpty == false) ? content! : L10n.complianceWarningDefault
        let duration = PartyValueNormalizer.intify(payload["time"]) ?? 0
        partyAuditWarningMessage = message
        partyAuditWarningDismissTask?.cancel()
        if duration > 0 {
            partyAuditWarningDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.clearPartyAuditWarning()
            }
        }
        // H5 `party-ban-popup`：有实际禁令（正数倒计时或永久 -1）时立刻下麦。
        if duration != 0, selfSeat != nil {
            Task { [weak self] in await self?.requestDownSeat() }
        }
    }

    func clearPartyAuditWarning() {
        partyAuditWarningDismissTask?.cancel()
        partyAuditWarningDismissTask = nil
        partyAuditWarningMessage = nil
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveSystemAuthUpdate payload: [String: Any]) {
        guard roomState == .entering || roomState == .joined else { return }
        let authType = PartyValueNormalizer.intify(payload["authType"])
            ?? PartyValueNormalizer.intify(payload["type"])
            ?? 0
        guard let userId = myUserIdString,
              !userId.isEmpty,
              authType == 1 || authType == 2 else { return }
        let nickname = SessionStore.shared.user?.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = nickname.flatMap { $0.isEmpty ? nil : $0 } ?? userId
        let text = authType == 1
            ? String(format: L10n.Party.authUpdateSetAdminFormat, displayName)
            : String(format: L10n.Party.authUpdateRemoveAdminFormat, displayName)
        // 对齐 H5 user `updatePartyAdmin`：1019 系统通知只在被任免用户端插入 authUpdateTip 公屏消息。
        chatRouter.postSystemAuthUpdate(text)
        applyPartyRoleUpdate(
            targetUserId: userId,
            role: authType == 1 ? .admin : .audience
        )
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceivePlatformAdminChange payload: [String: Any]) {
        guard roomState == .entering || roomState == .joined,
              payload["isPlatformAdmin"] != nil else { return }
        let isPlatformAdmin: Bool
        if let value = payload["isPlatformAdmin"] as? Bool {
            isPlatformAdmin = value
        } else if let value = payload["isPlatformAdmin"] as? String {
            isPlatformAdmin = ["1", "true", "yes"].contains(value.lowercased())
        } else {
            isPlatformAdmin = (PartyValueNormalizer.intify(payload["isPlatformAdmin"]) ?? 0) != 0
        }
        platformAdminOverride = isPlatformAdmin
        PartyBattleStore.shared.refreshPermissions()
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveSeatUpdate payload: [String: Any], raw: NIMMessage) {
        // spec §0/§1 乱序判丢：切模板成功前发出的 1001（msgTimestamp < switchedAt-3s）为陈旧广播，直接覆盖会踩到旧 seatList
        // v2（2026-07-15 findings #8 修复）：从"近 3s 内一律丢"改为**精确按 msgTimestamp 判丢旧广播**，
        // 对齐 1017 pattern。避免切模板后 3s 内新的用户上下麦 1001 被误丢
        let msgTimestampMs = Int64(raw.timestamp * 1000)
        if let switchedAt = lastRoomTempSwitchAt {
            let switchedAtMs = Int64(switchedAt.timeIntervalSince1970 * 1000)
            if msgTimestampMs < switchedAtMs - 3000 {
                AppLogger.party.notice("[PartyStore] 1001 dropped by lastRoomTempSwitchAt-3s guard (msgAt=\(msgTimestampMs, privacy: .public) switchedAt=\(switchedAtMs, privacy: .public))")
                return
            }
        }
        // MVP 简化：1001 payload schema 待 M3 抓真实帧确认；
        // 现策略——若 payload 含完整 seatList 数组直接替换，否则全量重拉。
        AppLogger.party.notice("[PartyStore] 1001 seatUpdate payload keys=\(Array(payload.keys), privacy: .public)")
        if let seats = decodeSeatListField(payload) {
            AppLogger.party.notice("[PartyStore] 1001 direct seatList replace count=\(seats.count, privacy: .public)")
            replaceSeatListPreservingGiftValues(seats)
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

    func partyRoomChatDidRequireSeatListReload(_ chat: PartyRoomChatManager, msgTimestampMs: Int64) {
        // spec §0/§1 乱序判丢：切模板成功前发出的 1012 全量重拉指令视为旧上下文，丢弃避免覆盖
        // v2（2026-07-15 findings #8 修复）：从"近 3s 内一律丢"改为**精确按 msgTimestamp 判丢**，
        // 对齐 1017 pattern，避免切模板后 3s 内新的 1012 被误丢
        if let switchedAt = lastRoomTempSwitchAt {
            let switchedAtMs = Int64(switchedAt.timeIntervalSince1970 * 1000)
            if msgTimestampMs < switchedAtMs - 3000 {
                AppLogger.party.notice("[PartyStore] 1012 dropped by lastRoomTempSwitchAt-3s guard (msgAt=\(msgTimestampMs, privacy: .public) switchedAt=\(switchedAtMs, privacy: .public))")
                return
            }
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

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveRoomMusicAvailability payload: [String: Any], raw: NIMMessage) {
        _ = raw
        applyRoomMusicAvailability(payload)
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveMusicUpdate payload: [String: Any], switchOnly: Bool, raw: NIMMessage) {
        _ = raw
        applyRoomMusicUpdate(payload, switchOnly: switchOnly)
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
        // Agora 的音量回调可能在禁麦广播之后才刷新。先移除当前说话状态，
        // 让禁麦图标和声纹效果与 1015 广播在同一轮 UI 更新中生效。
        if isProhibit,
           newSeat.isSeatMicrophoneProhibited,
           let uidString = old.userId,
           let uid = UInt(uidString) {
            speakingUids.remove(uid)
        }
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

        // v3（2026-07-15）：礼物消息进公屏 feed（`.gift` variant + 可能派生 `.luckyGift`）
        // 对齐 H5 party.js newGiftMessage：公屏固定使用 `smallImg`，不能在同时有动效 giftImg 时误取大图。
        let giftIcon: String? = (payload["smallImg"] as? String)
                             ?? (payload["giftSmallImg"] as? String)
                             ?? (payload["giftImg"] as? String)
        // H5 先写一条常规送礼公屏；若中奖，再额外派生 luckyGift 公屏。
        // 小窗态只保留前者，中奖公屏和视觉效果均在下方非小窗分支处理。
        // v3+（2026-07-16）：主播本人送礼时 payload.sendUser.avatar 若缺失，从 AnchorInfoStore.mine.icon
        // 或 SessionStore.user.icon 兜底 → 保证自己送礼公屏显示自己头像
        let myAvatarFallback = AnchorInfoStore.shared.mine?.icon ?? SessionStore.shared.user?.icon
        let totalReward = PartyValueNormalizer.intify(payload["totalReward"]).map { Int64($0) } ?? 0
        chat.appendMessage(PartyPublicChatAdapter.gift(
            event: event, iconURL: giftIcon,
            myUserId: myUserIdString, myAvatarFallback: myAvatarFallback
        ))

        // H5 小窗态仍保留礼物公屏，但不更新收礼值或播放任何礼物特效。
        guard !isMinimized else { return }

        if totalReward > 0 {
            chat.appendMessage(PartyPublicChatAdapter.luckyGiftDerived(
                event: event, iconURL: giftIcon, totalReward: totalReward,
                myUserId: myUserIdString, myAvatarFallback: myAvatarFallback
            ))
        }

        // 对齐 H5 `updateRoomSeatGiftValue`：2049 的 `gems` 是单个接收人的本次收礼值，
        // 按 `receiveUserList[].userId` 累加到正在该麦位上的用户，驱动所有麦位视图实时刷新。
        if event.gems.isFinite, event.gems > 0 {
            seatList = PartySeatGiftValue.adding(
                gems: event.gems,
                to: event.receiverUserIds,
                seats: seatList
            )
        }

        // Party 房特效：静态礼物走 H5 同款中央 + 收礼麦位 + 飘屏；SVGA/MP4 才交给通用全屏播放器。
        // payload 兼容 compressed 批量与真实 2049 单条两种形态。
        let scopeId = roomInfo?.id ?? ""
        let mineYxAccid = SessionStore.shared.user?.yxAccid ?? ""
        let myUserId = myUserIdString
        let giftPayloads = (payload["gifts"] as? [[String: Any]]) ?? [payload]
        for giftPayload in giftPayloads {
            guard let effect = PartyGiftEffectItem.from(payload: giftPayload) else { continue }
            let isLuckyGift = giftEffects.enqueue(
                effect,
                myUserId: myUserId
            )
            // H5 `newGiftPlay` 先判 Lucky Gift；命中后仅走收礼麦位动画和飘屏，
            // 不把其原始 SVGA/MP4 再送入全局礼物队列。
            if effect.hasPlayableAnimation, !isLuckyGift {
                GiftEffectIntake.ingest(
                    scene: .party,
                    scopeId: scopeId,
                    payload: giftPayload,
                    mineYxAccid: mineYxAccid
                )
            }
            if let winningEffect = PartyLuckyGiftWinEffect.from(
                payload: giftPayload,
                myUserId: myUserId
            ) {
                // 对齐 H5 `party.js:newGiftMessage`：非发送者收到 Lucky Gift 中奖广播时，
                // 用同一全局 SVGA 队列播放固定中奖动画，文字内容由 `luckyGiftWin` 覆盖层消费。
                GiftEffectCenter.shared.enqueue(
                    GiftEffectItem(
                        sceneKey: GiftEffectSceneKey(scene: .party, scopeId: scopeId),
                        senderYxAccid: winningEffect.senderUserId ?? "",
                        senderNickname: winningEffect.senderNickname ?? "",
                        senderAvatarUrl: winningEffect.senderAvatarURL,
                        giftId: effect.giftId,
                        giftName: effect.giftName,
                        giftCount: winningEffect.totalReward,
                        giftPrice: 0,
                        animationUrl: PartyLuckyGiftWinEffect.animationURL,
                        staticImgUrl: nil,
                        timestamp: Int64(raw.timestamp * 1000),
                        isSelfSent: false,
                        luckyGiftWin: GiftEffectLuckyGiftWin(
                            senderAvatarUrl: winningEffect.senderAvatarURL,
                            senderNickname: winningEffect.senderNickname ?? "",
                            reward: winningEffect.totalReward
                        )
                    )
                )
            }
        }

        // 财富榜累加与麦位收礼值同样以 `gems` 有效为前提（对齐 H5 updateRoomSeatGiftValue）。
        if event.gems.isFinite, event.gems > 0 {
            applyContributionDelta(payload: payload)
        }
    }

    /// 送礼消息触发的房间财富榜累加。对齐 H5 `party.js:1478`：
    /// ```js
    /// this.currentPartyInfo.contributionCostNum = new Decimal(this.currentPartyInfo.contributionCostNum || 0)
    ///     .plus(new Decimal(cost || 0)).toNumber()
    /// ```
    /// cost 字段来自 gift IM payload；缺失/0 时不改。roomInfo?.contributionCostNum 是 String 存储，
    /// Int 解析 + 累加 + 回写字符串。
    private func applyContributionDelta(payload: [String: Any]) {
        guard let info = roomInfo else { return }
        // cost 可能是 Int / String / Double 混发（后端非严格）
        let cost: Int
        if let n = payload["cost"] as? Int { cost = n }
        else if let d = payload["cost"] as? Double { cost = Int(d) }
        else if let s = payload["cost"] as? String, let n = Int(s) { cost = n }
        else { return }  // 缺失字段静默 skip
        guard cost > 0 else { return }
        let old = info.contributionCostNumInt
        let updated = old + cost
        roomInfo = info.withUpdated(contributionCostNum: String(updated))
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
        guard !isMinimized else { return }
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

    /// H5 `handleNotificationMessage(type=enter)`：无座驾的聊天室成员进入时显示 2 秒进场条。
    /// `notifyExt` 是云信官方字段，首次真机收到时记录字段形态以校验服务端 payload。
    func partyRoomChat(
        _ chat: PartyRoomChatManager,
        didReceiveMemberEnter notificationExtension: String?,
        fallbackNickname: String?
    ) {
        _ = chat
        guard roomState == .joined || roomState == .entering else { return }
        guard !isMinimized else { return }
        guard let message = PartyEnterFloatingMessage.from(
            notificationExtension: notificationExtension,
            fallbackNickname: fallbackNickname
        ) else { return }

        AppLogger.party.info(
            "[PartyStore] memberEnter floating nickname=\(message.nickname, privacy: .private) level=\(message.userLevel ?? -1, privacy: .public) vip=\(message.isVip, privacy: .public)"
        )
        enterFloatingQueue.append(message)
        if enterFloatingQueue.count > enterFloatingQueueLimit {
            enterFloatingQueue.removeFirst(enterFloatingQueue.count - enterFloatingQueueLimit)
        }
        playNextEnterFloatingIfIdle()
    }

    private func playNextEnterFloatingIfIdle() {
        guard enterFloatingTask == nil,
              !enterFloatingQueue.isEmpty else { return }
        let next = enterFloatingQueue.removeFirst()
        enterFloatingMessage = next
        enterFloatingTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if self.enterFloatingMessage?.id == next.id {
                self.enterFloatingMessage = nil
            }
            self.enterFloatingTask = nil
            self.playNextEnterFloatingIfIdle()
        }
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveVideoSeatInvite invite: PartyVideoSeatInvite) {
        guard roomState == .entering || roomState == .joined else { return }
        if let invitedRoomId = invite.roomId, !invitedRoomId.isEmpty {
            let currentRoomIds = Set([roomInfo?.id, roomInfo?.yxRoomId]
                .compactMap { $0 }
                .filter { !$0.isEmpty })
            guard currentRoomIds.contains(invitedRoomId) else {
                AppLogger.party.notice("[PartyStore] 1040 dropped room mismatch")
                return
            }
        }
        // `PartyVideoSeatInvite.from` 已校验 inviteId / seatIndex；到达此处再写入 UI 待响应态。
        pendingVideoSeatInvite = invite
    }

    /// F 里程碑（2026-07-17）表情面板 IM 消费：
    /// - Router 已完成 self-echo skip（sendUserId == 自己 → 已在本地 sendEmoji 时 enqueue，不重复）
    /// - Router 已完成 payload 严校验（emojiId / playUrl / sendUserId 必须非空）
    /// - 此处只做入队；播放由麦位 SVGA player 观察 emojiQueueMap[sendUserId] 驱动
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveEmoji payload: PartyEmojiPayload, raw: NIMMessage) {
        _ = raw
        guard !isMinimized else { return }
        enqueueEmoji(seatUserId: payload.sendUserId, payload: payload)
        AppLogger.party.info("[PartyStore] emoji enqueued sender=\(payload.sendUserId, privacy: .public) emojiId=\(payload.emojiId, privacy: .public) queueSize=\(self.emojiQueueMap[payload.sendUserId]?.count ?? 0, privacy: .public)")
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveInviteResult result: PartyVideoSeatInviteResult) {
        guard roomState == .entering || roomState == .joined else { return }
        lastInviteResult = result
        if let targetUserId = result.targetUserId {
            videoSeatInviteCooldowns.removeValue(forKey: targetUserId)
        }
        // v3（2026-07-15）：1047 广播型接受 → 公屏系统消息（对齐 H5 chat-list.vue L221 msgType='videoSeatInviteAccept'）
        // 房主视角 = 看到"xxx 上了视频位"；被邀请者接受成功也看到反馈
        if result.kind == .broadcast {
            let text = result.systemText?.isEmpty == false
                ? result.systemText!
                : String(format: L10n.Party.videoSeatInviteAcceptedFormat, L10n.Party.defaultUser)
            chatRouter.postSystemVideoSeatInvite(text)
        }
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
        // 对齐安卓 §3.4「data 含 roomId」+ 项目 1049 handler pattern：payload.roomId 校验防跨房错乱
        let payloadRoomId = PartyValueNormalizer.stringify(payload["roomId"]) ?? ""
        if !payloadRoomId.isEmpty, let current = roomInfo?.id, current != payloadRoomId {
            AppLogger.party.notice("[PartyStore] 1018 drop: roomId=\(payloadRoomId, privacy: .public) current=\(current, privacy: .public)")
            return
        }
        let operation = PartyValueNormalizer.intify(payload["operation"]) ?? 0
        let userId = PartyValueNormalizer.stringify(payload["userId"]) ?? ""
        // P1-8 守卫：num 字段缺失时保持前值不动，避免误清 badge（后端 partial 序列化兜底）
        if let num = PartyValueNormalizer.intify(payload["num"]) {
            queueSeatNum = num
        }
        let num = queueSeatNum

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
            // 未知 op 兜底：refresh 列表让 UI 与服务端最终一致（后端加 op=5/6 时客户端不脱轨）
            AppLogger.party.notice("[PartyStore] 1018 unknown operation=\(operation, privacy: .public) num=\(num, privacy: .public); fallback refresh")
            Task { [weak self] in await self?.refreshMicApplications() }
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
        // 对齐安卓 PartyRoomVM:646 `enable==0 → queueSeatNum=0, setIsApplyMic(false)`：
        // 房主关开关时，本地排队中的观众端申请自动作废，需清 myApplyInfo.inIndex + 停超时兜底 task
        if !on {
            micApplicationsState = .empty
            queueSeatNum = 0
            if myApplyInfo.inIndex > 0 {
                myApplyInfo.inIndex = 0
                applyingTimeoutTask?.cancel()
                applyingTimeoutTask = nil
                AppLogger.party.info("[PartyStore] 1021 switch off → cleared local applyInfo")
            }
        }

        // 公屏系统消息（v3：kind = .application → PublicChatVariant.partyModeSwitch）
        chatRouter.postSystemApplication(on
            ? L10n.Party.micApplicationSwitchOnSystemMsg
            : L10n.Party.micApplicationSwitchOffSystemMsg
        )
    }

    /// F 期 1029 派对房私 call 状态通知（spec §4.2 P0-4 已由 decoder 严格校验）。
    ///
    /// **本 spec 只做 log + roomInfo 回写**（不做 UI 提示 · Q8/Q9 决策）：
    /// - `status = calling`：日志埋点，通话建立由 CallStore.handleIncomingVideoCall 派对分支主链路承担
    ///   （queryCall callerType==5 判定 · 不依赖 1029 触发 pauseForCall）
    /// - `status = ended`：日志埋点，通话结束回派对房由 CallStoreObserver.callStore 触发 resumeParty
    /// - `partyCallOpen != nil`：回写 roomInfo.partyPrivateCallOpen（后端广播的最新开关态）
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceivePrivateCallNotify notify: PartyPrivateCallNotify, raw: NIMMessage) {
        _ = raw
        AppLogger.party.info("[PartyStore] 1029 privateCallNotify status=\(notify.status.rawValue, privacy: .public) userId=\(notify.userId, privacy: .public) partyCallOpen=\(notify.partyCallOpen ?? -1, privacy: .public)")
        // 回写房间开关态（若字段存在）
        if let open = notify.partyCallOpen, let info = roomInfo {
            roomInfo = info.withUpdated(partyPrivateCallOpen: open)
        }
    }

    // MARK: - v3（2026-07-15）Step 2 通知公屏 handler 业务实装

    /// 聊天室自定义 1019 仅用于实时角色同步。H5 用户端不在此通道插入权限提示，
    /// 被任免用户的 `authUpdateTip` 由系统通知 1019 处理入口负责。
    /// payload 期望 `{ userId, authType }`；authType 1=设房管 / 2=取消（真机 preflight）
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveAuthUpdate payload: [String: Any], raw: NIMMessage) {
        _ = raw
        AppLogger.party.info("[PartyStore] 1019 authUpdate payloadKeys=\(Array(payload.keys), privacy: .public)")
        let targetUserId = PartyValueNormalizer.stringify(payload["userId"]) ?? ""
        let authType = PartyValueNormalizer.intify(payload["authType"]) ?? 0
        guard !targetUserId.isEmpty, authType == 1 || authType == 2 else {
            AppLogger.party.notice("[PartyStore] 1019 ignored malformed payload")
            return
        }

        let role: PartyRoomRoleType = authType == 1 ? .admin : .audience
        applyPartyRoleUpdate(targetUserId: targetUserId, role: role)
    }

    /// 统一接收本地主动设置与服务端 1019 广播的房间角色变化。
    private func applyPartyRoleUpdate(targetUserId: String, role: PartyRoomRoleType) {
        partyRoleOverrides[targetUserId] = role

        // 本人未上麦时 selfRole 从 roomInfo 派生；他人不能改写本端 roomInfo。
        if targetUserId == myUserIdString, let info = roomInfo {
            roomInfo = info.withUpdated(roomRoleType: role.rawValue)
        }
        if let selfIndex = seatList.firstIndex(where: { $0.userId == targetUserId }),
           let updatedSeat = Self.replacingRoleType(of: seatList[selfIndex], with: role.rawValue) {
            seatList[selfIndex] = updatedSeat
        }
        if targetUserId == myUserIdString {
            PartyBattleStore.shared.refreshPermissions()
        }
    }

    /// PartyRoomSeat 使用不可变字段；以 Codable round-trip 定向更新 1019 广播中的角色字段。
    private static func replacingRoleType(of seat: PartyRoomSeat, with roleType: Int) -> PartyRoomSeat? {
        guard let data = try? JSONEncoder().encode(seat),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        dict["roomRoleType"] = roleType
        guard let updatedData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(PartyRoomSeat.self, from: updatedData)
    }

    /// F 期房主管理批（2026-07-17）1025 roomBgUpdate / 1026 roomBgExpire 消费。
    /// - `expired = false`：1025 房主 setBgImages 后广播 → 全量重拉 getRoomBgImage 与房主端对齐
    /// - `expired = true`：1026 背景过期 → 清 currentRoomBackground，UI 层 fallback DEFAULT_BG
    ///
    /// payload 字段名待真机 preflight（agent-recon-field-names-unverified rule）。
    /// 保守策略：不依赖 payload 字段值，直接触发全量拉取或清空，行为幂等安全。
    func partyRoomChatDidRequireRoomBgReload(_ chat: PartyRoomChatManager, expired: Bool) {
        guard roomState == .joined else {
            AppLogger.party.notice("[PartyStore] roomBg broadcast ignored: roomState=\(String(describing: self.roomState), privacy: .public) expired=\(expired, privacy: .public)")
            return
        }
        if expired {
            // 1026：清空自定义背景 → PartyRoomBackgroundView fallback 到 DEFAULT_BG asset
            backgroundEpoch &+= 1
            currentRoomBackground = nil
            AppLogger.party.info("[PartyStore] 1026 roomBgExpire cleared to default")
        } else {
            // 1025：全量重拉当前背景。loadCurrentRoomBackground 内已有 epoch/roomId 竞态守卫
            AppLogger.party.info("[PartyStore] 1025 roomBgUpdate → reloading current background")
            Task { [weak self] in await self?.loadCurrentRoomBackground() }
        }
    }

    /// 1049 房间通告公屏广播。payload 期望 `{ text, roomId }`。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveRoomAnnouncement payload: [String: Any], raw: NIMMessage) {
        _ = raw
        AppLogger.party.info("[PartyStore] 1049 roomAnnouncement payloadKeys=\(Array(payload.keys), privacy: .public)")
        // roomId 一致性校验（跨房广播防错）
        if let rid = PartyValueNormalizer.stringify(payload["roomId"]),
           let currentYxRoom = roomInfo?.yxRoomId,
           rid != currentYxRoom, rid != (roomInfo?.id ?? "") {
            AppLogger.party.notice("[PartyStore] 1049 dropped (roomId mismatch \(rid, privacy: .public) vs \(currentYxRoom, privacy: .public))")
            return
        }
        let text = (payload["text"] as? String) ?? ""
        guard !text.isEmpty else { return }
        if let info = roomInfo {
            roomInfo = info.withUpdated(announcement: text)
        }
        chatRouter.postAnnouncement(String(format: L10n.Party.roomAnnouncementFormat, text))
    }

    /// 1050 幸运数字抽数公屏卡片（H5 语义：优先 ext.data，缺失时回退顶层 ext）
    /// ext 期望 `{ userId, nickname, luckyNumber, giftId, ... }`
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveLuckyNumberDraw payload: [String: Any], raw: NIMMessage) {
        _ = raw
        AppLogger.party.info("[PartyStore] 1050 luckyNumberDraw payloadKeys=\(Array(payload.keys), privacy: .public)")
        guard let message = PartyPublicChatAdapter.luckyNumberPublic(payload: payload, didWin: false) else {
            AppLogger.party.notice("[PartyStore] 1050 drop invalid lucky number payload")
            return
        }
        chat.appendMessage(message)
    }

    /// 1051 幸运数字中奖公屏广播（H5 语义：优先 ext.data，缺失时回退顶层 ext）
    /// ext 期望 `{ userId, nickname, luckyNumber, winAmount, ... }`
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveLuckyNumberWin payload: [String: Any], raw: NIMMessage) {
        _ = raw
        AppLogger.party.info("[PartyStore] 1051 luckyNumberWin payloadKeys=\(Array(payload.keys), privacy: .public)")
        guard let message = PartyPublicChatAdapter.luckyNumberPublic(payload: payload, didWin: true) else {
            AppLogger.party.notice("[PartyStore] 1051 drop invalid lucky number payload")
            return
        }
        chat.appendMessage(message)
    }

    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveSuperWheelBroadcast attachType: Int, payload: [String: Any]) {
        guard roomState == .entering || roomState == .joined else { return }
        PartySuperWheelStore.shared.applyBroadcast(attachType: attachType, payload: payload)
    }

    /// 1052 幸运数字中奖个人通知。系统通知可能来自离线补发，必须确认仍在当前房内。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveLuckyNumberPersonalWin payload: [String: Any]) {
        _ = chat
        guard roomState == .joined,
              let win = PartyLuckyNumberWinPayload.from(payload: payload) else {
            AppLogger.party.notice("[PartyStore] 1052 drop: not joined or invalid payload")
            return
        }

        if let notifiedRoomId = win.roomId, !notifiedRoomId.isEmpty {
            let currentRoomIds = Set([roomInfo?.id, roomInfo?.yxRoomId].compactMap { $0 }.filter { !$0.isEmpty })
            guard currentRoomIds.contains(notifiedRoomId) else {
                AppLogger.party.notice("[PartyStore] 1052 drop room mismatch")
                return
            }
        }
        luckyNumberWinPayload = win
    }

    func dismissLuckyNumberWinPopup() {
        luckyNumberWinPayload = nil
    }

    /// 136 全服游戏中奖公屏（session.js 主入口 + Party 通道兜底）
    /// payload 期望 `{ avatar, nickname, winAmount, gameName, gameIcon, ... }`
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveGameWinGlobal payload: [String: Any], raw: NIMMessage) {
        AppLogger.party.info("[PartyStore] 136 gameWinGlobal payloadKeys=\(Array(payload.keys), privacy: .public)")
        appendGameWinDeduped(payload: payload, raw: raw, chat: chat, prefix: "136")
    }

    /// 138 PK 小奖 / Party 房游戏小奖（字段结构同 136）
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceivePkSmallPrize payload: [String: Any], raw: NIMMessage) {
        AppLogger.party.info("[PartyStore] 138 pkSmallPrize payloadKeys=\(Array(payload.keys), privacy: .public)")
        appendGameWinDeduped(payload: payload, raw: raw, chat: chat, prefix: "138")
    }

    /// 140 活动中奖公屏广播
    /// payload 期望 `{ activityName, quantity, imageURL, joinCTA, avatar, cardType, ... }`
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveWinnerBroadcast payload: [String: Any], raw: NIMMessage) {
        _ = raw
        AppLogger.party.info("[PartyStore] 140 winnerBroadcast payloadKeys=\(Array(payload.keys), privacy: .public)")
        guard let msg = PartyPublicChatAdapter.winnerBroadcast(
            payload: payload,
            myUserId: SessionStore.shared.user?.userId.map(String.init)
        ) else {
            AppLogger.party.notice("[PartyStore] 140 winnerBroadcast drop (scene or payload rejected)")
            return
        }
        chat.appendMessage(msg)
    }

    /// 197 首礼时刻：消息流和顶部横幅从同一 payload 入队，退房由 resetState 统一清空。
    func partyRoomChat(_ chat: PartyRoomChatManager, didReceiveFirstGiftMoment payload: [String: Any], raw: NIMMessage) {
        _ = raw
        guard let message = PartyPublicChatAdapter.firstGiftMoment(
            payload: payload,
            myUserId: SessionStore.shared.user?.userId.map(String.init)
        ) else {
            AppLogger.party.notice("[PartyStore] 197 firstGiftMoment drop invalid payload")
            return
        }
        chat.appendMessage(message)
        firstGiftFloatQueue.addToQueue(FirstGiftFloatQueue.Item(
            backgroundURL: payload["bgImageUrl"] as? String,
            renderedText: (payload["renderedText"] as? String) ?? "",
            nickname: (payload["nickname"] as? String) ?? "",
            giftImageURL: payload["giftImg"] as? String,
            giftSmallImageURL: payload["giftSmallImg"] as? String,
            styleKey: (payload["styleKey"] as? String) ?? "",
            isFirstGift: PartyPublicChatAdapter.boolify(payload["isFirstGift"])
        ))
    }

    // MARK: - v3 Step 2 handler 辅助

    /// 136 / 138 公用去重 + append 辅助。防止双通道重复（session.js 全服主入口 + party.js 兜底）。
    private func appendGameWinDeduped(payload: [String: Any], raw: NIMMessage, chat: PartyRoomChatManager, prefix: String) {
        _ = raw
        // messageClientId 优先 payload 后端字段；否则 fallback prefix + nickname + winAmount
        let clientId: String = {
            if let id = payload["messageClientId"] as? String, !id.isEmpty { return id }
            let nickname = (payload["nickname"] as? String) ?? ""
            let amount = (payload["winAmount"] as? String) ?? String(describing: payload["winAmount"] ?? "")
            return "\(prefix)-\(nickname)-\(amount)"
        }()
        guard !seenGameWinIds.contains(clientId) else {
            AppLogger.party.debug("[PartyStore] gameWin dedup \(clientId, privacy: .public)")
            return
        }
        seenGameWinIds.insert(clientId)
        // 每个 clientId 是短字符串，累积 1000 条 ~50KB；session 生命周期内不裁剪
        guard let msg = PartyPublicChatAdapter.gameWinNotify(payload: payload) else {
            AppLogger.party.notice("[PartyStore] gameWin drop (nickname/gameName empty)")
            return
        }
        chat.appendMessage(msg)
    }

    /// 跨消息去重集合（进程级；退 app 清空）
    private static var seenGameWinIds: Set<String> = []
    private var seenGameWinIds: Set<String> {
        get { PartyStore.seenGameWinIds }
        set { PartyStore.seenGameWinIds = newValue }
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

    // MARK: - F PartyCall 抢占（spec §2.1 Flow B/C）

    /// F 期：本地回写 roomInfo 私 call 字段（1029 handler / setPrivateCall API 成功后共用）。
    func applyPrivateCallUpdate(partyPrivateCallOpen: Int?, partyCallGiftId: String?) {
        guard let info = roomInfo else { return }
        roomInfo = info.withUpdated(
            partyPrivateCallOpen: partyPrivateCallOpen,
            partyCallGiftId: partyCallGiftId
        )
    }

    /// PK 进入 SELECTING/RUNNING 时强制关闭并隐藏私 call。
    ///
    /// 不依赖房间页的显示生命周期，确保小窗、重连后补拉到进行中 PK 时仍会执行。
    /// 非房主仅本地隐藏，避免修改他人房间的全局私 call 设置。
    func pausePartyPrivateCallForPK() {
        guard !partyPrivateCallHiddenForPK else { return }

        let info = roomInfo
        partyPrivateCallWasEnabledBeforePK = info?.isPartyPrivateCallEnabled == true
        partyPrivateCallGiftIdBeforePK = info?.partyCallGiftId
        partyPrivateCallHiddenForPK = true

        guard partyPrivateCallWasEnabledBeforePK else { return }
        applyPrivateCallUpdate(
            partyPrivateCallOpen: 0,
            partyCallGiftId: partyPrivateCallGiftIdBeforePK
        )
        enqueuePartyPrivateCallPKSync(enable: false, giftId: nil)
        AppLogger.party.info("[PartyStore] PK paused private call")
    }

    /// PK 结束、进入冷却或补拉到非活跃状态时，恢复进入 PK 前的私 call 状态。
    func resumePartyPrivateCallAfterPK() {
        guard partyPrivateCallHiddenForPK else { return }

        let shouldRestore = partyPrivateCallWasEnabledBeforePK
        let giftId = partyPrivateCallGiftIdBeforePK
        partyPrivateCallHiddenForPK = false
        partyPrivateCallWasEnabledBeforePK = false
        partyPrivateCallGiftIdBeforePK = nil

        applyPrivateCallUpdate(
            partyPrivateCallOpen: shouldRestore ? 1 : 0,
            partyCallGiftId: giftId
        )
        guard shouldRestore else { return }

        enqueuePartyPrivateCallPKSync(enable: true, giftId: giftId)
        AppLogger.party.info("[PartyStore] PK restored private call")
    }

    /// 退房时丢弃本地 PK 快照，不对已经离开的房间发送恢复请求。
    func discardPartyPrivateCallPKState() {
        partyPrivateCallPKSyncRevision &+= 1
        partyPrivateCallPKSyncTask?.cancel()
        partyPrivateCallPKSyncTask = nil
        partyPrivateCallHiddenForPK = false
        partyPrivateCallWasEnabledBeforePK = false
        partyPrivateCallGiftIdBeforePK = nil
        isTogglingPrivateCall = false
    }

    private func enqueuePartyPrivateCallPKSync(enable: Bool, giftId: String?) {
        // 入口在所有房间展示；但 PK 不能替非房主修改当前房间的全局私 call 设置。
        guard selfRole == .owner,
              let roomId = roomInfo?.id,
              !roomId.isEmpty else {
            return
        }

        partyPrivateCallPKSyncRevision &+= 1
        let requestRevision = partyPrivateCallPKSyncRevision
        let previousTask = partyPrivateCallPKSyncTask
        isTogglingPrivateCall = true

        partyPrivateCallPKSyncTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self,
                  !Task.isCancelled,
                  self.partyPrivateCallPKSyncRevision == requestRevision else {
                return
            }
            defer {
                if self.partyPrivateCallPKSyncRevision == requestRevision {
                    self.partyPrivateCallPKSyncTask = nil
                    self.isTogglingPrivateCall = false
                }
            }
            guard self.roomInfo?.id == roomId else { return }

            do {
                try await PartyAPI.updatePartyPrivateCall(
                    roomId: roomId,
                    enable: enable ? 1 : 0,
                    giftId: giftId
                )
                guard !Task.isCancelled,
                      self.partyPrivateCallPKSyncRevision == requestRevision,
                      self.roomInfo?.id == roomId else {
                    return
                }
                AppLogger.party.info(
                    "[PartyStore] PK private call sync ok enable=\(enable, privacy: .public)"
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.partyPrivateCallPKSyncRevision == requestRevision else { return }
                AppLogger.party.error(
                    "[PartyStore] PK private call sync failed enable=\(enable, privacy: .public) err=\(String(describing: error), privacy: .private)"
                )
            }
        }
    }

    /// F 期：房主 tap 主 view 浮动私 call 开关按钮触发。
    ///
    /// - `enable=true`：需带 `giftId`（从 CommonGiftPanel.callGate 选中回调传入）+ 可选 giftIcon/giftPrice 供按钮 preview
    /// - `enable=false`：giftId 传 nil；仅关开关，保留 partyCallGiftId 记忆下次开启时预选
    ///
    /// 成功后立即回写本地 roomInfo；失败设 lastError（顶层 alert 已 wire）。
    /// Optimistic UI 由调用方（PartyRoomView 浮动按钮）自己维护本地 @State 切换。
    func setPrivateCall(
        enable: Bool,
        giftId: String?,
        giftIcon: String? = nil,
        giftPrice: Int? = nil
    ) async {
        guard !partyPrivateCallHiddenForPK else {
            AppLogger.party.notice("[PartyStore] setPrivateCall rejected: PK active")
            return
        }
        guard selfRole == .owner else {
            AppLogger.party.notice("[PartyStore] setPrivateCall rejected: not owner/platformAdmin")
            return
        }
        guard let info = roomInfo, let roomId = info.id, !roomId.isEmpty else {
            AppLogger.party.notice("[PartyStore] setPrivateCall skip: roomInfo missing")
            return
        }
        // v5-需求 2：spinner flag —— UI 显示转圈 + 屏蔽 tap 直到 API 返回
        isTogglingPrivateCall = true
        defer { isTogglingPrivateCall = false }
        do {
            try await PartyAPI.updatePartyPrivateCall(
                roomId: roomId,
                enable: enable ? 1 : 0,
                giftId: giftId
            )
            applyPrivateCallUpdate(
                partyPrivateCallOpen: enable ? 1 : 0,
                partyCallGiftId: giftId ?? info.partyCallGiftId
            )
            // 开启私 call = 主播工作态；对齐直播/匹配的自动上线行为
            if enable, !OnlineStatusStore.shared.userSetOnline {
                OnlineStatusStore.shared.setUserSetOnline(true)
            }
            // 缓存 gift meta 供按钮 preview（enable=true 时更新；关开关时保留最后一次）
            if enable, let icon = giftIcon, !icon.isEmpty {
                partyCallGiftIcon = icon
            }
            if enable, let price = giftPrice, price > 0 {
                partyCallGiftPrice = price
            }
            AppLogger.party.info("[PartyStore] setPrivateCall ok enable=\(enable, privacy: .public) giftId=\(giftId ?? "nil", privacy: .public)")
        } catch {
            AppLogger.party.notice("[PartyStore] setPrivateCall failed err=\(error.localizedDescription, privacy: .private)")
            lastError = .underlying((error as? PartyAPIError) ?? .networkError)
        }
    }

    /// F 期入口：派对房挂起进入私 call（由 `CallStore.handleIncomingVideoCall` 派对分支调用）。
    ///
    /// **无 5s delay 直接接听**（D-1 决策 · 对齐 LiveStore.pauseForCall 立即模式）。时序：
    /// 1. 前置守卫（roomState==.joined）
    /// 2. updateMedia(type=3, enable=false) 若在麦上（fire-and-forget，不阻塞）
    /// 3. downSeat 若在麦上（fire-and-forget，不阻塞）
    /// 4. 立即关闭本地摄像头和麦克风发布（不依赖上述 HTTP 结果）
    /// 5. Task.sleep(200ms) — 让 AVCaptureSession 硬件层完全释放前置摄像头（P1-8 · 避免 CallView fallback camera reason=3）
    /// 6. rtc.leave() — await didLeaveChannelWith 回调（sharedEngine 不 destroy · rule §5）
    /// 7. CallStore.acceptIncomingFromParty(msg) — CallView zIndex=100 overlay 自动 pop calling
    func pauseForCall(msg: CallMessage) async {
        // 1) 前置守卫：只在派对房 .joined 状态下才处理
        guard roomState == .joined, let info = roomInfo else {
            AppLogger.party.notice("[PartyStore] pauseForCall guard reject roomState=\(self.roomState.debugDesc, privacy: .public)")
            return
        }
        AppLogger.party.info("[PartyStore] pauseForCall 开始 callId=\(msg.callId, privacy: .public)")

        // 先关闭当前麦位的本地采集和音频发布；后续两个 HTTP 只是服务端状态同步。
        deactivateLocalSeatMediaForExit()

        // 2+3) 若在麦上：updateMedia + downSeat（fire-and-forget · 不阻塞主流程）
        if let me = selfSeat, let seatIndex = me.seatIndex {
            let roomId = info.id ?? ""
            let yxRoomId = info.yxRoomId ?? ""
            let roomTempId = info.roomTempIdInt
            Task { @MainActor in
                do {
                    try await PartyAPI.updateMedia(
                        roomId: roomId, seatIndex: seatIndex,
                        type: 3, enable: false, yxRoomId: yxRoomId
                    )
                } catch {
                    AppLogger.party.notice("⚠️ [PartyStore] pauseForCall updateMedia failed err=\(error.localizedDescription, privacy: .private)")
                }
            }
            Task { @MainActor in
                do {
                    try await PartyAPI.downSeat(
                        roomId: roomId, seatIndex: seatIndex,
                        yxRoomId: yxRoomId, roomTempId: roomTempId
                    )
                } catch {
                    AppLogger.party.notice("⚠️ [PartyStore] pauseForCall downSeat failed err=\(error.localizedDescription, privacy: .private)")
                }
            }
        }

        // 4) 等 AVCaptureSession 硬件层完全释放（P1-8 · 20-200ms 保守取 200ms · Step 3 真机 5 循环压测调优）
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 5) rtc.leave() 派对房 Agora 频道（sharedEngine 不 destroy · rule §5 §9）
        await rtc.leave()

        // 6) 委托 CallStore 接听（内部 CallView fallback camera 会 start · CallView overlay 自动显示）
        await CallStore.shared.acceptIncomingFromParty(msg: msg)
        AppLogger.party.info("[PartyStore] pauseForCall 完成，已委托 CallStore")
    }

    /// F 期入口：通话结束回派对房（由 `CallStoreObserver.callStore(_:stateDidChange:previous:)`
    /// 在 state 转 .idle 时触发 · spec §2.1 Flow C）。
    ///
    /// 时序：
    /// 1. 前置守卫（roomState == .joined；通话中被踢/解散 → 短路，不 rejoin）
    /// 2. rtc.join 重入派对房 Agora 频道（内部 setChannelProfile(.liveBroadcasting) 显式重设）
    ///    失败 → refreshRtcToken 重试 1 次；仍失败 → forceLeaveRoom(.networkLost) + banner
    /// 3. postMikeList() 刷新麦位面板（麦位不自动恢复，主播需手动重上麦 · 对齐安卓）
    ///
    /// 注意：由于 disableLocalVideoCapture 已 tearDown camera，视频位需要用户手动重上麦时才会
    /// 再次 enableLocalVideoCapture（现有 postMikeList → onSeat 路径自动处理）。
    func resumeParty() async {
        // 1) 前置守卫：房间未被踢/未解散才恢复
        guard roomState == .joined, let info = roomInfo else {
            AppLogger.party.notice("[PartyStore] resumeParty 短路 roomState=\(self.roomState.debugDesc, privacy: .public)")
            return
        }
        guard let channelId = info.agoraChannelId, !channelId.isEmpty,
              let uid = myRtcUid else {
            AppLogger.party.error("[PartyStore] resumeParty missing channelId/uid → forceLeaveRoom(.networkLost)")
            await forceLeaveRoom(.networkLost)
            return
        }

        // 2) rtc.rejoin —— 先用现有 rtcToken；失败则 refreshRtcToken 重试 1 次
        AppLogger.party.info("[PartyStore] resumeParty rejoining channel=\(channelId, privacy: .public)")
        var rtcToken = info.rtcToken ?? ""
        if rtcToken.isEmpty {
            // 现有 rtcToken 空 → 主动拉一次
            do {
                let r = try await LiveService.getAgoraRtmToken()
                rtcToken = r.rtcToken ?? ""
            } catch {
                AppLogger.party.error("[PartyStore] resumeParty getAgoraRtmToken failed err=\(String(describing: error), privacy: .private)")
                await forceLeaveRoom(.networkLost)
                return
            }
        }
        guard !rtcToken.isEmpty else {
            AppLogger.party.error("[PartyStore] resumeParty rtcToken empty → forceLeaveRoom")
            await forceLeaveRoom(.networkLost)
            return
        }
        rtc.join(channelId: channelId, token: rtcToken, uid: uid)

        // 3) 刷麦位面板（麦位不自动恢复 · 对齐安卓 · 主播需手动重上麦）
        postMikeList()
        AppLogger.party.info("[PartyStore] resumeParty 完成，等用户主动上麦")
    }
}

// MARK: - CallStoreObserver（F 期 spec §3.2 状态机联动 · P0-2 多观察者数组）

extension PartyStore: CallStoreObserver {
    /// 观察通话状态变化：state 转 .idle 且之前非 .idle → 触发 resumeParty。
    /// 只在派对房挂起态（isSuspendedForCall）时才需 resume（else 直播私 call 已由 LiveStore 处理）。
    ///
    /// 由 CallStore.notifyObservers 遍历数组时调用（PartyStore 通过 attach 注册；LiveStore 同源不干扰）。
    nonisolated func callStore(_ store: CallStore, stateDidChange newState: CallState, previous: CallState) {
        // hop 到 MainActor 处理业务逻辑
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 只处理"通话结束→idle"（其他态迁移 no-op）
            guard newState == .idle, previous != .idle else { return }
            // 只在派对房挂起态下响应（避免直播私 call / direct 通话结束时错误触发 resumeParty）
            // 判定：previous frontGameType == .party（通话来源是派对房）
            // 注意：state 已转 .idle 但 current 尚未清（endLocally 内 scheduleEndedToIdle 500ms 延迟清理，观察者在此窗口内触发）
            guard store.current.frontGameType == .party else { return }
            AppLogger.party.info("[PartyStore] CallStoreObserver: call ended (prev=\(previous.rawValue, privacy: .public)) → resumeParty")
            await self.resumeParty()
        }
    }
}

// MARK: - debug helper

extension PartyRoomState {
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
