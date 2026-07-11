import SwiftUI

/// 直播间（对应 H5 liveRoom）：声网推流 + LiveStore 接管心跳/下播状态机 + 云信公屏。
///
/// M1：LiveStore 接管心跳（10s）与 forceEnd/endLive；
/// M2：注入相机错误回调 / 美颜降级通知 / 权限拒绝 alert / 网络监控转发（store.wire(agora)）；
/// M3：公屏/在线人数迁移到 LiveStore。
struct LiveRoomView: View {
    let roomInfo: LiveRoomInfo
    let title: String
    /// **不**用 `@ObservedObject`：父 view body 不再因 slider 拖动（每秒 30-60 publish）
    /// 触发整树重算 + .onReceive 入队。监听 + renderer 更新已下沉到 `BeautyPanel` 内（throttle）。
    let beauty: BeautyParameters

    @StateObject private var store = LiveStore()
    @StateObject private var camera = CameraManager()
    @StateObject private var agora = AgoraManager()
    @StateObject private var nim = NIMChatroomManager()
    /// 统一公屏组件 Phase 1：Live 场景 feed（订阅 nim.messagesStore.$messages → adapt → replace）
    @StateObject private var publicChatFeed = UnifiedPublicChatFeed(limit: 200)
    /// G 里程碑 M3：PK 主态状态机；onAppear weak 注入 store/agora/nim/observer/networkMonitor
    @StateObject private var pkStore = PKStore()
    /// G 里程碑 M3：PK 结束后 didEndPK observer 桥到 UI 弹结果窗
    @StateObject private var pkResultBridge = PKResultBridge()
    /// D 里程碑：监听 CallStore 状态，直播态收到私 call 时用 CallView overlay 覆盖直播画面。
    /// 对齐 H5 g-faceTime 全局浮层模式。RootView 的 ZStack 浮层在 sheet 内不可见，必须在
    /// LiveRoomView 内自己 overlay。
    /// **不**用 `@ObservedObject`：CallStore 上 5 个 HUD 字段（callWaitState/callWaitBonus/...）
    /// 每条 sysMsg publish 一次，订阅整 store 会触发 LiveRoomView 整树（含 CameraPreview/PKArenaView/
    /// publicScreen）重算。仅订阅 .state 镜像到本地 @State 即可（CallView overlay 显隐唯一依赖）。
    private let callStore = CallStore.shared
    @State private var callState: CallState = .idle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var authorized = false
    @State private var showBeauty = false

    // G 里程碑 M0 临时调试入口：手动加入/离开对手 PK 频道，验证 joinChannelEx 通路
    // 用 #if DEBUG 隔离，release 包不带（避免审核侧看到内部调试入口）
    #if DEBUG
    @State private var showPKDebug = false
    @State private var pkDebugChannel = ""
    @State private var pkDebugOppositeUid = ""
    @State private var pkDebugMessage = ""
    #endif

    /// G M3：邀请发起 sheet 显示状态
    @State private var showInviteSheet = false

    /// 底部 Say hi 输入框绑定：`onSend` → `nim.sendText(_:)`（严格对齐 H5 sendMessage
    /// liveRoom.vue:291-319，spec `docs/plan/H-直播间发送公屏文字-spec-202607101100.md`）
    @State private var inputText: String = ""

    /// "Coming soon" toast（快捷礼物 / 私 call 主动发起 / task / 排行 等占位入口点击提示）
    @State private var comingSoonToast: String? = nil

    /// Private Call 开关本地 UI 态（对齐 H5 `privateCall = ref(true)` 默认开）。
    /// 真数据源在 `LiveStore.privateCallOpen`：
    /// - onAppear 从 store 初始化本 @State
    /// - toggle 时乐观更新本 @State + 调 `LiveService.updatePrivateCall` + 成功后写回 store；失败回滚 + toast
    /// - `.onReceive(store.$privateCallOpen)` 反向同步（IM attachType 52 到达时）
    @State private var privateCallOn: Bool = true

    /// 设置按钮 confirmationDialog 显隐（含美颜 / 结束直播两项，对齐 H5 底部 setting 按钮）
    @State private var showSettingSheet: Bool = false

    /// B spec v7：直播结束 → 通过 `\.liveResultTransition` env 切 tab + 重建 path 到 `[liveResult]`
    /// LiveRoomView 随 path 替换自然 dismount，onDisappear 触发正常清资源（不再需 onChange 主动清）
    @Environment(\.liveResultTransition) private var liveResultTransition

    // MARK: - PK 4 popup 显隐（对齐 H5 pkLive/*Popup.vue：iteration 3 PK 全套 UI 同步）
    /// B-2 中断 PK 确认（inPK 态点击 PKEntryButton 触发）
    @State private var showPKInterruptConfirm: Bool = false
    /// B-3 断开连线确认（punishing 态点击 PKEntryButton 触发）
    @State private var showPKDisconnectConfirm: Bool = false
    /// B-4 匹配失败（state 从 .matching → .idle/.failed 时自动触发）
    @State private var showPKMatchFailed: Bool = false
    /// B-5 邀请等待（state == .inviting 且有邀请时挂载）
    @State private var showPKInviteWaiting: Bool = false
    /// 追踪上一次 PK state（用于 matching → idle/failed 判定匹配失败）
    @State private var lastPKState: PKStateMain = .idle

    // MARK: - 顶部按钮 popup / sheet 显隐
    /// **v7 分层**（2026-07-07）：Task / Audience 保持 placeholder popup；Contribution / Rank / Roulette
    /// 已迁到独立 sheet 对齐 H5 真交互（Sources/Live/{Contribution,Rank,Roulette}/）
    @State private var showTaskPopup: Bool = false
    // v11: audience popup 已删（tap → showRankSheet），保留 @State 以兼容 Modifier 编译（binding 未被读；linter 若清理可删）
    @State private var showAudiencePopup: Bool = false
    @State private var showContributionSheet: Bool = false
    @State private var showRankSheet: Bool = false
    /// v13 遗留（v16 后不再使用；保留 struct 兼容 Modifier 参数编译，见 TopSheetsModifier 已删该参数）
    @State private var rankSheetInitialTopTab: RankSheetTopTab = .topGifter
    /// v16：观众数字 tap → 弹独立 UserWeeklyRankSheet（对齐 H5 userWeeklyRank.vue）
    @State private var showUserWeeklyRankSheet: Bool = false
    /// Roulette 分两态：intro 首次引导（overlay 中心 modal）+ setting 转盘设置（sheet 底部）
    @State private var showRouletteIntro: Bool = false
    @State private var showRouletteSetting: Bool = false
    /// Roulette 顶部按钮 icon 两态开关（对齐 H5 liveRoomTop.vue rouletteStatus）
    /// - false → rouletteClose.webp（关闭态）
    /// - true  → rouletteOpen.webp（开启态）
    /// 数据源：onAppear 拉 queryConfig 拿初始；SettingSheet 保存/切换时 callback 回传
    @State private var isRouletteEnabled: Bool = false

    // MARK: - v9 新增 State
    /// 虚拟道具特效开关 store（UserDefaults persist）
    @StateObject private var virtualPropsStore = VirtualPropsStore()
    /// v9 4 popup/sheet 显隐
    @State private var showEffectSwitchPopup: Bool = false
    @State private var showAnnouncementPopup: Bool = false
    @State private var showGiftPicker: Bool = false
    /// UserCard tap 头像触发 → nil = 隐藏，非 nil = 该 userId 的 popup 显示
    @State private var userCardUserId: String? = nil
    /// v10 心愿单半屏面板显隐
    @State private var showWishlistPanel: Bool = false

    /// 半屏消息列表 sheet 显隐（对齐 H5 messagePopup） —— 底部工具栏消息按钮触发。
    @State private var showMessageSheet: Bool = false
    /// 半屏私聊 sheet 承载（非 nil 时叠加在 messageSheet 之上，对齐 H5 talkPopup）；
    /// 用 wrapper struct 满足 sheet(item:) Identifiable 要求。
    @State private var selectedChatPeer: ChatSheetPeer? = nil
    /// 半屏消息列表数据源（订阅未读计数用于消息按钮红点）。
    @ObservedObject private var sessionStore: MessageSessionStore = .shared

    /// body 里若写 `let isPKActive = ...`，body 会从"单表达式 @ViewBuilder"降级为"多语句 closure"，
    /// SwiftUI 类型推导复杂度剧增；抽 computed property 让 body 保持单表达式（rule swiftui-body-type-check-timeout §4）
    private var isPKActive: Bool {
        pkStore.state == .starting || pkStore.state == .inPK || pkStore.state == .punishing
    }

    /// 半屏消息列表未读合计（对齐 H5 sessionStore.newMsg red-dot + messagePopup 数据源过滤语义）。
    /// **不用** `unreadCount(in: .flame)` —— 那含 systemInboxEntries（sheet 里已过滤掉），
    /// 会导致红点显示 ≠ sheet 内容，用户点开看不到"未读源"。
    /// 语义：与 ConversationSheetContent.allSessions 对齐（3 类并集去重 → 累加 unreadCount）
    private var liveMessageUnreadTotal: Int {
        let all = sessionStore.sessions(in: .flame)
            + sessionStore.sessions(in: .prime)
            + sessionStore.sessions(in: .stranger)
        var seen = Set<String>()
        return all
            .filter { seen.insert($0.id).inserted }
            .reduce(0) { $0 + $1.unreadCount }
    }

    var body: some View {
        mainZStack
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showBeauty) {
            beautyPanel
                .presentationDetents([.fraction(0.4)])
                .presentationDragIndicator(.visible)
        }
        #if DEBUG
        .sheet(isPresented: $showPKDebug) { pkDebugPanel }   // M0 调试入口（仅 DEBUG，不限高）
        #endif
        .sheet(isPresented: $showInviteSheet) {
            PKInviteSheet(store: pkStore,
                          isPresented: $showInviteSheet,
                          onTapAvatar: { uid in
                              // tap anchor avatar → 关邀请 sheet + 打开 UserCard popup（对齐 H5 openAnchorProfile）
                              showInviteSheet = false
                              userCardUserId = uid
                          },
                          selfAvatarURL: AnchorInfoStore.shared.iconURL?.absoluteString,
                          onRequestOpenWaiting: {
                              // v22（2026-07-11）：Waiting 按钮 tap 时才打开 waiting popup（不自动触发）
                              showPKInviteWaiting = true
                          })
                .presentationDetents([.fraction(0.6), .fraction(0.8)])
                .presentationDragIndicator(.visible)
        }
        // G M3 / spec §6.1：PK 各态 overlay 合并为单一 PKOverlayHost，避免 5 层 _OverlayModifier
        // 链路 layout pass + 多 overlay 同时订阅 pkStore 触发 body 重算。
        .overlay { PKOverlayHost(pkStore: pkStore, resultBridge: pkResultBridge) }
        // PK 4 popup（iteration 3 全套 UI 同步）挂在 PKOverlayHost 之上（z 序更高）——
        // rule swiftui-body-type-check-timeout：合并 4 个 overlay 为 1 个，ZStack 内保持原 z 顺序
        .overlay { pkPopupsOverlay }
        // v7 顶部 2 个 placeholder popup（Task / Audience）；Contribution/Rank/Roulette 已迁独立 sheet
        .modifier(TopPlaceholderPopupsModifier(showTask: $showTaskPopup,
                                                showAudience: $showAudiencePopup))
        // v8/v9/v10 5 层 overlay（送礼动画 / 进场飘屏 / 钻石盲盒飘屏 / 付费弹幕飘屏 / 心愿达成飘屏）
        .modifier(LiveOverlayHost(giftQueue: nim.giftAnimationQueue,
                                   enterRoomQueue: nim.enterRoomQueue,
                                   diamondQueue: nim.diamondGiftQueue,
                                   paidBulletQueue: nim.paidBulletQueue,
                                   wishAchievedQueue: nim.wishAchievedQueue,
                                   isHost: true))
        // v9/v10 5 新 sheet/popup（虚拟道具开关 / 公告 / UserCard / Gift picker / 心愿单半屏面板）
        .modifier(LiveRoomExtraOverlaysModifier(
            virtualPropsStore: virtualPropsStore,
            showEffectSwitchPopup: $showEffectSwitchPopup,
            showAnnouncementPopup: $showAnnouncementPopup,
            userCardUserId: $userCardUserId,
            showGiftPicker: $showGiftPicker,
            roomIdStr: "\(roomInfo.id ?? 0)",
            wishlistStore: nim.wishlistStore,
            showWishlistPanel: $showWishlistPanel,
            liveRecordId: "\(roomInfo.id ?? 0)",
            onAnnouncementSaved: handleAnnouncementSaved
        ))
        .onAppear(perform: handleStoresInitialLoad)
        // v7 Contribution / Rank / Roulette 独立 sheet（对齐 H5 真交互）
        .modifier(TopSheetsModifier(
            uidStr: SessionStore.shared.user?.userId.map(String.init) ?? "",
            roomIdStr: "\(roomInfo.id ?? 0)",
            showContribution: $showContributionSheet,
            showRank: $showRankSheet,                                  // v16 girlWeeklyRank
            showUserWeeklyRank: $showUserWeeklyRankSheet,              // v16 userWeeklyRank
            // v14 Q3 sheet load 完成后回填顶部 rank 徽章（对齐 H5 "无推送→查看后更新"）
            onRankUpdate: { [weak nim = nim] rank in nim?.anchorRankStore.setRank(rank) },
            showRouletteSetting: $showRouletteSetting,
            showRouletteIntro: $showRouletteIntro,
            onRouletteEnabledChanged: { newValue in isRouletteEnabled = newValue },
            onRouletteToast: { msg in withAnimation { comingSoonToast = msg } }
        ))
        // 依 pkStore.state 转换自动挂载 InviteWaiting / MatchFailed
        // - inviting：发出邀请后自动挂载 InviteWaiting（对齐 H5 pkInviteWaitingPopup）
        // - matching → idle/failed：视为匹配失败，自动挂载 MatchFailed（对齐 H5 pkMatchFailedPopup）
        .onChange(of: pkStore.state, perform: handlePKStateChange)
        // v17 设置弹窗改 Bottom Sheet + 3 列 Grid（对齐 H5 liveSettingPopup.vue）
        .sheet(isPresented: $showSettingSheet) {
            LiveSettingBottomSheet(
                isPresented: $showSettingSheet,
                beautyAvailable: store.beautyAvailable,
                onOpenBeauty:       { showBeauty = true },
                onOpenEffects:      { showEffectSwitchPopup = true },
                onOpenAnnouncement: { showAnnouncementPopup = true },
                onEndLive:          { Task { await store.endLive() } }
            )
            .sheetTopInset()
            .presentationDetents([.fraction(0.32)])
            .presentationDragIndicator(.visible)
        }
        // 直播间半屏消息列表（对齐 H5 messagePopup 408pt） —— 底部工具栏消息按钮触发；
        // 直播 RTC 全程不中断（sheet 保留底层可见，@StateObject camera/agora 生命周期独立）
        .sheet(isPresented: $showMessageSheet) {
            ConversationSheetContent(
                store: sessionStore,
                onSelectSession: { session in
                    selectedChatPeer = ChatSheetPeer(id: session.id)
                },
                onClose: { showMessageSheet = false }
            )
            .presentationDetents([.fraction(0.55)])
            .presentationDragIndicator(.visible)
        }
        // 直播间半屏私聊页（对齐 H5 talkPopup 548pt 叠加）—— 从半屏消息列表点会话触发；
        // ChatDetailContainer.onClose 非 nil → ChatDetailView 走 sheet 承载模式（chevron 变 xmark，跳过 nav bar hidden + swipe pop）
        .sheet(item: $selectedChatPeer) { peer in
            ChatDetailContainer(
                peerYxAccId: peer.id,
                selfYxAccId: SessionStore.shared.user?.yxAccid ?? "",
                onClose: { selectedChatPeer = nil }
            )
            .presentationDetents([.fraction(0.75), .large])
            .presentationDragIndicator(.visible)
        }
        .animation(.easeInOut(duration: 0.2), value: pkStore.state)
        .alert(L10n.liveRoomPermissionAlertTitle, isPresented: $store.permissionDeniedAlert) {
            Button(L10n.liveRoomPermissionAlertOK) { dismiss() }
        } message: {
            Text(L10n.liveRoomPermissionAlertMessage)
        }
        .onAppear(perform: handleMainOnAppear)
        .onDisappear(perform: handleOnDisappear)
        .onChange(of: store.state, perform: handleStoreStateChange)
        // v5.8：本体 CameraPreview 的帧 sink 由 CameraManager.subscribers 字典持有，
        // 与 PIP CameraPreview 的 sink 独立共存；PIP 在 dismantleUIView 时精准注销自己那一格，
        // 本体不再依赖任何 SwiftUI re-eval 时机。详见 Sources/Camera/CameraPreview.swift v5.8 注释。
        // 美颜参数变化 → renderer 更新已下沉到 BeautyPanel 子 view（throttle 60ms），父 view 不再监听
        // 直播时长由 LiveStore.elapsedTimerStore 在 attachLiving/teardown 内自管启停；
        // 时间 capsule 通过独立 LiveElapsedCapsule 子 view 订阅，避免 1Hz 触发本树重渲染。
        // D 里程碑：CallView + returnLive 倒计时覆盖 —— 合并为单 overlay（rule swiftui-body-type-check-timeout）
        .overlay { callAndReturnLiveOverlays }
        .animation(.easeInOut(duration: 0.2), value: callState)
        .onReceive(callStore.$state) { newState in callState = newState }
        // v22 私 call 开关反向同步：IM attachType 52（后端广播）走 store 更新，UI 层跟随
        .onReceive(store.$privateCallOpen) { open in
            if privateCallOn != open { privateCallOn = open }
        }
        .animation(.easeInOut(duration: 0.2), value: store.isWaitingReturnLive)
        // Task 9：声明本 view 属于 GiftEffect .live 场景 —— onAppear 时 setActiveScene，onDisappear 时 leaveScene（硬中断+清队列）
        // ⚠️ scopeId 必须用 **yxRoomId**（云信房间 id），与 NIMChatroomManager.enter(roomId:) + IM handler intake.ingest(scopeId:) 完全一致；
        // 用业务 roomId (store.roomId) 会导致 Center.activeKey ≠ item.sceneKey → enqueue rejected（2026-07-09 真机反悔真根因）
        .giftEffectScene(.live, scopeId: roomInfo.yxRoomId.map(String.init) ?? "")
    }

    private var mainZStack: some View {
        ZStack {
            // 底层背景：Live 页深紫黑（对齐 Theme.Palette.liveBottomDark #0B0010）；
            // PK 中 CameraPreview 缩小到左半视频窗后，上/下/右半均露出此底色
            Theme.Palette.liveBottomDark.ignoresSafeArea()
            if authorized {
                if isPKActive {
                    // PK 中：CameraPreview **真正缩小**到左半 videoHeight 区域（对齐 H5 pkBattleView `h-374`）
                    // 不再用"上下黑遮罩"假缩小；改为限制 UIView 实际 frame，MTKView 自然响应尺寸变化
                    // 2026-07-07 v4 架构级根治：对方视频 PKOppositeContainer 与本端 CameraPreview 放
                    // 同一 HStack 直接兄弟位置 → SwiftUI 保证严格共坐标系，本端与对方视频 100% 齐平
                    // （原方案分离到 PKArenaView 独立 GeometryReader，两个 sibling GR 无法保证 pixel 级对齐）
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer().frame(height: PKArenaLayout.topOffset)
                            HStack(spacing: 0) {
                                CameraPreview(camera: camera, agora: agora)
                                    .frame(width: geo.size.width / 2,
                                           height: PKArenaLayout.videoHeight)
                                    .clipped()
                                PKOppositeContainer(view: agora.oppositeRemoteView)
                                    .frame(width: geo.size.width / 2,
                                           height: PKArenaLayout.videoHeight)
                                    .clipped()
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    CameraPreview(camera: camera, agora: agora).ignoresSafeArea()
                }
            }
            // G M3 / spec §6.1：PKArenaView 跨 .starting/.inPK/.punishing 三态用 if 链承载（铁律 §1）；
            // .id("pkArena") 锁 identity 避免 dismantleUIView 反复触发 → AgoraRtcVideoCanvas.view 黑屏。
            if isPKActive {
                PKArenaView(store: pkStore, agora: agora)
                    .id("pkArena")
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            VStack(spacing: 8) {
                // v11 fix: LiveRoomHeroTopArea 15+ 参数调用 inline 触发 SwiftUI type-check timeout，
                // 抽到 computed property `heroTopArea` 减轻 body 类型推导复杂度
                heroTopArea
                // DEBUG NetworkPanel 之前挂在此处影响真机视觉（2026-07-06 用户反馈"去掉网络监控展示"）；
                // struct 定义仍保留于文件底部供开发调试临时接入，不再默认挂载

                if !store.beautyAvailable {
                    Text(L10n.beautyUnavailableHint)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                if let netToast = store.networkWarningToast {
                    networkBanner(netToast)
                }
                if let toast = store.warningToast {
                    warningBanner(toast)
                }
                if let toast = comingSoonToast {
                    comingSoonBanner(toast)
                }
                Spacer()
                // 公屏消息 + 右侧 Private Call 小开关（对齐 H5 liveRoom.vue:639-679：左公屏 flex-1 + 右操作列 van-switch）
                HStack(alignment: .bottom, spacing: 8) {
                    PublicChatListView(feed: publicChatFeed, theme: .live)
                        .frame(maxHeight: 260)
                        .onReceive(nim.messagesStore.$messages) { messages in
                            publicChatFeed.replace(messages.map(LivePublicChatAdapter.adapt))
                        }
                        #if DEBUG
                        // v19 DEBUG 三连击注入 15 类 mock 消息，验证 iOS 各 row 视觉
                        .onTapGesture(count: 3) {
                            PublicChatDebugInjector.injectAll(into: nim.messagesStore)
                        }
                        #endif
                    // PK 期间隐藏私 call 开关（对齐 H5 liveRoom.vue:466 shouldShowPrivateCall）
                    // 隐藏由 LiveStore.privateCallHiddenForPK 驱动，PKStore.transition 联动切换
                    if !store.privateCallHiddenForPK {
                        LiveRoomPrivateCallSwitch(isOn: $privateCallOn, onToggle: { next in
                            handlePrivateCallToggle(next)
                        })
                        .padding(.bottom, 60)   // 让开底部工具栏 + gift row 高度，与 H5 pb-60 对齐
                    }
                }
                // 2026-07-07 v7：快捷礼物栏完全移除（用户明示"主播端没有快捷送礼"）——
                // 原以为 H5 有此栏但 PK 中隐藏，实测 H5 主播端从未显示此栏（LiveRoomGiftList 是观众端组件）。
                // 送礼入口仍由底部工具栏 gift 圆按钮承担（H 里程碑接入真礼物列表）
                // 底部工具栏 4 圆按钮（对齐 H5 liveRoom.vue:686-738：Input + PkEntryBtn + Msg + Gift + Setting）
                // - PKEntryButton 从原 .overlay(bottomTrailing) 迁到此处（对齐 H5 单入口，5 态视觉切换）
                // - Setting 按钮弹 confirmationDialog 承载「美颜 / 结束直播」（H 里程碑接入完整设置弹窗前的过渡）
                // - 移除原 DEBUG PK 按钮（PKEntryButton 5 态已覆盖入口）+ 原「结束直播」大红按钮（迁到 Setting 菜单 & 顶部 X）
                HStack(spacing: Theme.Metric.liveRoomToolbarGap) {
                    LiveRoomInputRow(text: $inputText, onSend: {
                        // sendText 内做 trim/空判/hasJoined 守卫 + 200 字截断（对齐 H5 maxlength）
                        // return true → 清空（H5 line 305 `if (res) inputText.value = ''`）
                        // return false → NIM send throw，保留 inputText 让用户重试（spec R5）
                        if nim.sendText(inputText) { inputText = "" }
                    })
                    PKEntryButton(store: pkStore,
                                  showInviteSheet: $showInviteSheet,
                                  onInterruptTap:  { showPKInterruptConfirm = true },
                                  onDisconnectTap: { showPKDisconnectConfirm = true })
                    LiveRoomToolButton(systemName: nil,
                                       imageName: "liveRoomToolMessageBadge",
                                       a11y: L10n.liveRoomToolMessage,
                                       action: { showMessageSheet = true })
                        .overlay(alignment: .topTrailing) {
                            // 未读红点（对齐 H5 sessionStore.newMsg），3 类会话未读合计 > 0 显示
                            if liveMessageUnreadTotal > 0 {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                    .offset(x: -2, y: 2)
                                    .accessibilityHidden(true)
                            }
                        }
                    LiveRoomToolButton(systemName: nil,
                                       imageName: "liveRoomToolGiftBadge",
                                       a11y: L10n.liveRoomToolGift,
                                       action: { showGiftPicker = true })   // 接入 CommonGiftPanel（.liveDisplayOnly，直播中纯展示）
                    LiveRoomToolButton(systemName: nil,
                                       imageName: "liveRoomToolSettingBadge",
                                       a11y: L10n.liveRoomToolSetting,
                                       action: { showSettingSheet = true })
                }
            }
            .padding(.horizontal, Theme.Metric.liveRoomScreenHPadding)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    // MARK: - body modifier handlers（编译器泛型推导减负 —— rule swiftui-body-type-check-timeout）

    /// PK 4 popup 合并为单 overlay 的 ZStack；保持原 z 顺序（后声明 z 更高）
    @ViewBuilder private var pkPopupsOverlay: some View {
        ZStack {
            PKInterruptConfirmPopup(isPresented: $showPKInterruptConfirm, store: pkStore)
            PKDisconnectConfirmPopup(isPresented: $showPKDisconnectConfirm, store: pkStore)
            PKMatchFailedPopup(isPresented: $showPKMatchFailed, onInitiate: {
                showInviteSheet = true   // 匹配失败 → 弹发起 PK 邀请弹窗
            })
            PKInviteWaitingPopup(store: pkStore, isPresented: $showPKInviteWaiting)
        }
    }

    /// 通话覆盖层：CallView（callState != .idle）+ returnLive 倒计时（挂断后 15s）
    @ViewBuilder private var callAndReturnLiveOverlays: some View {
        // D 里程碑：直播态期间收到私 call → CallView 顶层 overlay 覆盖直播画面。
        // 对齐 H5 g-faceTime 浮层模式。state != .idle 时显示（含 .calling/.connecting/.connected/.ended 过渡态）。
        if callState != .idle {
            // D 里程碑修复（v5.4）：注入直播侧 camera/beauty 复用同一路采集，
            // 避免 CallFaceTimeView 自启第二个 CameraManager 实例抢占摄像头 →
            // reason=3 → 20s watcher → forceEnd endType=5 误下播；同时保留主播美颜参数。
            CallView(store: callStore, liveCamera: camera, liveBeauty: beauty)
                .transition(.opacity)
        }
        // D 里程碑：通话挂断后 15s 倒计时覆盖层（对齐 H5 liveRoom.vue:218-227 waitingReturnLive）。
        // CallView overlay 在 callState→.ended/.idle 后消失，本覆盖层接力显示倒计时直到 rejoinLive。
        if store.isWaitingReturnLive {
            returnLiveCountdownOverlay.transition(.opacity)
        }
    }

    /// v20 公告保存成功后：立即往公屏插入 announcement 消息（对齐 H5 pushRoomAnnouncementMsg）
    private func handleAnnouncementSaved(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        nim.messagesStore.append(PublicChatMessage(
            text: trimmed,
            isSystem: false,
            senderNickname: nil,
            senderAvatar: nil,
            userLevel: nil,
            isHost: false,
            isVip: false,
            messageType: .announcement
        ))
    }

    /// v10/v11 触发 4 个 store 初始化拉取（进房时）
    private func handleStoresInitialLoad() {
        nim.contributionStore.loadInitial()
        nim.anchorRankStore.loadInitial()
        // v16 topRankStore 需要 dbId (roomId) 才能调 apiSendRank(rankType='now', dbId:)
        nim.topRankStore.setRoomId(roomInfo.id)
        nim.topRankStore.loadInitial()
        nim.wishlistStore.loadInitial(
            anchorUserId: SessionStore.shared.user?.userId.map(String.init) ?? "",
            anchorNickname: SessionStore.shared.user?.nickname ?? title
        )
        loadRouletteEnabledStatus()
    }

    /// 拉取主播当前转盘开启状态用于顶部 icon 显示
    /// 对齐 H5 [liveRoomTop.vue onMounted L164-172] `getQueryWheelConfigByAnchorId → rouletteStatus`
    private func loadRouletteEnabledStatus() {
        let uid = SessionStore.shared.user?.userId.map(String.init) ?? ""
        guard !uid.isEmpty else { return }
        Task {
            if let cfg = try? await RouletteServiceReal().queryConfig(anchorUserId: uid) {
                await MainActor.run { isRouletteEnabled = cfg.enabled }
            }
        }
    }

    /// 依 pkStore.state 转换自动挂载 InviteWaiting / MatchFailed
    /// - inviting：发出邀请后自动挂载 InviteWaiting（对齐 H5 pkInviteWaitingPopup）
    /// - matching → idle/failed：视为匹配失败，自动挂载 MatchFailed（对齐 H5 pkMatchFailedPopup）
    private func handlePKStateChange(_ newState: PKStateMain) {
        defer { lastPKState = newState }
        // 对齐 H5 精确行为（2026-07-11 反悔上一轮 over-close）：
        // - H5 pkInitiatePopup.vue:254-258 `pkStatus !== 'Live'` 只调 closePopup() 重置搜索状态，**不关闭 sheet**
        // - H5 liveRoom.vue:558-559 真正 `showPkInitiatePopup.value=false` 只在 `pkStatus === 'InPK'` 时
        // → iOS 对齐：**仅 .inPK / .punishing 关闭邀请 sheet**；`.matching / .inviting / .invited / .starting / .endingPK` 全保留
        if newState == .inPK || newState == .punishing {
            showInviteSheet = false
        }
        switch newState {
        case .inviting:
            // v22（2026-07-11）：不再自动弹 waiting popup（用户明示：只在 Waiting 按钮 tap 时才弹）
            break
        case .idle, .failed:
            // 上一态是 matching → 未进 starting/inPK 就回到 idle/failed，视为匹配失败
            if lastPKState == .matching { showPKMatchFailed = true }
            // PK 结束 / 邀请超时清理相关 popup
            showPKInviteWaiting = false
            showPKInterruptConfirm = false
            showPKDisconnectConfirm = false
        case .starting, .inPK, .punishing:
            // 一旦进入 PK 流程，取消匹配失败提示（防误触）
            showPKMatchFailed = false
            showPKInviteWaiting = false
        default:
            break
        }
    }

    /// 主 onAppear：suspend 离线监测 + Sharer attach + camera/agora/nim/pkStore 全套 wire
    private func handleMainOnAppear() {
        // 长时间无操作自动离线：直播中暂停监测（对齐 H5 isBusy 停 timer）
        AutoOfflineMonitor.shared.suspend()
        camera.renderer.updateParameters(beauty)
        // K 里程碑 P0-2 fix（2026-07-03 review 202607030426）：接入 Sharer `.live` token,
        // 让用户在美颜设置页调过的 25+ 参数 + 贴纸广播到直播 renderer。首帧 apply 保证
        // 用户不进设置页直接开播时 SDK 参数与 K store defaults 一致（对齐 CallView 模式）。
        // 注意与上一行 legacy updateParameters(beauty) 并存：legacy 只影响 4 参数（BeautyPanel
        // 用户拖 slider 时覆盖），K store 覆盖 25+ 参数；两条路径不冲突。
        BeautyPipelineSharer.shared.attach(camera.renderer as AnyObject & BeautyRenderer, token: .live)
        BeautyPipelineSharer.shared.reportSetupResult(camera.isBeautyFallback ? .failure(.genericSetupFailed) : .success(()))
        camera.renderer.apply(BeautyPipelineSharer.shared.store.settings)
        // M2：相机错误转发到 store
        // v5.11 真根因修复：CameraManager 的 onError 3 处调用点全在 DispatchQueue.main.async 内,
        // 已保证 wasInterrupted → interruptionEnded 的 FIFO 派发顺序；此处用 Task { @MainActor in }
        // 二次包装会把 start/stopWatcher 拆到两个独立 Task 排队等 MainActor executor,
        // Swift Task 调度非严格 FIFO → 反序时 stopWatcher 先跑（无操作）后 startWatcher 起孤儿 watcher,
        // 20s 后误触发 forceEnd(.cameraFailure)。改 assumeIsolated 同步执行、复用 main queue FIFO。
        camera.onError = { error in
            MainActor.assumeIsolated {
                store.onCameraError(error)
            }
        }
        // M2：美颜降级通知（CameraManager init 时已确定）
        if camera.isBeautyFallback {
            store.markBeautyUnavailable()
        }
        // M2：声网双向 wire（token 续期 + networkQuality 转发）
        // v5.1：同时注入 camera 让 monitor degrade 时节流推帧
        store.wire(agora, camera: camera)

        CameraManager.requestAccess { ok in
            authorized = ok
            if ok {
                camera.start()
            } else {
                store.onCameraError(.permissionDenied)
            }
        }
        agora.join(channelId: roomInfo.agoraChannelId ?? "",
                   token: roomInfo.rtcToken ?? "",
                   uid: UInt(roomInfo.userId ?? 0))
        if let yx = roomInfo.yxRoomId, let user = SessionStore.shared.user {
            // H M5：IM 登录由 NIMOnlineKeeper.start 在 SessionStore.login 后已完成；
            // NIMChatroomManager.enter 仅进聊天室，不再传 account/token。
            nim.enter(roomId: "\(yx)",
                      nickname: user.nickname ?? L10n.liveRoomAnchorDefault)
        }
        store.attachLiving(roomInfo: roomInfo)
        // D 里程碑：注入 LiveStore 给 CallStore + 挂 observer（直播态期间直播私 call 接听 +
        // 通话挂断后 resumeCall 回直播的协议入口）。weak 引用，LiveRoomView 销毁时自动清理。
        CallStore.shared.liveStore = store
        CallStore.shared.observer = store
        // G M6：把 PKStore 注入给 CallStore，PK 期收到私 call 自动 busy reject（spec §8.2）
        CallStore.shared.pkStore = pkStore
        // G M3：PKStore 注入。weak 引用，PKStore 在 LiveRoomView 销毁时随 @StateObject 一起释放。
        pkStore.liveStore = store
        pkStore.agora = agora
        pkStore.nim = nim
        pkStore.observer = pkResultBridge
        pkStore.networkMonitor = store.networkMonitor
        pkStore.ownAnchorId = SessionStore.shared.user?.userId ?? 0
        pkStore.ownRoomId = roomInfo.id ?? 0
        // M3 bug 修复：声网 PK 多频道 join 时复用主直播 rtcToken（绑 uid 不绑 channel）
        pkStore.rtcToken = roomInfo.rtcToken ?? ""
        // H M5：PK router 走 NIMService 路由链路
        NIMService.shared.registerRouter(pkStore.router)
        // H M4：注入直播态 weak liveStore；全局 sysRouter 由 NIMService.setupOnce 永驻注册
        SystemMessageRouter.shared.liveStore = store
    }

    /// v5.3.3 真根因修复：SwiftUI 在 ScenePhase=.background 时也会触发 onDisappear（snapshot 用），
    /// 若此时 tearDown camera/agora/nim，则切后台→回前台后帧分发永久断开（v5.8 已用 subscribers
    /// 字典让每个 CameraPreview 独立注销，仍以"真正 dismiss 才清理"为正路径）。
    private func handleOnDisappear() {
        // 场景 A（切后台）：guard 短路，资源保留等待回前台
        guard scenePhase != .background else { return }
        // 场景 B（真 dismiss）：无论 .living / .forceEnding / .ending / .ended 都清资源。
        // 各清理调用均幂等（review 202607071524 F4 抽 helper 去重）。
        performLiveTeardown()
        // 非 .ended 追加 endLiveRoom 兜底，避免僵尸房间（tryEnterEnding 内已 guard inFlightEnd
        // + state==.living，forceEnding 已在 flight 会被拦、无重复请求）
        if store.state != .ended {
            Task { await store.endLive() }
        }
    }

    /// B spec v7：直播结束 → env action 切 Work Tab + workPath 重建为 [liveResult]。
    /// LiveRoomView 随 path 替换自然 dismount → onDisappear 触发正常清资源；
    /// 无 fullScreenCover 层，用户从结果页 back 走标准 pop，swipe-back 原生支持。
    private func handleStoreStateChange(_ newState: LiveState) {
        if newState == .ended {
            liveResultTransition.perform(store.beginTimestamp, store.endTimestamp, store.endType)
        }
    }

    /// 直播资源清理（review 202607071524 F4 抽 helper 去重）。
    /// 两个触发点等价调用：
    /// - `onChange(store.state == .ended)`：直播结束后立即清（fullScreenCover 覆盖不触发 onDisappear）
    /// - `onDisappear`（非 background）：真 dismount 兜底
    /// 所有子操作均幂等——重复调用无副作用。
    private func performLiveTeardown() {
        AutoOfflineMonitor.shared.resume()
        // K 里程碑 P0-2 fix：detach Sharer 订阅（camera.tearDown 前，确保栈顶变化及时）
        BeautyPipelineSharer.shared.detach(camera.renderer as AnyObject & BeautyRenderer)
        camera.tearDown()
        // D 里程碑修复（v5.4）：agora.leave 改 async，非 async 上下文包 Task 让出；
        // nim.leave 与 camera.stop 同步走，不依赖 agora 完成。
        Task { await agora.leave() }
        nim.leave()
        camera.stop()
        NIMService.shared.unregisterRouter(pkStore.router)
        SystemMessageRouter.shared.liveStore = nil
        // G M3：PKStore teardown 取消倒计时 / 解 NQM 订阅 / 清字段
        Task { await pkStore.teardown() }
    }

    // MARK: - D 里程碑：挂断后回直播倒计时覆盖层

    /// v5.6 修订（用户反馈"返回直播后画面卡住"）：
    /// 通话结束回直播中央弹窗（对齐 H5 anchor-livechat-h5/src/views/liveSetting/components/returnLivePopup.vue）：
    /// - 旋转圆环 + 大数字倒计时
    /// - 提示文案 "X seconds later it will automatically return to live"
    /// - "Return to live" 按钮立刻触发 rejoin（无需等 15s 倒计时归 0）
    /// - 蒙层屏蔽底层交互（不可点关，对齐 CThemePopup close-on-click-overlay=false）
    private var returnLiveCountdownOverlay: some View {
        ReturnLivePopup(
            countdown: store.returnLiveCountdown,
            onReturn: { Task { await store.returnLiveNow() } }
        )
    }

    // MARK: - 合规警告条幅（NIM attachType=61 触发，3s 自动消失）

    private func warningBanner(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .center)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - "Coming soon" 占位提示 banner（点击设计稿里 H/I 里程碑未接入的入口时显示，3s 自消）

    private func comingSoonBanner(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.black.opacity(0.7), in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation { comingSoonToast = nil }
            }
    }

    // MARK: - 网络弱网降级条幅（NetworkQualityMonitor 触发，恢复时自动消失）

    private func networkBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark").font(.caption)
                .accessibilityHidden(true)
            Text(text).font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .center)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    // MARK: - G 里程碑 M0 调试面板（仅 DEBUG 构建）

    #if DEBUG
    private var pkDebugPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PK Test (M0)").font(.headline)
            Text("token 复用主直播 rtcToken；ownUid 复用 roomInfo.userId")
                .font(.caption2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Opposite channelId").font(.caption)
                TextField("e.g. anchor_xxx", text: $pkDebugChannel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Opposite uid").font(.caption)
                TextField("e.g. 123456", text: $pkDebugOppositeUid)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                Button("Join") {
                    Task { await runPKDebugJoin() }
                }
                .disabled(pkDebugChannel.isEmpty || pkDebugOppositeUid.isEmpty)
                .buttonStyle(.borderedProminent)
                Button("Leave") {
                    Task { await runPKDebugLeave() }
                }
                .disabled(pkDebugChannel.isEmpty)
                .buttonStyle(.bordered)
            }
            if !pkDebugMessage.isEmpty {
                Text(pkDebugMessage)
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .padding()
        .presentationDetents([.fraction(0.4)])
    }

    private func runPKDebugJoin() async {
        guard let uidInt = UInt(pkDebugOppositeUid.trimmingCharacters(in: .whitespaces)) else {
            pkDebugMessage = "invalid uid"
            return
        }
        let token = roomInfo.rtcToken ?? ""
        let ownUid = UInt(roomInfo.userId ?? 0)
        do {
            try await agora.joinPKOpposite(channel: pkDebugChannel,
                                           oppositeUid: uidInt,
                                           token: token,
                                           ownUid: ownUid)
            pkDebugMessage = "join requested, watch Console for didJoinedOfUid"
        } catch {
            pkDebugMessage = "join failed: \(error)"
        }
    }

    private func runPKDebugLeave() async {
        await agora.leavePKOpposite(channel: pkDebugChannel)
        pkDebugMessage = "leave completed for \(pkDebugChannel)"
    }
    #endif

    // MARK: - 美颜面板

    private var beautyPanel: some View {
        BeautyPanel(beauty: beauty, camera: camera)
    }

    // MARK: - v22 Private Call 开关：调 API + 失败回滚

    /// 对齐 H5 liveRoom.vue:367 `changePrivateCall`：调 updatePrivateCall；失败还原开关 + toast。
    /// 成功后写回 LiveStore 让 CallStore.handleIncomingVideoCall 立即感知（关闭时来电 busy reject）。
    private func handlePrivateCallToggle(_ next: Bool) {
        guard let rid = roomInfo.id, rid > 0 else {
            // 极端场景：roomInfo.id 缺失时接口无法调，回滚 UI + toast
            privateCallOn = !next
            comingSoonToast = L10n.liveRoomComingSoonPrivateCall
            return
        }
        // 乐观更新：先把 store 改成 next（让 CallStore 立即拦截来电，即使 API 未回来）
        store.setPrivateCallOpen(next)
        Task { @MainActor in
            do {
                try await LiveService.updatePrivateCall(roomId: rid, open: next)
            } catch {
                // 回滚（UI + store）+ toast（对齐 H5 "Private call switch failed, please try again."）
                privateCallOn = !next
                store.setPrivateCallOpen(!next)
                comingSoonToast = L10n.liveRoomComingSoonPrivateCall
            }
        }
    }

    // MARK: - v11 抽 LiveRoomHeroTopArea 到 computed property（缓解 SwiftUI type-check timeout）

    private var heroTopArea: some View {
        // v22 修：顶部展示"主播昵称"，不是直播描述（title 是 liveDescribe/bio，误传成 anchorName）。
        // 对齐 H5 liveRoomTop.vue L202-204：`{{ userStore.mineInfo.nickname }}`
        LiveRoomHeroTopArea(
            anchorIconURL: SessionStore.shared.user?.icon,
            anchorName: SessionStore.shared.user?.nickname ?? title,
            hotScore: roomInfo.hotScore ?? 0,
            agora: agora,
            presence: nim.presenceStore,
            timerStore: store.elapsedTimerStore,
            isPKActive: pkStore.state == .starting
                        || pkStore.state == .inPK
                        || pkStore.state == .punishing,
            onClose: { Task { await store.endLive() } },
            onTaskTap:         { showTaskPopup = true },
            onContributionTap: { showContributionSheet = true },
            // v16 入口分派：Rank 徽章 → RankSheetView（girlWeeklyRank）；观众数 → UserWeeklyRankSheet（userWeeklyRank）
            onRankTap:         { showRankSheet = true },
            onAudienceTap:     { showUserWeeklyRankSheet = true },
            onRouletteTap:     handleRouletteTap,
            isRouletteEnabled: isRouletteEnabled,
            contributionStore: nim.contributionStore,
            anchorRankStore: nim.anchorRankStore,
            wishlistStore: nim.wishlistStore,
            onWishlistTap: { showWishlistPanel = true },
            topRankStore: nim.topRankStore
        )
    }

    /// Roulette tap 路由（对齐 H5 首次引导 localStorage 按 userId scope）
    private func handleRouletteTap() {
        let uidStr = SessionStore.shared.user?.userId.map(String.init) ?? ""
        let key = RouletteStore.introShownKey(userId: uidStr)
        if UserDefaults.standard.bool(forKey: key) {
            showRouletteSetting = true
        } else {
            showRouletteIntro = true
        }
    }
}

// MARK: - BeautyPanel：sheet 内独立 @ObservedObject，throttle 60ms 调 renderer
//
// 父 LiveRoomView 持 `let beauty` 不订阅 publish；只有 sheet 打开期间本子 view 监听并节流更新
// renderer，避免 slider 拖动每秒 30-60 次 publish 触发父 view 整树重算。
private struct BeautyPanel: View {
    @ObservedObject var beauty: BeautyParameters
    let camera: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.liveRoomBeautyPanelTitle).font(.headline)
            Toggle(L10n.livePrepareBeautyToggle, isOn: $beauty.enabled).tint(.pink)
            sheetSlider(L10n.livePrepareSliderBlur, value: $beauty.blur)
            sheetSlider(L10n.livePrepareSliderWhiten, value: $beauty.whiten)
            sheetSlider(L10n.livePrepareSliderEyeEnlarge, value: $beauty.eyeEnlarge)
            sheetSlider(L10n.livePrepareSliderFaceThin, value: $beauty.faceThin)
            Spacer()
        }
        .padding()
        .presentationDetents([.fraction(0.4)])
        .onReceive(
            beauty.objectWillChange
                .throttle(for: 0.06, scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            camera.renderer.updateParameters(beauty)
        }
    }

    private func sheetSlider(_ t: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t)
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1).tint(.pink).disabled(!beauty.enabled)
        }
    }
}

// MARK: - 时间 capsule（订阅独立 LiveTimerStore，1Hz 写不波及 LiveRoomView 主树）

private struct LiveElapsedCapsule: View {
    @ObservedObject var timerStore: LiveTimerStore

    var body: some View {
        let secs = timerStore.elapsedSeconds
        let timeString = String(format: "%02d:%02d", secs / 60, secs % 60)
        return HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(String(format: L10n.liveRoomStatusLiveFormat, timeString))
                .font(.caption).foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.4), in: Capsule())
    }
}

// MARK: - AgoraStatusText / AgoraConnectingCapsule（复查 202607012202 S-8）
//
// 把 topBar 内 agora.message / agora.state 的读点收敛到子 view，让 LiveRoomView 主 body
// 不再订阅 AgoraManager.objectWillChange —— agora.remoteUid / message / state 高频变（弱网
// 109/110 didOccurError 反复触发）时不再整树重算 CameraPreview / PKArenaView / publicScreen。
// 对齐 [.claude/rules/swiftui-keepalive-publisher-isolation.md] 订阅隔离原则。
// LiveRoomView 顶层保留 `@StateObject agora` 归属生命周期，body 只把引用传给这两个子 view。

private struct AgoraStatusText: View {
    @ObservedObject var agora: AgoraManager

    var body: some View {
        Text(agora.message.isEmpty ? agora.state.label : agora.message)
            .font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
    }
}

private struct AgoraConnectingCapsule: View {
    @ObservedObject var agora: AgoraManager
    let timerStore: LiveTimerStore

    var body: some View {
        if agora.state == .joined {
            LiveElapsedCapsule(timerStore: timerStore)
        } else {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(L10n.liveRoomStatusConnecting)
                    .font(.caption).foregroundStyle(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
        }
    }
}

// MARK: - 网络监控调试面板（v5.1，弱网计数实时显示）
// 独立子 view + 独立 NetworkDebugStore：高频 2s/次的网络计数变化只触发本 view body re-eval，
// 不再影响 LiveRoomView 主树（详见 LiveStore.networkDebugStore）。
// 仅 DEBUG 构建编译，release 剥离整个 struct（减少 binary footprint + 避免审核侧看到）。

#if DEBUG
private struct DebugNetworkPanel: View {
    @ObservedObject var debugStore: NetworkDebugStore

    var body: some View {
        let info = debugStore.info
        let statusColor: Color = {
            switch info.status {
            case "normal":   return .green
            case "degraded": return .orange
            case "ended":    return .red
            default:         return .gray
            }
        }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text("net.\(info.status) bad=\(info.bad)/10→30 good=\(info.good)/5")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
            }
            Text("tx=\(info.lastTx) rx=\(info.lastRx) worst=\(info.lastWorst) total=\(info.total)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Text("agora.fps=\(info.agoraFps) cam.fps=\(info.cameraFps)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif

// MARK: - PKOverlayHost：合并 5 个 PK overlay
//
// 原实现：5 个连续 `.overlay { ... }` 包裹 PKMatchingOverlay / PKInvitedSheet / PKPunishingOverlay /
// PKResultOverlay 4 个状态层 + PKEntryButton 入口按钮 — 每层都是独立 `_OverlayModifier`，
// layout pass 反复算尺寸；且各子 view 都 `@ObservedObject pkStore`，任一字段变更触发所有 body 重算。
// 现合并为单一 host，所有 PK 状态层共享一个 `.overlay`，PKEntryButton 保留为独立 bottomTrailing overlay。
private struct PKOverlayHost: View {
    @ObservedObject var pkStore: PKStore
    @ObservedObject var resultBridge: PKResultBridge

    var body: some View {
        ZStack {
            PKMatchingOverlay(store: pkStore).transition(.opacity)
            PKInvitedSheet(store: pkStore).transition(.opacity)
            PKPunishingOverlay(store: pkStore).transition(.opacity)
            PKResultOverlay(isPresented: $resultBridge.presented,
                            myScore: resultBridge.myScore,
                            oppositeScore: resultBridge.opponentScore,
                            top3: resultBridge.top3)
        }
    }
}

// PublicScreenList / LiveRoomChatList / LiveRoomChatRow 已迁移到 Sources/PublicChat/UI/PublicChatListView.swift
// （Phase 1 T7/T10）。本文件不再自持公屏 UI 分派逻辑。


/// review 202606260029 P1-1：onlineCount 子 view 内观测。
/// 父 view 顶层不读 `nim.presenceStore.onlineCount`，避免 .enter/.exit 通知触发整树重算。
private struct OnlineCountText: View {
    @ObservedObject var store: ChatPresenceStore

    var body: some View {
        Text("\(store.onlineCount)").font(.caption)
    }
}

// MARK: - 设计稿还原：顶部主播胶囊
//
// 视觉：黑色 40% 半透胶囊内 [头像 + 名字 + (热度火 + 数字) + (直播状态点 + 时长)]。
// 时长走独立子 view 订阅 timerStore（1Hz 变化不波及本 view 主 body）。
fileprivate struct LiveRoomAnchorPill: View {
    let anchorIconURL: String?
    let anchorName: String
    let hotScore: Int
    @ObservedObject var agora: AgoraManager
    let timerStore: LiveTimerStore

    var body: some View {
        HStack(spacing: 6) {
            AvatarView(urlString: anchorIconURL, size: Theme.Metric.liveRoomChipAvatar, kind: .anchor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(anchorName)
                    .font(Theme.Typography.liveRoomAnchorName)
                    .foregroundColor(Theme.Palette.liveRoomAnchorName)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image("liveRoomHotIcon")
                            .resizable().frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        // 走 FormatStyle 按 Locale.current 渲染（review 202607031955 P2-3，
                        // 对齐 BlocklistRow.swift `Text(age, format: .number)` 先例）
                        Text(hotScore, format: .number)
                            .font(Theme.Typography.liveRoomAnchorMeta)
                            .foregroundColor(Theme.Palette.liveRoomAnchorMeta)
                    }
                    if agora.state == .joined {
                        LiveRoomAnchorElapsed(timerStore: timerStore)
                    } else {
                        Text(L10n.liveRoomStatusConnecting)
                            .font(Theme.Typography.liveRoomAnchorMeta)
                            .foregroundColor(Theme.Palette.liveRoomAnchorMeta)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Metric.liveRoomChipHPadding)
        .padding(.vertical, Theme.Metric.liveRoomChipVPadding)
        .background(Theme.Palette.liveRoomChipBackground, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// 独立订阅 timerStore：1Hz 更新不波及 LiveRoomAnchorPill 主体（agora.state 变时才刷）。
fileprivate struct LiveRoomAnchorElapsed: View {
    @ObservedObject var timerStore: LiveTimerStore

    var body: some View {
        let secs = timerStore.elapsedSeconds
        HStack(spacing: 3) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(String(format: "%d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60))
                .font(Theme.Typography.liveRoomAnchorMeta)
                .monospacedDigit()
                .foregroundColor(Theme.Palette.liveRoomAnchorMeta)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 设计稿还原：顶部右侧（Top 观众头像叠 + 观众数徽章 + 关闭 X）

fileprivate struct LiveRoomTopActions: View {
    @ObservedObject var presence: ChatPresenceStore
    /// v11 顶部右侧 Top2 送礼头像 store（对齐 H5 liveStore.topRankList）
    @ObservedObject var topRankStore: LiveTopRankStore
    /// v11 tap 观众数字 → 弹送礼周榜（对齐 H5 rankPopup）；上层直接 set showRankSheet=true
    let onAudienceTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Theme.Metric.liveRoomBadgeGap) {
            // v11 Top2 送礼头像 —— 从固定切图升级为 store 驱动 + 金/紫边框 + 皇冠角标
            // v22 tap → onAudienceTap（同观众数 tap，弹 UserWeeklyRankSheet）
            // 对齐 H5 liveRoomTop.vue L228 `@click.stop="() => emit('openUserWeeklyRank', 1)"`
            top2Avatars
                .contentShape(Rectangle())
                .onTapGesture(perform: onAudienceTap)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(L10n.liveRoomViewerCountA11y))

            // 观众数徽章 v6 改可点击（tap → 观众 popup）
            // v19 Q3 根治：对齐 H5 audienceNum（live.js:121-137 getAudienceList）：
            //   presence.onlineCount 现在由 NIMChatroomManager.syncAudienceNumFromMembers 提供，
            //   走 NIM fetchChatroomMembers + 过滤主播 + 30s 定时纠错，直接是真实观众数（不含主播）
            //   对齐 H5 `v-if="!!audienceNum"`：0 不显示徽章数字
            Button(action: onAudienceTap) {
                ZStack(alignment: .topTrailing) {
                    Image("liveRoomViewerCountIcon")
                        .resizable()
                        .frame(width: Theme.Metric.liveRoomViewerCountSize,
                               height: Theme.Metric.liveRoomViewerCountSize)
                    if presence.onlineCount > 0 {
                        Text(formatOnlineCount(presence.onlineCount))
                            .font(Theme.Typography.liveRoomViewerCount)
                            .foregroundColor(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.black.opacity(0.6), in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L10n.liveRoomViewerCountA11y))

            // 关闭 X
            Button(action: onClose) {
                Image("liveRoomCloseButton")
                    .resizable()
                    .frame(width: Theme.Metric.liveRoomCloseSize,
                           height: Theme.Metric.liveRoomCloseSize)
            }
            .accessibilityLabel(Text(L10n.liveRoomCloseA11y))
        }
    }

    /// v11 Top2 头像叠 —— 对齐 H5 `v-if="topRankList.length && topRankList[0]?.cost > 1"`：
    /// 无送礼数据（items 为空）时不渲染，只保留观众数徽章 + 关闭按钮
    @ViewBuilder
    private var top2Avatars: some View {
        if !topRankStore.items.isEmpty {
            HStack(spacing: -6) {
                ForEach(topRankStore.items) { item in
                    ZStack(alignment: .topTrailing) {
                        AvatarView(urlString: item.avatarUrl,
                                   size: Theme.Metric.liveRoomTopViewerSize,
                                   kind: .user)
                            .overlay(
                                Circle().stroke(topRankBorderColor(item.rank), lineWidth: 1.5)
                            )
                        // 皇冠角标（对齐 H5 live-crown-1/2.webp 偏右上）
                        Image(systemName: "crown.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(topRankBorderColor(item.rank))
                            .shadow(color: .black.opacity(0.3), radius: 1)
                            .offset(x: 2, y: -4)
                    }
                }
            }
        }
    }

    /// H5 Rank 1 金色 #FFC33A / Rank 2 紫色 #C2CCEC
    private func topRankBorderColor(_ rank: Int) -> Color {
        rank == 1 ? Color(hex: 0xFFC33A) : Color(hex: 0xC2CCEC)
    }
}

/// v11 观众数 "k+" 格式化（对齐 H5 `(num / 1000) >> 0` 整除截取）
fileprivate func formatOnlineCount(_ n: Int) -> String {
    n < 1000 ? "\(n)" : "\(n / 1000)k+"
}

// MARK: - 设计稿还原：Task / Diamond / Rank 徽章 row
//
// H5 对齐：liveRoomTop.vue Task icon + AnimatedNumber (贡献值) + LiveRoomTopAnchorRank。
// 本次为视觉占位，点击回调交给父组件（当前 no-op；H/I 里程碑接入真数据）。
fileprivate struct LiveRoomBadgeRow: View {
    let contributionValue: Int      // 顶部钻石累计（当场直播贡献值）
    let rankPosition: Int?          // 收礼周榜位次（nil = 未上榜）
    let onTaskTap: () -> Void
    let onContributionTap: () -> Void
    let onRankTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Metric.liveRoomBadgeGap) {
            Button(action: onTaskTap) {
                Image("liveRoomTaskBadge")
                    .resizable()
                    .frame(width: Theme.Metric.liveRoomBadgeHeight,
                           height: Theme.Metric.liveRoomBadgeHeight)
            }
            .accessibilityLabel(Text(L10n.liveRoomTaskA11y))

            Button(action: onContributionTap) {
                HStack(spacing: 4) {
                    // v17 钻石动图（对齐 H5 diamond-yellow-gif.gif）—— 从 Bundle 加载 gif 帧动画
                    // v21 用户明示 30pt（v20 6pt 因 UIImageView intrinsicContentSize=56 未被 frame 约束视觉溢出）
                    // AnimatedGIFView v21 修 hugging/compression low 让 SwiftUI frame 真生效
                    AnimatedGIFView(name: "diamond-yellow")
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    Text("\(contributionValue)")
                        .font(Theme.Typography.liveRoomBadgeText)
                        .foregroundColor(Theme.Palette.liveRoomBadgeNumber)
                }
                .padding(.horizontal, 8)
                .frame(height: Theme.Metric.liveRoomBadgeHeight)
                .background(Theme.Palette.liveRoomBadgeBackground,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.liveRoomBadge))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(L10n.liveRoomContributionA11y))

            Button(action: onRankTap) {
                HStack(spacing: 4) {
                    Image("liveRoomRankIcon")
                        .resizable()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    if let rank = rankPosition {
                        Text(String(format: L10n.liveRoomRankFormat, rank))
                            .font(Theme.Typography.liveRoomBadgeText)
                            .foregroundColor(Theme.Palette.liveRoomRankNumber)
                    } else {
                        Text(L10n.liveRoomRankUnlisted)
                            .font(Theme.Typography.liveRoomBadgeText)
                            .foregroundColor(Theme.Palette.liveRoomBadgeNumber)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.Palette.liveRoomBadgeNumber)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 8)
                .frame(height: Theme.Metric.liveRoomBadgeHeight)
                .background(Theme.Palette.liveRoomBadgeBackground,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.liveRoomBadge))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(L10n.liveRoomRankA11y))
        }
    }
}

// MARK: - 设计稿还原：Underway 红色徽章（右侧）
//
// 视觉占位：单纯的红色胶囊 + 白色 "Underway" 文字，表示"直播进行中"贴纸。
fileprivate struct LiveRoomUnderwayBadge: View {
    var body: some View {
        Text(L10n.liveRoomUnderwayLabel)
            .font(Theme.Typography.liveRoomUnderwayText)
            .foregroundColor(Theme.Palette.liveRoomUnderwayText)
            .padding(.horizontal, Theme.Metric.liveRoomUnderwayHPadding)
            .frame(height: Theme.Metric.liveRoomUnderwayHeight)
            .background(Theme.Palette.liveRoomUnderwayFill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.liveRoomUnderway))
            .accessibilityLabel(Text(L10n.liveRoomUnderwayLabel))
    }
}

// MARK: - 设计稿还原：Wishlist 卡片
//
// 视觉：半透黑卡片 + 礼物图 + 主播端货币 + 数字 + 进度条 + 分数文字。
// 数据为占位（totalCoin/currentCoin/targetCoin），未来接 wishStore（L 里程碑）。
/// v10 顶部心愿单小卡 —— 从硬编码 3 参数升级为 store 驱动 + 4s 轮播 + 完成态 + tap 打开半屏面板
fileprivate struct LiveRoomWishlistCard: View {
    @ObservedObject var store: WishlistStore
    let onTap: () -> Void
    @State private var currentIndex: Int = 0

    /// 对齐 H5 wishlist.vue L62-122：卡片尺寸 80×108pt 竖排布局 + van-swipe autoplay 4s + 手动滑动
    var body: some View {
        Group {
            if store.items.isEmpty {
                Button(action: onTap) { emptyCard }
                    .buttonStyle(.plain)
            } else if store.items.count == 1 {
                // 单条不需要 TabView（避免 SwiftUI TabView 单页 warning + 无必要的 gesture 挂载）
                Button(action: onTap) { cardContent(store.items[0]) }
                    .buttonStyle(.plain)
            } else {
                // TabView(.page) 原生支持手动 swipe；currentIndex 双向绑定 → autoplay Timer 递增即触发翻页动画
                TabView(selection: $currentIndex) {
                    ForEach(Array(store.items.enumerated()), id: \.offset) { idx, item in
                        Button(action: onTap) { cardContent(item) }
                            .buttonStyle(.plain)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(width: 80, height: 108)
            }
        }
        .frame(width: 80, height: 108)
        .onReceive(Timer.publish(every: 4.0, on: .main, in: .common).autoconnect()) { _ in
            guard store.items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex = (currentIndex + 1) % store.items.count
            }
        }
    }

    /// 空态：仅心愿单标签（对齐 H5 wishlist.vue v-if 无卡片时不渲染；本处保留可点击兜底容错）
    private var emptyCard: some View {
        VStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.4))
            Text("Wishlist")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(width: 80, height: 108)
        .background(Color.black.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    /// 单张卡片（对齐 H5 wishlist.vue L86-118 竖排布局）：
    /// 承诺文案(2行截断) / 礼物名 → 礼物图 44×44 → 钻石数(未完成) → 进度条 + 完成态标签
    private func cardContent(_ item: WishlistItem) -> some View {
        // v22 修：对齐 H5 wishlist.vue L31 `promiseText = fullList[0]?.promiseText` —— 多礼物共享首条 promise，
        // 而非每张卡各自的 promise（原实现读 item.promiseText 会导致 Crown 卡无 promise 时回落 giftName，
        // 与 Rose/Star 卡展示样式不一致，H5 上所有卡均展示同一条 promise）
        let sharedPromise = store.items.first?.promiseText
        return VStack(spacing: 2) {
            // v21 严格对齐 H5 wishlist.vue L88-93 h-24 固定高：
            // 有 promiseText → promise 两行截断（font-9 leading-12 bold text-center）
            // 否则         → giftName 一行 truncate（font-12 bold text-center）
            Group {
                if let promise = sharedPromise, !promise.isEmpty {
                    Text(promise)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .lineSpacing(1)
                } else {
                    Text(item.giftName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: 72, height: 24)

            // v17 礼物图 44×44 —— 从 item.giftIconUrl 加载（对齐 H5 wishlist.vue L94 item.giftSmallImg）
            wishlistGiftIcon(item: item)

            // 钻石价格（仅未完成态展示，对齐 H5 v-if="!isItemComplete"）
            if !item.isCompleted {
                HStack(spacing: 2) {
                    Image("liveRoomWishlistCoin")
                        .resizable().frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text("\(item.giftPrice)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            // 进度条 + 状态文字（H5 完成态分两行 / 未完成态同行数字）
            if item.isCompleted {
                VStack(spacing: 2) {
                    progressBar(ratio: 1, width: 62)
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Color(hex: 0x1AFFCD))
                        Text(L10n.wishlistProgressComplete)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    progressBar(ratio: item.progress, width: 42)
                    Text("\(item.completedCount) / \(item.targetCount)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 4)
        .frame(width: 80, height: 108)
        .background(Color.black.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// v17/v21 心愿单礼物图 —— 优先真图 URL（对齐 H5 item.giftSmallImg），nil/失败时**按 giftName 分派不同 SF Symbol**
    ///
    /// **v21 修**：Fakes 阶段后端未返回 URL 时，根据 giftName（Rose/Star/Crown 等）匹配对应 SF Symbol，
    /// 用户在 Fakes 阶段能看到**3 张不同**的礼物图标（不再是同一张黄色 gift.fill 或灰色占位）
    @ViewBuilder
    private func wishlistGiftIcon(item: WishlistItem) -> some View {
        if let s = item.giftIconUrl, !s.isEmpty, let u = URL(string: s) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit)
                default:
                    giftSymbolFallback(for: item.giftName)
                }
            }
            .frame(width: 44, height: 44)
        } else {
            giftSymbolFallback(for: item.giftName).frame(width: 44, height: 44)
        }
    }

    /// v21 按 giftName 分派 SF Symbol + 主题色（Rose/Star/Crown 3 种视觉可区分）
    @ViewBuilder
    private func giftSymbolFallback(for name: String) -> some View {
        let (symbol, tint): (String, Color) = {
            let lower = name.lowercased()
            if lower.contains("rose") || lower.contains("heart") || lower.contains("flower") {
                return ("heart.fill", Color(hex: 0xFF3D8E))     // 粉玫瑰
            } else if lower.contains("star") {
                return ("star.fill", Color(hex: 0xFFE600))       // 黄星
            } else if lower.contains("crown") || lower.contains("king") {
                return ("crown.fill", Color(hex: 0xFFBB02))      // 金皇冠
            } else if lower.contains("diamond") {
                return ("diamond.fill", Color(hex: 0x66E5FF))    // 冰蓝钻石
            }
            return ("gift.fill", Color(hex: 0xFFE600))            // 兜底黄礼物
        }()
        Image(systemName: symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(tint)
            .padding(4)
            .accessibilityHidden(true)
    }

    /// H5 进度条通用绘制（渐变填充色对齐 H5 --lc-primary-color-1/2/3 粉紫渐变）
    private func progressBar(ratio: Double, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.2))
                .frame(width: width, height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(colors: [Color(hex: 0xFF9438), Color(hex: 0xFF0090), Color(hex: 0xFE00DE)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .frame(width: max(0, min(1, ratio)) * width, height: 4)
        }
        .frame(width: width, height: 4)
    }
}

/// safe subscript for Array
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 设计稿还原：顶部整体组合区（主播胶囊 + 顶部右侧 + 徽章 row + Underway + Wishlist）

fileprivate struct LiveRoomHeroTopArea: View {
    let anchorIconURL: String?
    let anchorName: String
    let hotScore: Int
    // 本 view body 不直读 agora/presence 任一字段，只把引用透传给已自订阅的子 view
    // (LiveRoomAnchorPill / LiveRoomTopActions)。用 `let` 而非 @ObservedObject 避免
    // 本层订阅 agora.state/message/remoteUid 与 presence.onlineCount 高频变更 →
    // 触发 Hero 层 5 个子 view 全量重算（review 202607031955 P2-4，命中
    // .claude/rules/swiftui-keepalive-publisher-isolation.md 规则 1）。
    let agora: AgoraManager
    let presence: ChatPresenceStore
    let timerStore: LiveTimerStore
    /// PK 中（starting/inPK/punishing）隐藏 Wishlist 卡片 —— 对齐 H5 pkBattleView.vue
    /// `v-if="!pkStore.isShowPkBattleView"` 语义。父 LiveRoomView 已订阅 pkStore.state，
    /// 只传布尔避免 Hero 层引入 pkStore 订阅。
    let isPKActive: Bool
    let onClose: () -> Void
    let onTaskTap: () -> Void
    let onContributionTap: () -> Void
    let onRankTap: () -> Void
    /// 观众徽章点击（v6 观众 popup）
    let onAudienceTap: () -> Void
    /// 顶部互动转盘按钮点击（对齐 H5 liveRoomTop.vue L256-273 rouletteButton）
    let onRouletteTap: () -> Void
    /// 转盘 icon 两态开关（对齐 H5 rouletteStatus: true=rouletteOpen / false=rouletteClose）
    let isRouletteEnabled: Bool
    // v10 数据源接入
    @ObservedObject var contributionStore: LiveContributionStore
    @ObservedObject var anchorRankStore: LiveAnchorRankStore
    @ObservedObject var wishlistStore: WishlistStore
    let onWishlistTap: () -> Void
    /// v11 顶部右侧 Top2 送礼头像 store
    @ObservedObject var topRankStore: LiveTopRankStore

    var body: some View {
        // v22：顶部内间距 -10pt（用户反馈"直播间顶部内间距减 10pt"），三行元素（Avatar / Badges / Wishlist）
        // 之间的 VStack spacing 由 10 → 0；padding.top 保持外层 VStack 的 8pt 不动
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                LiveRoomAnchorPill(anchorIconURL: anchorIconURL,
                                    anchorName: anchorName,
                                    hotScore: hotScore,
                                    agora: agora,
                                    timerStore: timerStore)
                // v11 反悔 v6：H5 无 Underway 徽章（校验 liveRoomTop.vue 无此元素），删除对齐
                Spacer()
                LiveRoomTopActions(presence: presence,
                                   topRankStore: topRankStore,
                                   onAudienceTap: onAudienceTap,
                                   onClose: onClose)
            }
            .padding(.bottom, 6)   // v22 主播胶囊栏下方补 6pt gap（外层 VStack spacing=0 会让其与 badges 行紧贴）
            HStack(alignment: .top) {
                LiveRoomBadgeRow(contributionValue: Int(contributionStore.currentLiveIncome),   // v10 动态
                                 rankPosition: anchorRankStore.currentRank,                       // v10 动态
                                 onTaskTap: onTaskTap,
                                 onContributionTap: onContributionTap,
                                 onRankTap: onRankTap)
                Spacer()
                Button(action: onRouletteTap) {
                    // 对齐 H5 liveRoomTop.vue L264-267：rouletteStatus 切 rouletteOpen/rouletteClose 两态
                    Image(isRouletteEnabled ? "rouletteOpen" : "rouletteClose")
                        .resizable()
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(L10n.liveRoomRouletteA11y))
            }
            // PK 中隐藏 Wishlist（对齐 H5 pkBattleView 布局）
            if !isPKActive {
                HStack(alignment: .top) {
                    LiveRoomWishlistCard(store: wishlistStore, onTap: onWishlistTap)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// LiveRoomChatRow / LiveRoomChatList 已迁移到 Sources/PublicChat/UI/PublicChatListView.swift + PublicChatRow.swift（Phase 1 T7/T10）
// 旧 ChatRowXXX 结构定义在 Sources/Live/PublicScreen/UI/ChatRowSubviews.swift 已由 T11 删除

// MARK: - 设计稿还原：Private Call 小开关（对齐 H5 liveRoom.vue:658-678 van-switch）
//
// H5 视觉：19x19 圆形 switch node（活动态 #FD79C1 粉色 / 非活动态 #898989 灰）+ 下方 12pt "Private call" 文字。
// 显示条件（H5 `v-if="roomInfo.giftId && shouldShowPrivateCall"`）在 iOS 侧未接入 gift 前先无条件显示，
// 由父 view 决定是否放到 chat area 右侧列。
fileprivate struct LiveRoomPrivateCallSwitch: View {
    @Binding var isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.Palette.liveRoomPrivateCallText : Color(hex: 0x898989))
                    .frame(width: 34, height: 20)
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
            .animation(.easeInOut(duration: 0.18), value: isOn)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(Text(isOn ? "on" : "off"))

            Text(L10n.liveRoomPrivateCallCaption)
                .font(Theme.Typography.liveRoomPrivateCall)
                .foregroundColor(Theme.Palette.liveRoomPrivateCallText)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let next = !isOn
            isOn = next
            onToggle(next)
        }
        .accessibilityLabel(Text(L10n.liveRoomPrivateCallCaption))
    }
}

// MARK: - 设计稿还原：底部工具栏（Say hi 输入 + 圆按钮）
//
// 2026-07-07 v7：LiveRoomGiftQuickTile + LiveRoomGiftQuickRow 已完全移除
// —— 用户明示"主播端没有快捷送礼"，H5 主播端此栏本就不存在（旧实现对齐错误）。
// Theme token `liveRoomGiftTile*` / `liveRoomGiftPrice` 保留供未来 gift picker 复用

/// 半屏私聊 sheet(item:) 的 Identifiable wrapper —— peerYxAccId 即 id。
fileprivate struct ChatSheetPeer: Identifiable {
    let id: String
}

fileprivate struct LiveRoomToolButton: View {
    let systemName: String?      // 非 nil 走 SF Symbol
    let imageName: String?       // 非 nil 走 Asset
    let a11y: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let sys = systemName {
                    // SF Symbol：套黑圆背景保持圆按钮视觉
                    Image(systemName: sys)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.white)
                        .frame(width: Theme.Metric.liveRoomToolButtonSize,
                               height: Theme.Metric.liveRoomToolButtonSize)
                        .background(Theme.Palette.liveRoomChipBackground, in: Circle())
                } else if let img = imageName {
                    // Asset 切图：本身已含灰底+icon（对齐设计稿"编组 29/5/27"），**不**再套背景
                    Image(img)
                        .resizable()
                        .frame(width: Theme.Metric.liveRoomToolButtonSize,
                               height: Theme.Metric.liveRoomToolButtonSize)
                }
            }
            .contentShape(Circle())
        }
        .accessibilityLabel(Text(a11y))
    }
}

fileprivate struct LiveRoomInputRow: View {
    @Binding var text: String
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(L10n.liveRoomInputPlaceholder, text: $text)
                .font(Theme.Typography.liveRoomInputPlaceholder)
                .foregroundStyle(.white)
                .tint(.white)
                .submitLabel(.send)
                .onSubmit(onSend)
                .padding(.leading, Theme.Metric.liveRoomInputHPadding)
                .frame(height: Theme.Metric.liveRoomInputHeight)
            Button(action: onSend) {
                Image("liveRoomSendButton")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .padding(.trailing, 8)
            }
            .accessibilityLabel(Text(L10n.liveRoomInputSendA11y))
        }
        .frame(height: Theme.Metric.liveRoomInputHeight)
        .background(Theme.Palette.liveRoomInputBackground,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.liveRoomInput))
    }
}
