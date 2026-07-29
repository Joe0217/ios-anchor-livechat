import SafariServices
import SwiftUI
import WebKit

/// 派对房主舞台（设计稿视觉重排 2026-07-11）。
///
/// **本次重写只重排视觉**，所有状态机 / RTC / IM / 礼物 / 邀请 / 自动离线 wiring 与旧版一致：
/// - `handleAppear` / `handleDisappear`：进退房 + 自动离线 suspend/resume
/// - `handleSeatListChange`：seatList 变化时更新 sortedSeatsCache
/// - `inviteAlertButtons` / `inviteAlertMessage`：视频位邀请
/// - `selfActionsButtons`：自己麦位操作 sheet
/// - `handleSeatTap`：麦位点击分流
/// - `sendText` / `sendDemoGift`：公屏 / 送礼
/// - `.giftEffectScene`：礼物特效场景绑定
///
/// **视觉层新增**：
/// - 全屏 partyRoomBg 背景图 + 深色遮罩
/// - 顶部主播条（PartyRoomAnchorBar）
/// - 3 大位（前 3 个 seatIndex）+ 10 小位（后续）
/// - 聊天区（tab strip + welcome + PartyMessageListView）
/// - 底部输入 + 5 工具按钮（PartyRoomInputBar）
struct PartyRoomView: View {
    let roomId: String
    /// v8：密码房进房时传入（对齐 H5 clickRoomItem 密码框语义）；普通房传 nil
    var password: String? = nil
    /// 仅 `topRoomGuide` 来源可触发掉出 TOPX 后的换房提醒。
    var entryPath: PartyRoomEntryPath = .standard
    /// 热门房引导确认后由 PartyTabRoot 替换当前路由，避免子页直接持有 NavigationPath。
    var onSwitchToHotRoom: ((String, PartyRoomEntryPath) -> Void)? = nil

    @ObservedObject private var store = PartyStore.shared
    /// 观众数权威源（对齐 H5 party.js:1017 NIM notification type=0/1 ++/--）：
    /// 直接订阅 PartyRoomChatManager.onlineCount（云信 chatroom 总在场人数,进/退实时增减），
    /// 而非 room/enter 一次性快照 `roomInfo.audienceNum`（后端多返 0）。
    @ObservedObject private var chat = PartyStore.shared.chat
    @Environment(\.dismiss) private var dismiss
    /// v5.3.3 真根因坑：SwiftUI 在 ScenePhase=.background 时也会调度 onDisappear，
    /// 必须双守卫防误退房。
    @Environment(\.scenePhase) private var scenePhase

    /// v16.10：内嵌 TextField 文本 state（对齐 LiveRoomView `inputText`）
    @State private var inputText: String = ""
    /// v16.10：输入框 focus state 桥（focused 时 PartyRoomInputBar 收起右侧按钮，TextField 占满宽度）
    @FocusState private var isInputFocused: Bool
    /// v16.11：键盘高度（`UIResponder.keyboardWillShow/Hide` 订阅）—— inputBar 手动 padding 上移
    @State private var keyboardHeight: CGFloat = 0
    /// H5 `footer-wrap.vue` 的房内一键发送词条；关闭仅作用于当前房间会话。
    @State private var quickPhrases: [PartyQuickPhrase] = []
    @State private var areQuickPhrasesDismissed = false
    @State private var showSelfActions: Bool = false
    @State private var showError: Bool = false
    /// 1040 视频位邀请倒计时；到零时主动回传 `respondInvite(action: 3)`。
    @State private var videoInviteRemainingSeconds: Int = 0
    @State private var didStartEnter: Bool = false
    /// v8 房主设置页 sheet（保留供其他路径直接触发；v8.1 主入口改走 activeRoomTool = .settings）
    @State private var showSettings: Bool = false
    /// v8.1 房间工具 sheet（enum-driven 单 sheet 切换，规避 iOS 16 双 sheet race）
    @State private var activeRoomTool: PartyRoomToolSheetKind? = nil
    /// 视频位邀请/麦位限制等房内操作的即时反馈 toast。
    @State private var roomActionToast: String? = nil
    /// E v2 §1：Room Mode 二次确认 sheet 之间共享的 pending tempId（模板 grid 选中 → 弹确认 sheet）
    @State private var pendingRoomModeTempId: Int? = nil
    /// v9：公告只读 sheet 显隐（对齐 H5 announcement-popup.vue，MVP 只读；房主/房管编辑权限 F 期补）
    @State private var showAnnouncement: Bool = false
    // F 期房主管理批（2026-07-17）房主编辑通告态
    @State private var isEditingAnnouncement: Bool = false
    @State private var announcementDraft: String = ""
    @State private var isSavingAnnouncement: Bool = false
    /// H5 用户端同款站内邀请面板。
    @State private var showShareInviteSheet: Bool = false
    /// 顶部活动 Banner 点击后的应用内网页承载，不触发 PartyRoomView 生命周期。
    @State private var activeCornerBannerURL: PartyCornerBannerPresentation?
    /// 中奖公屏 Join 的活动半屏页；保持 Party 房 RTC/NIM 会话不断开。
    @State private var winnerActivityPage: H5Page?
    /// Party 半屏游戏承载。由右下角游戏 Banner 唯一触发，避免轮播页各自挂 sheet。
    @State private var activePartyGame: PartyGamePresentation?
    /// v9：更多菜单 action sheet 显隐（对齐 H5 more-tool-popup.vue Minimize/Exit）
    @State private var showMoreActions: Bool = false
    // v16（2026-07-14）：关注态改从 `store.isFollowingAnchor` 读，进房时 room/enter 接口的
    // `isFollowOwner` 字段初始化；本地 @State 已删除以避免"退出重进显示未关注"的状态漂移。
    /// v12：底部工具栏 message 按钮 → 复用 Live 侧 ConversationSheetContent 半屏消息列表
    @State private var showMessageSheet: Bool = false
    /// 名片卡 Message → 半屏私聊；挂在 PartyRoomView 顶层避免与房间内其他 sheet 竞争。
    @State private var chatSheetPeerYxAccid: String? = nil
    /// 底部工具栏 Tools 面板（对齐 H5 party-tool-menu.vue）。
    @State private var showToolMenu: Bool = false
    /// Tools 面板关闭后要呈现的下一个界面；由 sheet 的 onDismiss 消费，避免 dismiss/present 同帧竞争。
    @State private var pendingToolMenuPresentation: ToolMenuPresentation?
    /// H5 music-mini-widget：房主/房管点击打开音乐管理，普通用户只切换本端收听。
    @State private var showMusicSheet: Bool = false
    /// 幸运数字配置页由 Tools 面板关闭后延迟拉起，规避 iOS 双 sheet 切换 race。
    @State private var showLuckyNumberSettings: Bool = false
    @StateObject private var luckyNumberStore = PartyLuckyNumberStore()
    /// v12：消息未读徽章（对齐 [swiftui-keepalive-publisher-isolation] 复用 Live 侧 bridge pattern）
    @StateObject private var unreadBridge = MessageEntryUnreadBridge()
    /// P2-10：sortedSeats 缓存
    @State private var sortedSeatsCache: [PartyRoomSeat] = []
    /// 聊天区当前筛选（All / Chat / Gift；过滤逻辑在 PartyMessageListView 内集中处理）。
    @State private var chatFilter: PartyRoomChatFilter = .all
    /// v15：他人麦位 tap → UserCardPopup 显示（对齐 H5 openUserCard；nil = 不显示）
    @State private var userCardForUserId: String? = nil
    /// 麦位点击时已有的用户资料；目标切换或关闭时通过 userId 对齐，避免旧资料串到新名片卡。
    @State private var userCardPreview: UserCardPreview? = nil
    /// v15：已在 A 麦位点 B 空位 → 切麦确认（对齐 H5 EnterSwitchPopup；nil = 不显示）
    @State private var switchSeatPendingTarget: PartyRoomSeat? = nil
    /// v15：房主/房管点空位 → 弹管理动作 dialog（Take/Lock/Unlock；对齐 H5 my-mic-tool.vue 简化版）
    @State private var adminSeatActionsTarget: PartyRoomSeat? = nil
    /// H5 `seat-invite-recommend-popup`：从空麦位菜单拉起的在线用户上麦邀请列表。
    @State private var seatInvitePresentation: PartySeatInvitePresentation? = nil
    /// H-5：礼物面板 sheet 显隐（点底部礼物 icon 触发；对齐 H5 party-gift-popup.vue showPartyGiftPopup）
    @State private var showGiftPanel: Bool = false
    /// 普通礼物与背包共用的收礼人选择；关闭完整礼物架后按 H5 的新建面板语义重置。
    @StateObject private var giftRecipientSelection = GiftRecipientSelectionState()
    /// 从用户名片卡进入礼物架时锁定的单个收礼人（对齐 H5 `giftPopupRecipient`）。
    @State private var giftRecipientOverride: ReceiverItem? = nil
    /// Party 背包从普通礼物面板内层拉起；关闭后仍保留普通礼物面板和当前收礼人选择。
    @State private var showPartyBackpack: Bool = false
    /// H-5：送礼成功 toast（sheet 内触发；主 body overlay 显示避免被 sheet 遮挡）
    @State private var giftSentToast: String? = nil
    /// F 里程碑（2026-07-17）：表情面板 sheet 显隐（对齐 H5 party-expression-popup.vue showEmojiPopup）
    @State private var showExpressionPanel: Bool = false
    /// 对齐安卓 §3.2 `showMicApplicationListDialog(seatIndex)`：观众 tap 空位后待申请的 seatIndex；
    /// Sheet 内观众视角 CTA "申请上麦"点击时消费此值调 applyMic；nil 表示无待申请
    @State private var pendingApplySeatIndex: Int? = nil
    /// 对齐安卓 SeatRosterDialog(isAgreeOnSeatMode=true)：房主 tap Approve 时暂存申请人上下文，
    /// PartyApproveSeatPickerSheet 消费该字段列空位供房主挑选 seatIndex（避免自动挑首空位）
    @State private var approveSeatPickerCandidate: PartyMicApplication? = nil
    /// Sheet 过渡中标志：Approve 走"关列表 sheet → 350ms → 开选座 sheet"过渡（规避 iOS 16 双 sheet race），
    /// 中间的 activeRoomTool=nil 不应触发 onChange 清 candidate；过渡完成后立即置回 false 让手动 swipe dismiss 能正常清
    @State private var isSheetTransitioning: Bool = false

    // MARK: - F-1a PartyBattle 状态（Task 21-22, 2026-07-17）

    /// PartyBattle 状态机（对齐 spec §6.2 布局叠加；sheet 触发由 handlePkTap 分流）
    @ObservedObject private var battleStore = PartyBattleStore.shared
    /// 房主 PK 发起弹窗 sheet 显隐
    @State private var showBattleInitiate: Bool = false
    /// 房主 PK 强制结束确认 sheet 显隐
    @State private var showBattleForceEnd: Bool = false
    /// 冷却期点 PK 提示 toast 显隐（自清 2s）
    @State private var showBattleCooldownToast: Bool = false
    /// PK 规则弹窗 sheet 显隐
    @State private var showBattleRules: Bool = false
    /// PK RUNNING 期礼物面板红蓝 Tab 当前选中 team（1=红 2=蓝；对齐 H5 giftPanelTabs.vue）
    @State private var battleGiftTeam: Int = 1
    /// 安卓 Party 周任务：P2P 1022/1023 进度与奖励的房内展示。
    @ObservedObject private var weeklyTaskStore = PartyWeeklyTaskStore.shared
    /// H5 Super Winner 1150-1156 的房内转盘状态机。
    @ObservedObject private var superWheelStore = PartySuperWheelStore.shared
    @State private var showWeeklyTaskSheet = false
    @ObservedObject private var hotTaskStore = PartyHotRoomTaskStore.shared
    @State private var showHotTaskSheet = false
    /// 热门任务 sheet 的 dismiss 动画完成前，Super Winner 保持待展示，避免同一容器并发 present。
    @State private var isHotTaskSheetPresentationActive = false

    /// 顶栏 Rank / Viewers sheet enum-driven state（对齐 H5 room-rank.vue，同一 sheet 3 mode 切换；
    /// nil = 不显示。左侧财富数 tap → .contribution、荣耀数 tap → .honor、观众数 tap → .viewers）
    @State private var activeRankSheet: PartyRoomRankMode? = nil

    private enum ToolMenuPresentation {
        case pk
        case superWheel
        case luckyNumberSettings
    }

    // MARK: - 顶层 body

    var body: some View {
        sceneBody
            .giftEffectScene(.party, scopeId: store.roomInfo?.id ?? roomId)
            // v23（2026-07-13）派对房进场特效：与 giftEffectScene 并列驱动 EnterEffectCenter
            // scopeId 同源用 roomInfo?.id（与 PartyStore.didReceiveEnterAnimation 内 EnterEffectCenter.enqueue 的 scopeId 强对齐）
            .enterEffectScene(.party, scopeId: store.roomInfo?.id ?? roomId)
            .chatDetailBottomSheet(
                peer: $chatSheetPeerYxAccid,
                selfYxAccId: SessionStore.shared.user?.yxAccid ?? ""
            )
            // v16.14：不再挂 .ignoresSafeArea(.keyboard) —— 换新架构：
            // inputBar 从 contentColumn VStack 拆出到 stageContent ZStack 作独立 sibling（alignment: .bottom），
            // contentColumn 挂 .ignoresSafeArea(.keyboard) 阻止避让。SwiftUI 默认避让只作用于 inputBar 层，
            // 自动上移到键盘顶部 0 空隙（Workflow 3 agent 一致诊断结论）。
    }

    /// 拆两层规避 SwiftUI type-check timeout（[swiftui-body-type-check-timeout] rule）：
    /// body 已含 modifier + 嵌套 ZStack，直接挂 alert/toolbar/onAppear 编译器负载过高。
    private var sceneBody: some View {
        sceneBodyWithTaskSheets
    }

    private var sceneBodyWithRoomSheets: some View {
        stageContentWithFooterOverlays
            // 隐藏 nav bar：Party 房是全屏视觉铺满自定义顶栏，无系统 nav bar。
            // 保留 navigationBarBackButtonHidden 副作用禁 interactive pop（对齐 [default-swipe-back-on-push-pages] 业务态防误退例外）。
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                settingsSheet.giftPanelSheetBackground()
                    .presentationDetents([.fraction(0.5), .fraction(0.8)])
            }
            .sheet(isPresented: $showAnnouncement) {
                announcementSheet
                    .giftPanelSheetBackground()
                    .presentationDetents([.fraction(0.5), .fraction(0.8)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showMusicSheet) {
                PartyMusicManagementSheet(store: store)
                    .giftPanelSheetBackground()
                    .presentationDetents([.fraction(0.75), .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showShareInviteSheet) { shareInviteSheet.giftPanelSheetBackground() }
            .sheet(item: $activeCornerBannerURL) { presentation in
                PartyActivitySafariView(url: presentation.url)
                    .ignoresSafeArea()
                    .presentationDetents([.fraction(0.5), .fraction(0.8)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $winnerActivityPage) { page in
                H5WebSheetView(page: page, onAction: handleWinnerActivityAction)
                    .presentationDetents([.fraction(0.5)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $activePartyGame) { presentation in
                PartyHalfScreenGameSheet(presentation: presentation)
                    .presentationDetents([.height(presentation.preferredHeight)])
                    .presentationDragIndicator(.visible)
            }
            // v8.1 房间工具 sheet（单一挂点，enum 切换 tools / settings 内嵌 push）
            .sheet(item: $activeRoomTool) { kind in
                if kind == .roomMode {
                    roomToolContent(kind: kind)
                        .giftPanelSheetBackground()
                } else {
                    roomToolContent(kind: kind)
                        .giftPanelSheetBackground()
                        .presentationDetents([.fraction(0.5), .fraction(0.8)])
                }
            }
            // P1-7：sheet dismiss（用户 swipe 关 / closure 关都会走）清 pending seatIndex，
            // 避免下次打开 sheet 仍带上次 pending（可能已被别人坐了）
            // ⚠️ Approve 走"nil → 350ms → .approveSeatPicker"过渡，中间的 nil 不应清 candidate（否则 picker 打开时 candidate=nil 自动关）
            .onChange(of: activeRoomTool) { newValue in
                if newValue == nil, !isSheetTransitioning {
                    pendingApplySeatIndex = nil
                    approveSeatPickerCandidate = nil
                }
            }
            // P1-6：开关关闭时若 sheet 仍开着 → 关 sheet + 清 pending（观众不应用旧 pending 触发新 applyMic）
            .onChange(of: store.micApplicationSwitchOn) { on in
                if !on {
                    pendingApplySeatIndex = nil
                    if activeRoomTool == .micApplicationList {
                        activeRoomTool = nil
                    }
                }
            }
            // H-5：底部礼物 icon → CommonGiftPanel sheet（对齐 H5 party-gift-popup.vue）
            .sheet(isPresented: $showGiftPanel) { giftPanelSheet }
            // 顶栏 Rank / Viewers sheet（对齐 H5 room-rank.vue 单 sheet 3 mode 切换）
            .sheet(item: $activeRankSheet) { mode in
                PartyRoomRankSheet(
                    initialMode: mode,
                    roomId: store.roomInfo?.id ?? roomId,
                    onUserTap: { userId in
                        // 先由榜单 sheet dismiss，再打开名片卡，避免 iOS 16 同时呈现两个 sheet。
                        userCardForUserId = userId
                    }
                )
                .presentationDetents([.fraction(0.5), .fraction(0.8)])
            }
            // F 里程碑（2026-07-17）表情面板 sheet 挂载；高度由 PartyExpressionPanel 按当前内容计算。
            .sheet(isPresented: $showExpressionPanel) {
                PartyExpressionPanel()
                    .giftPanelSheetBackground()
            }
    }

    private var sceneBodyWithToastsAndLifecycle: some View {
        sceneBodyWithRoomSheets
            // H-5：送礼成功 toast（sheet 内触发，主 body overlay 避免被 sheet 遮挡）
            .overlay(alignment: .top) {
                if let t = giftSentToast {
                    Text(t)
                        .toastStyle()
                        .transition(Toast.transition)
                        .task(id: t) {
                            try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                            giftSentToast = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: giftSentToast == nil)
            .overlay(alignment: .top) {
                if let t = roomActionToast {
                    Text(t)
                        .toastStyle()
                        .transition(Toast.transition)
                        .task(id: t) {
                            try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                            roomActionToast = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: roomActionToast == nil)
            .confirmationDialog(L10n.PartyRoom.moreMenuTitle, isPresented: $showMoreActions, titleVisibility: .visible) {
                moreActionsButtons
            }
            .onAppear(perform: handleAppear)
            .onChange(of: store.seatList, perform: handleSeatListChange)
            .onChange(of: store.isLocalCameraActive) { _ in
                hotTaskStore.reevaluateFaceCheck()
            }
            .onChange(of: store.effectiveSelfCameraEnabled) { _ in
                hotTaskStore.reevaluateFaceCheck()
            }
            .onChange(of: showGiftPanel) { isPresented in
                guard !isPresented else { return }
                showPartyBackpack = false
                giftRecipientOverride = nil
                giftRecipientSelection.reset()
            }
            .onChange(of: store.roomState) { state in
                switch state {
                case .entering, .joined:
                    startTaskTrackingIfNeeded()
                case .ended:
                    stopTaskTracking()
                    // 被踢或收到 1009 关闭/限制通知后，退房已由 Store 完成；房间页也必须回到列表。
                    // H5 同样在这两类通知后立即离开房间，而不是留在失效的房间 UI。
                    if case .some(.kicked) = store.lastError {
                        AppToastCenter.shared.show(L10n.Party.errorKicked)
                        dismiss()
                    }
                default:
                    break
                }
            }
            .onDisappear(perform: handleDisappear)
    }

    private var sceneBodyWithAlerts: some View {
        sceneBodyWithToastsAndLifecycle
            .overlay {
                if let requirement = store.mediaPermissionAlertRequirement {
                    MediaPermissionDialog(
                        requirement: requirement,
                        onCancel: { store.mediaPermissionAlertRequirement = nil },
                        onConfirm: {
                            Task { await store.retryMediaPermissionFromAlert(requirement) }
                        }
                    )
                }
            }
            .alert(L10n.Party.inviteTitle, isPresented: invitePresented) {
                inviteAlertButtons
            } message: {
                inviteAlertMessage
            }
            .task(id: store.pendingVideoSeatInvite?.inviteId) {
                await runVideoSeatInviteCountdown()
            }
            .alert(L10n.Party.alertTitle, isPresented: $showError) {
                Button(L10n.Party.ok) { store.clearLastError() }
            } message: {
                Text(store.lastError?.errorDescription ?? "")
            }
            .alert(
                L10n.Party.alertTitle,
                isPresented: Binding(
                    get: { store.partyAuditWarningMessage != nil },
                    set: { if !$0 { store.clearPartyAuditWarning() } }
                )
            ) {
                Button(L10n.Party.ok) { store.clearPartyAuditWarning() }
            } message: {
                Text(store.partyAuditWarningMessage ?? "")
            }
            .onChange(of: store.lastError?.errorDescription ?? "", perform: handleLastErrorChange)
            .onChange(of: store.lastInviteResult, perform: handleVideoSeatInviteResult)
    }

    private var sceneBodyWithInteractions: some View {
        sceneBodyWithAlerts
            .confirmationDialog(L10n.Party.selfActionsTitle, isPresented: $showSelfActions) {
                selfActionsButtons
            }
            // v15:他人麦位 tap → UserCardPopup(sheet 化,对齐 H5 openUserCard)
            // 派对房主播端 tap 头像不跳 UserProfile(对齐 H5 主播端 route.path === '/liveSetting' 分支)
            // onSendGiftTap:关闭名片卡 + 拉起礼物面板(对齐 H5 partyStore.showPartyGiftPopup = true)
            // partyAdminContext:派对房 owner/admin 场景下嵌 admin action row
            .userCardSheet(
                item: Binding(
                    get: {
                        userCardForUserId.map {
                            UserCardPresentation(
                                userId: $0,
                                preview: userCardPreview?.userId == $0 ? userCardPreview : nil
                            )
                        }
                    },
                    set: {
                        userCardForUserId = $0?.userId
                        if $0 == nil { userCardPreview = nil }
                    }
                ),
                onMessageTap: { _, yxAccid in
                    guard let yxAccid, !yxAccid.isEmpty else { return }
                    // 对齐 H5 直播名片的 openTalkPopup：关闭名片，再由顶层挂载半屏私聊。
                    userCardForUserId = nil
                    userCardPreview = nil
                    DispatchQueue.main.async {
                        chatSheetPeerYxAccid = yxAccid
                    }
                },
                isPartyRoom: true,
                onSendGiftTap: { info in
                    let seatMatch = store.seatList.first {
                        $0.yxAccid == info.yxAccid || $0.userId == info.userId
                    }
                    guard let yxAccid = info.yxAccid ?? seatMatch?.yxAccid,
                          !yxAccid.isEmpty,
                          yxAccid != "0" else {
                        return
                    }
                    giftRecipientOverride = ReceiverItem(
                        id: yxAccid,
                        avatarURL: (info.avatarUrl ?? seatMatch?.avatar).flatMap(URL.init(string:)),
                        seatIndex: seatMatch?.seatIndex
                    )
                    giftRecipientSelection.replace(with: [yxAccid])
                    // 先关名片卡再拉礼物面板;延迟 0.3s 避免同帧 dismiss+present 冲突(系统 sheet)
                    userCardForUserId = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showGiftPanel = true
                    }
                },
                partyAdminContext: partyAdminContextForCard
            )
            // 头像 tap 内置分派：party 房中 → 弹名片卡（走 userCardForUserId binding）
            .avatarUserCardPresenter { uid in
                userCardPreview = nil
                userCardForUserId = uid
            }
            // v15：已在麦位点空位 → 切麦确认（对齐 H5 EnterSwitchPopup）
            .confirmationDialog(
                L10n.PartyRoom.switchSeatTitle,
                isPresented: switchSeatDialogPresented,
                titleVisibility: .visible
            ) {
                switchSeatDialogButtons
            }
            // v15：房主/房管点空位 → 管理动作 dialog（Take / Lock / Unlock）
            .confirmationDialog(
                L10n.PartyRoom.adminSeatActionsTitle,
                isPresented: adminSeatActionsPresented,
                titleVisibility: .visible
            ) {
                adminSeatActionsButtons
            }
            .sheet(item: $seatInvitePresentation) { presentation in
                PartySeatInviteSheet(store: store, seat: presentation.seat)
                    .giftPanelSheetBackground()
            }
            // v16.10：TapGesture 让点击外部区域收起键盘（对齐 LiveRoomView L459）。
            // TapGesture 与 Button/DragGesture 不同类别，不会挡住 seat/toolbar 按钮点击。
            .simultaneousGesture(
                TapGesture().onEnded {
                    if isInputFocused { isInputFocused = false }
                }
            )
            // v16.11：键盘 notification 订阅，同步 keyboardHeight 让 inputBar 上移
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                withAnimation(.easeOut(duration: duration)) {
                    keyboardHeight = frame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                withAnimation(.easeOut(duration: duration)) {
                    keyboardHeight = 0
                }
            }
    }

    private var sceneBodyWithTaskSheets: some View {
        sceneBodyWithInteractions
            // F-1a Task 22：PartyBattle UI 挂载点（避免 sceneBody 复杂度爆炸抽独立 modifier）
            .modifier(PartyBattleUIModifier(
                battleStore: battleStore,
                effectiveRoomId: store.roomInfo?.id ?? roomId,
                showInitiate: $showBattleInitiate,
                showForceEnd: $showBattleForceEnd,
                showCooldownToast: $showBattleCooldownToast,
                showRules: $showBattleRules
            ))
            .modifier(PartyWeeklyTaskUIModifier(
                weeklyStore: weeklyTaskStore,
                hotStore: hotTaskStore,
                isWeeklyTaskPresented: $showWeeklyTaskSheet,
                isHotTaskPresented: hotTaskSheetPresented,
                onHotTaskDismiss: { isHotTaskSheetPresentationActive = false },
                roomId: store.roomInfo?.id ?? roomId
            ))
            .overlay {
                if let guide = hotTaskStore.guide {
                    PartyTopRoomBonusDialog(
                        kind: .outOfTop,
                        guide: guide,
                        topRankLimit: hotTaskStore.topRankLimit,
                        onDismiss: hotTaskStore.dismissGuide,
                        onConfirm: { switchToHotRoom(guide) }
                    )
                }
            }
            .partyLuckyNumberWinOverlay(store: store)
            .overlay {
                if let notification = hotTaskStore.pendingReward {
                    PartyHotTaskRewardOverlay(notification: notification) {
                        hotTaskStore.dismissReward(notification.id)
                    }
                }
            }
            .preferredColorScheme(.dark)
    }

    // MARK: - 全屏 stage

    private var stageContent: some View {
        ZStack {
            backgroundLayer
            contentColumn
            // H5 Party 专属静态礼物效果：中央缩放、收礼麦位缩放和最多三条送礼飘屏。
            PartyGiftEffectOverlay()
            PartyEnterFloatingOverlay(message: store.enterFloatingMessage)
            FirstGiftFloat(queue: store.firstGiftFloatQueue)
            partyPluginStack
            // v8：进房 loading overlay（对齐 H5 clickRoomItem 全屏 isSearchLoading 反馈）
            // 显示条件：preparing / entering 态；joined 或 ended 时消失让房内 UI 显现
            if store.roomState == .preparing || store.roomState == .entering {
                enterLoadingOverlay
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    /// 右下角插件队列：私 call → 活动 Banner → 游戏 Banner → 音乐小组件。
    /// 所有项目处于同一纵向容器，统一向下、向右对齐，且各项目不可见时不产生占位。
    /// 底部随输入栏/键盘整体上移。
    private var partyPluginStack: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !store.partyPrivateCallHiddenForPK {
                PartyRoomPrivateCallButton(
                    isOn: privateCallOn,
                    selectedGiftIcon: store.partyCallGiftIcon,
                    selectedGiftPrice: store.partyCallGiftPrice,
                    isLoading: store.isTogglingPrivateCall,
                    onToggle: handlePartyCallToggle,
                    onTapGift: handlePartyCallGiftReselect
                )
                // 容器基础间距为 8pt；私 call 与 Banner 单独对齐为 10pt。
                .padding(.bottom, hasDisplayablePartyBanner ? 2 : 0)
            }
            if hasDisplayablePartyBanner, let banners = store.roomInfo?.bannerList {
                PartyRoomBannerCarousel(banners: banners, onTap: handlePartyBannerTap)
            }
            // 半屏游戏暂不接入，隐藏房内游戏 Banner 入口。
            if superWheelStore.isActive {
                PartySuperWheelFloatingButton {
                    superWheelStore.isPanelPresented = true
                }
            }
            PartyMusicMiniWidget(
                settings: store.roomMusicSettings,
                isAudible: store.isRoomMusicAudible,
                onTap: {
                    if store.selfRole == .owner || store.selfRole == .admin {
                        showMusicSheet = true
                    } else {
                        store.toggleRoomMusicAudible()
                    }
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, Theme.Metric.partyRoomScreenH)
        .padding(.bottom, partyPluginBottomInset)
    }

    private var hasDisplayablePartyBanner: Bool {
        store.roomInfo?.bannerList?.contains(where: \.isDisplayable) == true
    }

    private var hasVisibleQuickPhrases: Bool {
        !areQuickPhrasesDismissed && !quickPhrases.isEmpty
    }

    /// 常规输入栏上方保留 16pt；快捷词条增加 42pt 高度后上移 36pt，保留 10pt 间距。
    private var partyPluginBottomInset: CGFloat {
        88 + keyboardHeight + (hasVisibleQuickPhrases ? 36 : 0)
    }

    /// 进房 loading：半透黑底 + ProgressView + 文案（对齐 PartySearchView loadingOverlay 模式）
    private var enterLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text(L10n.Party.enteringRoom)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .transition(.opacity)
    }

    /// 背景层：房主自定义大图（bigImgUrl 优先）→ H5 DEFAULT_BG 兜底 → partyRoomBg asset placeholder。
    ///
    /// **v17 移除静态降级**：直接把 bigImgUrl 按 URL 后缀分流给三种渲染器（image/mp4/svga），
    /// 与 H5 `room-bg.vue` `bgType` 逻辑一致；`imgUrl` 缩略图退化为**动态资源加载中的 placeholder**
    /// 覆盖层，就绪后透明度过渡消失（对齐 H5 `showPlaceholder` + `<Transition name="bg-placeholder">`）。
    ///
    /// **v16.3 真根因修复保留**：静态图路径下 CachedAsyncImage 需显式 `.frame + .clipped()` 约束到屏幕大小。
    /// **v16.7 保留**：UIScreen.main.bounds 锁定物理屏幕尺寸不受键盘避让影响。
    private var backgroundLayer: some View {
        let bg = store.currentRoomBackground
        let bigURL = firstNonEmpty(bg?.bigImgUrl, store.roomInfo?.bigImgUrl)
        let placeholderURL = firstNonEmpty(bg?.imgUrl, store.roomInfo?.bgImgUrl)
        let screenSize = UIScreen.main.bounds.size
        return ZStack {
            // PK 不替换房主配置的舞台背景，等待和进行中均沿用房间背景。
            PartyRoomBackgroundView(
                bigImgURL: bigURL,
                placeholderURL: placeholderURL,
                size: screenSize
            )
            .ignoresSafeArea()

            Theme.Palette.partyRoomOverlay
                .frame(width: screenSize.width, height: screenSize.height)
                .ignoresSafeArea()
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }

    private func firstNonEmpty(_ a: String?, _ b: String?) -> String? {
        if let a, !a.isEmpty { return a }
        if let b, !b.isEmpty { return b }
        return nil
    }

    /// 内容层（v16.11 版本）
    private var contentColumn: some View {
        VStack(spacing: 0) {
            anchorBar
                // v3：上内边距再 +6pt（8 → 16 → 22），与 status bar/dynamic island 更宽松呼吸位
                .padding(.top, 22)
            if isBattleActive {
                pkActiveContent
            } else {
                bigSeatRow
                smallSeatGrid
                    .padding(.top, 12)
            }
            chatArea
            Spacer(minLength: 0)
            inputBar
        }
        // v16.11：contentColumn 层阻止 SwiftUI 默认键盘避让
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// PK 的渐变底色需连续覆盖比分、视频位、麦位与 Top3，而非只停在顶部 HUD。
    private var pkActiveContent: some View {
        VStack(spacing: 0) {
            pkBattleHeader
                .padding(.horizontal, 8)
            bigSeatRow
            smallSeatGrid
                .padding(.top, 8)
        }
        .padding(.bottom, 8)
        .background(pkBattleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var pkBattleBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.66, green: 0.0, blue: 0.42),
                Color(red: 0.46, green: 0.08, blue: 0.43),
                Color(red: 0.0, green: 0.35, blue: 0.50),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - 顶部主播条

    private var anchorBar: some View {
        PartyRoomAnchorBar(
            roomName: store.roomInfo?.roomName ?? L10n.Party.defaultRoomName,
            roomId: store.roomInfo?.id ?? roomId,
            anchorAvatarURL: store.roomInfo?.roomAvatar,
            // v12：头像装饰框 URL（async 从 apiPartyGetUser 拉；对齐 H5 head-frame.vue）
            headFrameURL: store.ownerHeadFrameURL,
            wealthText: PartyNumberFormat.compact(store.roomInfo?.contributionCostNumInt ?? 0),
            honorText: PartyNumberFormat.compact(store.roomInfo?.honorDailyTotalInt ?? 0),
            audienceCountText: "\(chat.onlineCount)",
            showsViewerEntry: chat.onlineCount > 0,
            cornerBanner: store.roomInfo?.cornerBannerList?.first,
            isFollowing: store.isFollowingAnchor,
            // 用 isSelfRoomOwner（ownerId==myUserId）而非 selfRole == .owner：
            // 平台超管在他人房 selfRole 已被提权为 .owner（管理权限用），但**关注按钮显隐**
            // 属"是否房主本人"身份判定 —— 超管应能像普通用户一样关注房主
            isSelfRoom: store.isSelfRoomOwner,
            // v7.4.1 用户明示修正：房主本人 + admin 都可见"设置入口"；仅观众不显示
            // （Bug 1a 已修 selfRole 优先 selfSeat.roomRoleType 派生 → admin 权限实时生效）
            canManage: store.selfRole == .owner || store.selfRole == .admin,
            // 与 H5/安卓主播端保持同一门控：管理员 + Battle Team 房型 + 后台总开关开启。
            canStartPk: battleStore.canManage
                && battleStore.isFunctionEnabled
                && store.roomInfo?.roomTempIdInt == 1,
            onFollowTap: handleFollowTap,
            onAnchorTap: handleAnchorTap,
            onCornerBannerTap: handleCornerBannerTap,
            onPkTap: handlePkTap,
            onAnnouncementTap: handleAnnouncementTap,
            onShareTap: handleShareTap,
            onManagementTap: handleManagementTap,
            onMoreTap: handleMoreTap,
            onRankTap: handleRankTap,
            onViewerTap: handleViewerTap,
            // 入口直接由 room/enter.rewardQuantity 控制，避免异步 tracking 时序让入口短暂或永久缺失。
            showWeeklyTask: (store.roomInfo?.rewardQuantity ?? 0) > 0,
            weeklyTaskRewardQuantity: max(0, store.roomInfo?.rewardQuantity ?? weeklyTaskStore.rewardQuantity),
            onWeeklyTaskTap: {
                startTaskTrackingIfNeeded()
                showWeeklyTaskSheet = true
            },
            showHotTask: hotTaskStore.showsEntry,
            hotTaskStatus: hotTaskStore.status,
            hotTaskTopRankLimit: hotTaskStore.topRankLimit,
            onHotTaskTap: {
                if hotTaskStore.status?.isActive == true {
                    Task { await hotTaskStore.loadMissionRules() }
                    presentHotTaskSheet()
                }
            },
            // 对齐安卓 tvMicApplicationNum：queueSeatNum>0 时管理按钮显示红角标（房主/房管专属）
            managementBadge: store.queueSeatNum
        )
    }

    /// F-1a Task 21：PK 入口点击（对齐 spec §6.2 · 三分支）
    /// - RUNNING 期 → 强制结束确认
    /// - COOLDOWN 期 → 提示 toast
    /// - 其他（idle / ended） → **前置强开排麦** + 发起弹窗（对齐 H5 g-agora-party.vue :400-416 `ensureApplyOnAndOpenPk`）
    ///
    /// H5 强约束：发起 PK 前若排麦关闭，主动开启（后端 PK 依赖排麦通道）；开启失败直接终止不进 PK
    private func handlePkTap() {
        // 入口和实际动作共用相同的权限、房型和后台开关校验，避免隐藏入口仍可由旧事件触发。
        guard battleStore.canManage,
              battleStore.isFunctionEnabled,
              store.roomInfo?.roomTempIdInt == 1 else {
            AppLogger.party.warning("[PartyRoom] pk tapped but permission/template/switch gate rejected")
            return
        }
        if battleStore.isRunning {
            showBattleForceEnd = true
        } else if battleStore.isCoolingDown {
            showBattleCooldownToast = true
        } else {
            // H5 :400-414 `ensureApplyOnAndOpenPk`：发起 PK 前强开排麦
            if !store.micApplicationSwitchOn {
                Task {
                    await store.toggleMicApplicationSwitch(enable: true)
                    // 等 1021 广播回来 micApplicationSwitchOn=true 才进 PK popup（避免开启失败仍进 popup）
                    if store.micApplicationSwitchOn {
                        await MainActor.run { showBattleInitiate = true }
                    }
                }
            } else {
                showBattleInitiate = true
            }
        }
    }

    private func handleRankTap(_ kind: PartyRankKind) {
        // 对齐 H5 header-wrap.vue: wealthRank tap → showRankPopupType='rank' / honorRank tap → 'honor'
        switch kind {
        case .wealth: activeRankSheet = .contribution
        case .honor: activeRankSheet = .honor
        }
    }

    // MARK: - 大麦位（按模板动态：0/1/2/3/6+ 视频位）

    /// v12（对齐 H5 蓝本 livechat-h5/src/components/party/components/main-wrap.vue）：
    /// - `1`：外层 `.video-wrap h-180` 全宽容器（小屏 <380pt 高 156pt），内层视频 cell `w-186` 居中
    /// - `6`：`.video-wrap-6 grid grid-cols-3 gap-1 px-1`，每 cell `aspect-[6/5]`
    /// - `2/3/其他`：v11 沿用 HStack 均分屏宽，每 cell 9/16 竖屏
    /// - `0`：整行隐藏（纯语聊模板）
    @ViewBuilder
    private var bigSeatRow: some View {
        if battleStore.isSelecting, !bigSeats.isEmpty {
            PkSelectingVideoTripleView(
                bigSeats: bigSeats,
                battleStore: battleStore,
                isSelf: isSelf,
                isLocalCameraActive: store.isLocalCameraActive,
                camera: store.camera,
                engine: store.rtc,
                onSeatTap: handleSeatTap
            )
        } else if bigSeats.count == 1 {
            singleBigSeat(bigSeats[0])
        } else if bigSeats.count == 6 {
            sixBigSeatGrid
        } else if !bigSeats.isEmpty {
            multiBigSeatRow
        }
    }

    /// v12：1 视频位模板 —— 对齐 H5 `.video-wrap h-180` 容器 + `w-186` 内层视频 cell 居中
    /// 小屏 (<380pt) 高降为 156pt（对齐 H5 `@media (max-width: 380px)`）
    private func singleBigSeat(_ seat: PartyRoomSeat) -> some View {
        let baseHeight: CGFloat = UIScreen.main.bounds.width < 380 ? 156 : 180
        let containerHeight = isBattleActive ? baseHeight - 40 : baseHeight
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            PartyRoomBigSeatCell(
                seat: seat,
                isSelf: isSelf(seat),
                isLocalCameraActive: store.isLocalCameraActive,
                camera: store.camera,
                engine: store.rtc,
                aspectRatio: nil
            )
            .frame(width: 186)
            // 单视频位：index=0/total=1 → H5 pkVideoSlotTeamClass 返回 'pk-team-red'
            .partyBattleVideoSeatRing(index: 0, total: 1)
                .onTapGesture { handleSeatTap(seat) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: containerHeight)
    }

    /// v12：6 视频位模板 —— 3 列 × 2 行 grid（对齐 H5 `grid grid-cols-3 gap-1 px-1` + `aspect-[6/5]`）
    /// v12：6 视频位模板 —— 3 列 × 2 行 grid（对齐 H5 `grid grid-cols-3 gap-1 px-1` + `aspect-[6/5]`）
    /// **固定 height**：aspectRatio(.fit) 两维 flex 会被父 VStack 因键盘 padding 挤压 → 视频位缩小；
    /// 显式挂 `.frame(height:)` 让 seat 脱离 flex，键盘弹起时不受影响。
    private var sixBigSeatGrid: some View {
        let total = bigSeats.count
        return LazyVGrid(columns: sixBigSeatColumns, spacing: 2) {
            ForEach(Array(bigSeats.enumerated()), id: \.element.stableId) { idx, seat in
                PartyRoomBigSeatCell(
                    seat: seat,
                    isSelf: isSelf(seat),
                    isLocalCameraActive: store.isLocalCameraActive,
                    camera: store.camera,
                    engine: store.rtc,
                    aspectRatio: 6.0 / 5.0
                )
                // 视频位按 index 判定色边（对齐 H5 pkVideoSlotTeamClass：首位红 / 末位蓝）
                .partyBattleVideoSeatRing(index: idx, total: total)
                .clipShape(RoundedRectangle(
                    cornerRadius: isBattleActive ? 8 : 0,
                    style: .continuous
                ))
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: sixBigSeatGridHeight)
    }

    private var sixBigSeatColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    /// 6 视频位模板固定高度：cellW = (屏宽 - 2*4 hPadding - 2*2 colSpacing) / 3，cellH = cellW * 5/6，总高 = 2 行 + 1 rowSpacing
    private var sixBigSeatGridHeight: CGFloat {
        let screenW = UIScreen.main.bounds.width
        let cellW = (screenW - 12) / 3   // 12 = 2*4 padding + 2*2 col spacing
        let cellH = cellW * 5.0 / 6.0
        let baseHeight = cellH * 2 + 2   // 2 行 + 1 行 spacing
        return isBattleActive ? max(0, baseHeight - 40) : baseHeight
    }

    /// 对齐 H5 `main-wrap.vue`：2/3/其他视频位共用 `video-wrap h-180`，横向均分。
    /// 视频内容自身使用 `.hidden`/`.aspectFill` 铺满这个固定容器并从中心裁切。
    private var multiBigSeatRow: some View {
        let total = bigSeats.count
        return HStack(spacing: multiBigSeatGap) {
            ForEach(Array(bigSeats.enumerated()), id: \.element.stableId) { idx, seat in
                PartyRoomBigSeatCell(
                    seat: seat,
                    isSelf: isSelf(seat),
                    isLocalCameraActive: store.isLocalCameraActive,
                    camera: store.camera,
                    engine: store.rtc,
                    aspectRatio: multiBigSeatAspectRatio
                )
                // 视频位按 index 判定色边（对齐 H5 pkVideoSlotTeamClass：首位红 / 末位蓝 / 中间无色）
                .partyBattleVideoSeatRing(index: idx, total: total)
                .clipShape(RoundedRectangle(
                    cornerRadius: isBattleActive ? 8 : 0,
                    style: .continuous
                ))
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, multiBigSeatHorizontalInset)
        .frame(height: multiBigSeatRowHeight)
        // v9：已按 seat.seatType 分组（video→大位，voice→小位）—— 对齐 H5 main-wrap.vue
    }

    /// H5 `video-wrap` uses a fixed 180pt row (156pt on narrow screens),
    /// so the video content can crop within a stable container instead of
    /// changing the room layout based on screen width.
    private var multiBigSeatRowHeight: CGFloat {
        let baseHeight: CGFloat = UIScreen.main.bounds.width < 380 ? 156 : 180
        return isBattleActive ? baseHeight - 40 : baseHeight
    }

    /// 以实际容器宽高计算 cell 比例，避免 `.aspectRatio(.fit)` 改变 H5 的固定行高。
    private var multiBigSeatAspectRatio: CGFloat {
        let n = CGFloat(max(bigSeats.count, 1))
        let gap = multiBigSeatGap
        let horizontalPadding = multiBigSeatHorizontalInset * 2
        let cellW = (UIScreen.main.bounds.width - horizontalPadding - gap * (n - 1)) / n
        return cellW / multiBigSeatRowHeight
    }

    /// H5 adds 16pt horizontal inset below 380pt; PK uses 12pt on regular screens.
    private var multiBigSeatHorizontalInset: CGFloat {
        if UIScreen.main.bounds.width < 380 { return 16 }
        return isBattleActive ? 12 : 0
    }

    /// H5 PK RUNNING `pk-triple` 使用 4pt gap；非 PK 视频位不留间距。
    private var multiBigSeatGap: CGFloat {
        isBattleActive ? 4 : Theme.Metric.partyRoomBigSeatGap
    }

    /// v9：按 seatType 分组（对齐 H5 main-wrap.vue slice(0, videoMicNum)）
    private var bigSeats: [PartyRoomSeat] {
        sortedSeatsCache.filter { $0.seatType == PartyRoomSeatType.video.rawValue }
    }

    // MARK: - 小麦位（按模板动态布局，v17 对齐 H5 main-wrap.vue 三分支）

    /// v17（对齐 H5 main-wrap.vue L326-349）：小麦位按 audioMicNum + 有无视频位分 3 布局分支
    /// - `smallSeats.count == 30 && bigSeats.isEmpty` → 6 列 5 行 grid + sm 变体（H5 L326）
    /// - `smallSeats.count <= 8 && bigSeats.isEmpty` → 前 n-4 + 后 4 底行分组（H5 L338）
    /// - 默认（≥10 或有视频位）→ 3/5 列 flex-wrap（对齐 H5 L332 flex-wrap w-68）
    @ViewBuilder
    private var smallSeatGrid: some View {
        // H5 在 SELECTING/RUNNING 时无条件挂载 PkTeamBoxes 和底部 Top3。
        // 不能受音频麦数量或视频位数量限制，否则部分 Battle Team 房型根本不会显示贡献头像。
        if isBattleActive {
            pkBattleArea
        } else if !smallSeats.isEmpty {
            Group {
                if smallSeats.count == 30 && bigSeats.isEmpty {
                    smallSeatGrid30
                } else if smallSeats.count <= 8 && bigSeats.isEmpty {
                    smallSeatSplitLayout
                } else {
                    smallSeatDefaultGrid
                }
            }
        }
    }

    /// PK 期 5+5 麦位盒布局（对齐 H5 pk-team-boxes.vue）
    ///
    /// 数据来源：`PartyBattleSeatLayout.buildTeamSlots` 从 `store.seatList` 派生红蓝各 5 slot
    /// 点击：所有 slot 走 `handleSeatTap` 原逻辑（跟非 PK 期一致，包括空槽走 joinOrOutMic）
    private var pkTeamBoxesLayout: some View {
        let redSlots = PartyBattleSeatLayout.buildTeamSlots(team: .red, seatList: store.seatList)
        let blueSlots = PartyBattleSeatLayout.buildTeamSlots(team: .blue, seatList: store.seatList)
        return PkTeamBoxesView(
            redSlots: redSlots,
            blueSlots: blueSlots,
            onSeatTap: { seatIndex in
                if let seat = store.seatList.first(where: { $0.seatIndex == seatIndex }) {
                    handleSeatTap(seat)
                }
            }
        )
    }

    /// PK 阶段的视频位下方内容：战队盒及发起/Top3 条。
    /// 比分卡由 `pkBattleHeader` 固定放置在视频位上方，和设计稿层级一致。
    @ViewBuilder
    private var pkBattleArea: some View {
        VStack(spacing: 0) {
            pkTeamBoxesLayout

            if battleStore.isSelecting {
                PartyBattleSelectingStartStrip(store: battleStore)
                    .padding(.top, 8)
            } else {
                PartyBattleHostBottomMarquee(store: battleStore)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        }
    }

    /// PK 等待/进行中共用设计稿比分卡，固定高度 77pt 并置于视频位前。
    private var pkBattleHeader: some View {
        PartyBattleRunningHud(store: battleStore, appearance: .selecting) {
            showBattleRules = true
        }
        .frame(height: 77)
    }

    private var isBattleActive: Bool {
        battleStore.isSelecting || battleStore.isRunning
    }

    /// v17（对齐 H5 `@media (max-width: 380px)` 音频位缩小）：小屏统一 sm 变体（35pt 头像 vs 46pt 默认）
    private var isSmallScreen: Bool {
        UIScreen.main.bounds.width < 380
    }

    /// v17：小麦位默认布局（≥10 麦位 或 有视频位）—— 现有 3/5 列 grid 保留 + sizeVariant 小屏自适应
    private var smallSeatDefaultGrid: some View {
        let variant: PartyRoomSmallSeatCell.SizeVariant = isSmallScreen ? .sm : .default
        return LazyVGrid(columns: smallSeatColumns, spacing: isSmallScreen ? 8 : 14) {
            ForEach(smallSeats, id: \.stableId) { seat in
                PartyRoomSmallSeatCell(
                    seat: seat,
                    isSelf: isSelf(seat),
                    isSpeaking: store.isSpeaking(seat: seat),
                    isVoicePrintActive: store.isVoicePrintActive(seat: seat),
                    sizeVariant: variant
                )
                .partyBattleSeatRing(seat: seat)
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, Theme.Metric.partyRoomScreenH)
    }

    /// v17：30 麦位纯语聊模板 —— 6 列 × 5 行 grid（对齐 H5 L326 `grid-cols-6 mx-2`）
    /// - 无视频位强制走 sm 变体（H5 `<AudioWrap size="sm">`）
    private var smallSeatGrid30: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 6)
        return LazyVGrid(columns: cols, spacing: 2) {
            ForEach(smallSeats, id: \.stableId) { seat in
                PartyRoomSmallSeatCell(
                    seat: seat,
                    isSelf: isSelf(seat),
                    isSpeaking: store.isSpeaking(seat: seat),
                    isVoicePrintActive: store.isVoicePrintActive(seat: seat),
                    sizeVariant: .sm
                )
                .partyBattleSeatRing(seat: seat)
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, 8)
    }

    /// v17：≤8 麦位纯语聊模板 —— 前 n-4 + 后 4 底行分组（对齐 H5 L338-349）
    /// - topCount < 4 → 上排居中；topCount = 4 → 上排 justify-between
    /// - 底排 4 个恒 justify-around（用 `.frame(maxWidth: .infinity)` 均分模拟）
    /// - 每 cell 固定宽 68pt（H5 `w-68`）
    private var smallSeatSplitLayout: some View {
        let n = smallSeats.count
        let topCount = max(n - 4, 0)
        let topSeats = Array(smallSeats.prefix(topCount))
        let bottomSeats = Array(smallSeats.suffix(min(4, n)))
        let variant: PartyRoomSmallSeatCell.SizeVariant = isSmallScreen ? .sm : .default
        let cellW: CGFloat = isSmallScreen ? 56 : 68
        return VStack(spacing: isSmallScreen ? 4 : 8) {
            if !topSeats.isEmpty {
                if topCount < 4 {
                    HStack(spacing: 20) {
                        ForEach(topSeats, id: \.stableId) { seat in
                            splitLayoutCell(seat, variant: variant, cellW: cellW)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(topSeats.enumerated()), id: \.element.stableId) { idx, seat in
                            splitLayoutCell(seat, variant: variant, cellW: cellW)
                            if idx < topSeats.count - 1 { Spacer() }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(spacing: 0) {
                ForEach(bottomSeats, id: \.stableId) { seat in
                    splitLayoutCell(seat, variant: variant, cellW: cellW)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func splitLayoutCell(_ seat: PartyRoomSeat,
                                 variant: PartyRoomSmallSeatCell.SizeVariant,
                                 cellW: CGFloat) -> some View {
        PartyRoomSmallSeatCell(
            seat: seat,
            isSelf: isSelf(seat),
            isSpeaking: store.isSpeaking(seat: seat),
            isVoicePrintActive: store.isVoicePrintActive(seat: seat),
            sizeVariant: variant
        )
        .frame(width: cellW)
        .partyBattleSeatRing(seat: seat)
                .onTapGesture { handleSeatTap(seat) }
    }

    /// v11：列数按模板 smallSeats.count 自适应，避免 5 列固定在 3/6/9 麦模板下右侧留空。
    /// - ≤9 位（3/6/9 麦模板）：3 列（更方阵，行数 1/2/3）
    /// - ≥10 位（10/15/20 麦模板）：5 列（行数 2/3/4）
    private var smallSeatColumns: [GridItem] {
        let count = smallSeats.count <= 9 ? 3 : 5
        return Array(repeating: GridItem(.flexible(),
                                         spacing: Theme.Metric.partyRoomSmallSeatGap),
                     count: count)
    }

    /// v9：按 seatType 分组（对齐 H5 main-wrap.vue）；seatType==2 (voice) → 小位
    private var smallSeats: [PartyRoomSeat] {
        sortedSeatsCache.filter { $0.seatType == PartyRoomSeatType.voice.rawValue }
    }

    // MARK: - 聊天区

    private var chatArea: some View {
        PartyRoomChatArea(
            filter: $chatFilter,
            welcomeMessage: store.roomInfo?.greetingMessage ?? L10n.PartyRoom.welcomeFallback,
            chat: store.chat,
            lastGiftEvent: store.lastGiftEvent,
            canDeleteTextMessages: store.selfRole == .owner || store.selfRole == .admin,
            onDeleteTextMessage: { message in
                await store.deletePartyMessage(message)
            },
            onWinnerActivity: openWinnerActivity
        )
        .padding(.top, 6)
    }

    // MARK: - F-spec 派对房私 call

    /// 派生态：从 `store.roomInfo.partyPrivateCallOpen` 单向流动；PK 状态由 PartyStore
    /// 先快照并关闭，结束后恢复，避免页面重建或小窗状态造成开关漂移。
    private var privateCallOn: Bool {
        store.roomInfo?.isPartyPrivateCallEnabled == true
    }

    /// 浮动按钮 tap handler（v5-需求 1：已有 giftId 复用不重选）：
    /// - 关 → 开：若 `roomInfo.partyCallGiftId` 已有 → 直接 API set enable=1 复用礼物（无需弹 sheet）
    ///           若无 → 拉起 `CommonGiftPanel.callGate` 让房主选礼物；confirm 后才 API set enable=1
    /// - 开 → 关：直接 `PartyStore.setPrivateCall(enable: false)`（视觉切换由 store 回写驱动）
    private func handlePartyCallToggle(_ next: Bool) {
        guard !store.partyPrivateCallHiddenForPK else { return }
        if next {
            if let existingGiftId = store.roomInfo?.partyCallGiftId, !existingGiftId.isEmpty {
                Task { await store.setPrivateCall(enable: true, giftId: existingGiftId) }
            } else {
                Task { @MainActor in
                    activeRoomTool = nil
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    activeRoomTool = .privateCall
                }
            }
        } else {
            Task { await store.setPrivateCall(enable: false, giftId: nil) }
        }
    }

    /// tap 按钮上的礼物 icon —— 无论开关状态都可以重选礼物（弹 gift panel）
    /// 复用与 `handlePartyCallToggle` 开启态相同的 sheet；confirm 后走 setPrivateCall(enable: true) 更新礼物
    private func handlePartyCallGiftReselect() {
        guard !store.partyPrivateCallHiddenForPK else { return }
        Task { @MainActor in
            activeRoomTool = nil
            try? await Task.sleep(nanoseconds: 200_000_000)
            activeRoomTool = .privateCall
        }
    }

    // MARK: - 底部输入 + 工具栏

    private var inputBar: some View {
        PartyRoomInputBar(
            text: $inputText,
            micOn: currentMicOn,
            // v12：emoji + mic 均以 isOnSeat 为门槛（完全对齐 H5 v-if=inPartyRole>-1）
            isOnSeat: store.selfSeat != nil,
            // v9：游戏按钮主播端不显示（对齐 H5 v-if=hasGameCenter，APP_USER_ROLE=2 主播端恒 false）
            showGameButton: false,
            // v12：消息未读徽章（对齐 H5 useUnreadMessageCount + van-badge）
            unreadCount: unreadBridge.totalUnread,
            // 对齐安卓 §1 checkMicApplicationVisible：房主/房管 + 排麦开关开时显示快捷入口
            showMicApplicationButton: (store.selfRole == .owner || store.selfRole == .admin) && store.micApplicationSwitchOn,
            // 排麦队列红角标（对齐安卓 tvMicApplicationNum）
            micApplicationBadge: store.queueSeatNum,
            quickPhrases: quickPhrases,
            showsQuickPhrases: hasVisibleQuickPhrases,
            // v16.10：focus 桥（focused 时收起右侧按钮，对齐 LiveRoomView pattern）
            focus: $isInputFocused,
            onSubmit: sendText,
            onEmojiTap: handleEmojiTap,
            onMessageTap: handleMessageTap,
            onMicTap: handleMicTap,
            onGameTap: handleGameTap,
            onToolMenuTap: handleToolMenuTap,
            onGiftTap: handleGiftTap,
            // 排麦快捷入口 tap：直接开 Mic Application sheet（绕过 Tools sheet）
            onMicApplicationTap: {
                activeRoomTool = .micApplicationList
            },
            onQuickPhraseTap: sendQuickPhrase,
            onQuickPhrasesClose: { areQuickPhrasesDismissed = true }
        )
        // v2：下内边距 20pt 让按钮行距 home indicator 更宽松呼吸位
        .padding(.bottom, 20)
        .background(
            Rectangle().fill(Color.black.opacity(0.15))
                .ignoresSafeArea(edges: .bottom)
        )
        // v16.11：键盘弹起时手动上移到键盘顶（配合 contentColumn `.ignoresSafeArea(.keyboard)` 使用）。
        // 背景层已用 UIScreen.main.bounds 绝对锁定（v16.7），padding 触发的 layout 重算不影响背景视觉。
        .padding(.bottom, keyboardHeight)
    }

    private var currentMicOn: Bool {
        guard let me = store.selfSeat else { return false }
        return (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
    }

    // MARK: - 视频邀请 alert

    private var invitePresented: Binding<Bool> {
        Binding(
            get: { store.pendingVideoSeatInvite != nil },
            set: { if !$0 { store.clearPendingVideoSeatInvite() } }
        )
    }

    @ViewBuilder private var inviteAlertButtons: some View {
        Button(L10n.Party.inviteAccept) { Task { await store.acceptVideoSeatInvite() } }
        Button(L10n.Party.inviteReject, role: .cancel) { Task { await store.rejectVideoSeatInvite() } }
    }

    @ViewBuilder private var inviteAlertMessage: some View {
        if let i = store.pendingVideoSeatInvite {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: L10n.Party.inviteMessageFormat,
                            i.fromNickname ?? L10n.Party.defaultUser,
                            i.seatIndex))
                Text(String(format: L10n.Party.inviteExpiresFormat, videoInviteRemainingSeconds))
            }
        }
    }

    @MainActor
    private func runVideoSeatInviteCountdown() async {
        guard let invite = store.pendingVideoSeatInvite else { return }
        videoInviteRemainingSeconds = invite.ttlSeconds
        while videoInviteRemainingSeconds > 0, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard store.pendingVideoSeatInvite?.inviteId == invite.inviteId else { return }
            videoInviteRemainingSeconds -= 1
        }
        guard !Task.isCancelled,
              store.pendingVideoSeatInvite?.inviteId == invite.inviteId else { return }
        await store.timeoutVideoSeatInvite()
    }

    private func handleVideoSeatInviteResult(_ result: PartyVideoSeatInviteResult?) {
        guard let result else { return }
        switch result.kind {
        case .rejected:
            roomActionToast = L10n.Party.videoSeatInviteRejected
        case .timeout:
            roomActionToast = L10n.Party.videoSeatInviteTimeout
        case .leave:
            roomActionToast = L10n.Party.videoSeatInviteLeave
        case .occupied:
            roomActionToast = L10n.Party.videoSeatInviteOccupied
        case .alreadyOn:
            roomActionToast = L10n.Party.videoSeatInviteAlreadyOn
        case .joinFailed:
            roomActionToast = L10n.Party.videoSeatInviteJoinFailed
        case .accepted, .broadcast:
            break
        }
        store.clearLastInviteResult()
    }

    // MARK: - 自己麦位 sheet

    @ViewBuilder private var selfActionsButtons: some View {
        if let me = store.selfSeat {
            let micOn = (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
            if me.isVideoSeat {
                // 视频位不提供禁麦；历史脏数据需要走管理员解禁接口，而不是 updateMedia。
                if me.isSeatMicrophoneProhibited,
                   (store.selfRole == .owner || store.selfRole == .admin),
                   let seatIndex = me.seatIndex {
                    Button(L10n.userCardPartyUnmute) {
                        Task { await store.requestProhibitSeat(seatIndex: seatIndex, mute: false) }
                    }
                } else if me.isUserMicrophoneMuted {
                    Button(L10n.Party.selfMicOn) {
                        Task { await store.toggleSelfMedia(type: 1, enable: true) }
                    }
                }
            } else {
                Button(micOn ? L10n.Party.selfMicOff : L10n.Party.selfMicOn) {
                    Task { await store.toggleSelfMedia(type: 1, enable: !micOn) }
                }
            }
            if me.seatType == 1 {
                let camOn = (me.cameraEnabled ?? 0) == 1
                Button(camOn ? L10n.Party.selfCamOff : L10n.Party.selfCamOn) {
                    Task { await store.toggleSelfMedia(type: 2, enable: !camOn) }
                }
            }
            Button(L10n.Party.selfLeaveSeat, role: .destructive) {
                Task { await store.requestDownSeat() }
            }
        }
        Button(L10n.Party.cancel, role: .cancel) {}
    }

    // MARK: - Lifecycle 钩子（与原版语义一致）

    private func handleAppear() {
        // 长时间无操作自动离线：派对房中暂停监测（对齐 H5 isBusy 停 timer）
        store.suspendAutoOfflineMonitorIfNeeded()
        // 用户诉求 2026-07-09：进派对房 = 独占摄像头，若匹配中先静默关匹配
        if MatchStore.shared.state == .matching {
            Task { await MatchStore.shared.closeMatch(silent: true) }
        }
        // P2-10：onAppear 同步 cache 一次仅作为"上次会话残留"兜底
        sortedSeatsCache = store.seatList.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }
        // F 里程碑（spec §3.4 P0-2）：挂 CallStore observer 监听 PartyCall 通话结束触发 resumeParty
        // NSHashTable 多观察者数组，与 LiveStore attach 互不干扰
        CallStore.shared.attach(store)
        Task { await loadQuickPhrases() }
        guard !didStartEnter else { return }
        didStartEnter = true
        Task {
            await ensureEntered()
            // `enterRoom` 在 RTC/NIM 双就绪前就返回 .entering；任务接口不依赖该双就绪，
            // 此处同步启动，状态观察器则覆盖后续重连和已就绪路径。
            startTaskTrackingIfNeeded()
        }
    }

    /// 双守卫防误退房：scenePhase != .background + 仅活跃态才 leave
    private func handleDisappear() {
        guard scenePhase != .background else { return }
        // H5 小窗只卸载房间页面，RTC/IM/任务追踪仍必须继续；真正退出才执行下方清理。
        guard !store.isMinimized else { return }
        // F 里程碑：显式 detach（NSHashTable weak 会自动清，但显式调用是最佳实践）
        CallStore.shared.detach(store)
        store.resumeAutoOfflineMonitorIfNeeded()
        if store.roomState == .joined || store.roomState == .entering {
            // leaveRoom 会先读取热门任务的 TopX 状态用于离房埋点，再统一停止各任务追踪。
            Task { await store.leaveRoom() }
        } else {
            stopTaskTracking()
        }
    }

    private func stopTaskTracking() {
        weeklyTaskStore.stopTracking(roomId: store.roomInfo?.id ?? roomId)
        hotTaskStore.stopTracking()
    }

    private func startTaskTrackingIfNeeded() {
        guard store.roomState == .entering || store.roomState == .joined else { return }
        let trackedRoomId = store.roomInfo?.id ?? roomId
        weeklyTaskStore.beginTracking(
            roomId: trackedRoomId,
            rewardQuantity: store.roomInfo?.rewardQuantity ?? 0
        )
        hotTaskStore.beginTracking(roomId: trackedRoomId, entryPath: entryPath)
        AppLogger.party.info("[PartyTask] tracking started state=\(store.roomState.debugDesc, privacy: .public) roomId=\(trackedRoomId, privacy: .public)")
        Task { await weeklyTaskStore.load() }
    }

    private func switchToHotRoom(_ guide: PartyHotRoomGuide) {
        hotTaskStore.dismissGuide()
        let currentRoomId = store.roomInfo?.id ?? roomId
        // 全部热门房暂时无空麦时，服务端仍返回第一名。主播可进入房间等待，不应阻断跳转。
        guard guide.roomId != currentRoomId else { return }
        Task {
            // 路由替换前先结束旧 RTC/IM 会话，避免新房 `enterRoom` 与旧房 leave 并发互相清状态。
            if store.roomState == .joined || store.roomState == .entering {
                await store.leaveRoom()
            }
            onSwitchToHotRoom?(guide.roomId, .topRoomGuide)
        }
    }

    private func handleSeatListChange(_ newList: [PartyRoomSeat]) {
        sortedSeatsCache = newList.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }
        hotTaskStore.reevaluateFaceCheck()
    }

    private func handleLastErrorChange(_ msg: String) {
        showError = !msg.isEmpty
    }

    private func ensureEntered() async {
        if store.roomState == .joined, store.roomInfo?.id == roomId {
            if store.isMinimized {
                store.restoreMinimizedRoom()
            }
            return
        }
        // 从最小化 Party 房切入另一房时，先完成标准退房（退 RTC/NIM/心跳）再进新房，
        // 不走 forceLeave，避免旧房后台会话干扰新房。
        if store.isMinimized {
            await store.leaveMinimizedRoom()
        }
        if store.roomState != .idle, store.roomState != .ended {
            await store.forceLeaveRoom(.userRequest)
        }
        // v8：密码房带 password 参数（对齐 PartyAPI.enterRoom 已有 password 字段）
        await store.enterRoom(roomId: roomId, password: password)
    }

    // MARK: - 麦位点击分流

    private func isSelf(_ seat: PartyRoomSeat) -> Bool {
        guard let me = store.myUserIdString else { return false }
        return seat.userId == me
    }

    /// v15：麦位点击分流（对齐 H5 g-agora-party.vue `joinOrOutMic` 完整语义）。
    ///
    /// 分支优先级（从上到下）：
    /// 1. 自己麦位 → showSelfActions（sheet: mic/cam/leave）
    /// 2. 他人占用麦位 → userCard（弹 UserCardPopup；管理员操作已内嵌 admin row）
    /// 3. **管理员（房主/房管）点空位 → adminSeatActionsTarget（Take/Lock/Unlock dialog）**
    /// 4. 空锁麦位 (lockFlag=1) → toast "The seat is locked"（非管理员）
    /// 5. 空视频位 + 非管理员 → toast "Requires invitation..."（优先于排麦/切麦）
    /// 6. 空语音位 + 已在其他麦位 → switchSeatPendingTarget（切麦确认）
    /// 7. 空语音位 + 未在任何麦位 → 直接 onSeat
    private func handleSeatTap(_ seat: PartyRoomSeat) {
        if isSelf(seat) {
            showSelfActions = true
            return
        }
        if seat.occupied, let uid = seat.userId, !uid.isEmpty {
            // 他人占用位一律走名片卡；管理员操作由 UserCardPopup 内嵌 admin row 承接
            userCardPreview = seat.userCardPreview
            userCardForUserId = uid
            return
        }
        let isManager = store.selfRole == .owner || store.selfRole == .admin
        guard let idx = seat.seatIndex else { return }
        if isManager {
            adminSeatActionsTarget = seat
            return
        }
        if seat.isMCSeat {
            roomActionToast = L10n.Party.mcSeatCannotTake
            return
        }
        if (seat.lockFlag ?? 0) == 1 {
            roomActionToast = L10n.PartyRoom.seatLockedToast
            return
        }
        // H5 `joinOrOutMic` 对普通用户的空视频位直接拦截，不能因排麦开关开启而进入申请流，
        // 也不能由已在其他麦位的状态进入切麦确认。
        if seat.seatType == PartyRoomSeatType.video.rawValue {
            roomActionToast = L10n.PartyRoom.videoSeatNeedsInviteToast
            return
        }
        // 已在麦 → 换麦（视频/语音位均可切）
        if store.selfSeat != nil {
            switchSeatPendingTarget = seat
            return
        }
        // 对齐安卓 §3.2 `showMicApplicationListDialog(seatIndex)`：开关开 + 非特权空位 tap →
        // 打开 Sheet + 保存待申请 seatIndex，等用户在 Sheet 内 tap CTA "申请上麦"才发 API
        // （给用户查看队列 + 主动放弃的完整入口；对齐安卓弹窗内 tvConfirm 手动提交语义）
        if store.micApplicationSwitchOn {
            pendingApplySeatIndex = idx
            Task { @MainActor in
                activeRoomTool = .micApplicationList
            }
            return
        }
        Task { await store.requestOnSeat(seatIndex: idx) }
    }

    // MARK: - v15 UserCard sheet(sheet 化后 helper computed 已删,挂载走 §.userCardSheet 一行 modifier)

    /// 名片卡内嵌 admin action row 上下文 —— 派生自 store 当前态 + 当前查看的 userCardForUserId。
    /// - 我方非 owner/admin → nil(admin row 隐藏)
    /// - 目标是我自己 → nil(不能对自己操作)
    /// - 其他场景返回 PartyAdminContext,UserCardPopup 内 canShowAdminActions 再过滤(目标房主/角色差异等)
    private var partyAdminContextForCard: PartyAdminContext? {
        guard let uid = userCardForUserId else { return nil }
        guard store.selfRole == .owner || store.selfRole == .admin else { return nil }
        if let mineUidInt = SessionStore.shared.user?.userId, uid == String(mineUidInt) { return nil }

        let targetSeat = store.seatList.first { $0.userId == uid }
        let targetRole = store.partyRole(for: uid)
        // 首个空音频位(seatType == voice + isOccupied==0 + lockFlag != 1);目标不在麦时 Take 用此位
        let firstEmptyAudioSeatIndex: Int? = store.seatList
            .first { seat in
                seat.seatType == PartyRoomSeatType.voice.rawValue
                    && (seat.isOccupied ?? 0) == 0
                    && (seat.lockFlag ?? 0) != 1
            }?
            .seatIndex

        return PartyAdminContext(
            selfRole: store.selfRole,
            targetSeat: targetSeat,
            targetRoleType: targetRole,
            roomId: store.roomInfo?.id ?? roomId,
            kickOutHours: store.kickOutHours,
            firstEmptyAudioSeatIndex: firstEmptyAudioSeatIndex,
            onTakeToMic: { targetUserId, seatIndex in
                Task { await store.requestTakeToMic(seatIndex: seatIndex, targetUserId: targetUserId) }
                userCardForUserId = nil
            },
            onKickFromMic: { targetUserId, seatIndex in
                Task { await store.requestKickFromMic(seatIndex: seatIndex, targetUserId: targetUserId) }
                userCardForUserId = nil
            },
            onToggleMute: { seatIndex, mute in
                Task { await store.requestProhibitSeat(seatIndex: seatIndex, mute: mute) }
                // 不关闭 sheet:mute 后等 IM 1008 广播 → seat.seatMicrophoneEnabled 更新
            },
            onSetAdmin: { targetUserId, add in
                Task {
                    guard await store.requestSetAdmin(userId: targetUserId, add: add) else { return }
                    userCardForUserId = nil
                    userCardPreview = nil
                }
            },
            onKickOutRoom: { seatIndex, targetUserId, banType in
                Task { await store.requestKickOutRoom(seatIndex: seatIndex, targetUserId: targetUserId, banType: banType) }
                userCardForUserId = nil
            }
        )
    }

    // MARK: - v15 切麦确认

    private var switchSeatDialogPresented: Binding<Bool> {
        Binding(
            get: { switchSeatPendingTarget != nil },
            set: { if !$0 { switchSeatPendingTarget = nil } }
        )
    }

    @ViewBuilder private var switchSeatDialogButtons: some View {
        Button(L10n.PartyRoom.switchSeatConfirm) {
            guard let target = switchSeatPendingTarget,
                  let idx = target.seatIndex,
                  let type = target.seatType else { return }
            switchSeatPendingTarget = nil
            Task { await store.requestExchangeSeat(targetSeatIndex: idx, targetSeatType: type) }
        }
        Button(L10n.Party.cancel, role: .cancel) { switchSeatPendingTarget = nil }
    }

    // MARK: - v15 房主/房管空位管理

    private var adminSeatActionsPresented: Binding<Bool> {
        Binding(
            get: { adminSeatActionsTarget != nil },
            set: { if !$0 { adminSeatActionsTarget = nil } }
        )
    }

    /// 房主/房管点空位的动作 sheet：
    /// - 未在任何麦位 → Take Seat（视频位管理员可自上，绕过普通用户"需邀请"限制）
    /// - 已在其他麦位 → Switch Here（走切麦）
    /// - Mute/Unmute（仅语音位；服务端广播后空位右下角同步禁麦图标）
    /// - Invite（H5 同款在线推荐用户上麦邀请）
    /// - Lock/Unlock（按 seat.lockFlag 动态切换文案）
    @ViewBuilder private var adminSeatActionsButtons: some View {
        if let seat = adminSeatActionsTarget, let idx = seat.seatIndex {
            let locked = (seat.lockFlag ?? 0) == 1
            let type = seat.seatType ?? PartyRoomSeatType.voice.rawValue
            // Take / Switch 按钮（锁麦位不给 Take 入口，需要先 Unlock）
            if !locked {
                if store.selfSeat == nil {
                    Button(L10n.PartyRoom.adminActionTake) {
                        adminSeatActionsTarget = nil
                        Task { await store.requestOnSeat(seatIndex: idx) }
                    }
                } else {
                    Button(L10n.PartyRoom.adminActionSwitchHere) {
                        adminSeatActionsTarget = nil
                        Task { await store.requestExchangeSeat(targetSeatIndex: idx, targetSeatType: type) }
                    }
                }
            }
            // 视频位只修复历史管理员禁麦脏数据，不提供禁麦；语音位保持正常切换。
            if type == PartyRoomSeatType.video.rawValue, seat.isSeatMicrophoneProhibited {
                Button(L10n.userCardPartyUnmute) {
                    adminSeatActionsTarget = nil
                    Task { await store.requestProhibitSeat(seatIndex: idx, mute: false) }
                }
            } else if type != PartyRoomSeatType.video.rawValue {
                Button(seat.isMicrophoneMuted ? L10n.userCardPartyUnmute : L10n.userCardPartyMute) {
                    adminSeatActionsTarget = nil
                    Task { await store.requestProhibitSeat(seatIndex: idx, mute: !seat.isMicrophoneMuted) }
                }
            }
            Button(L10n.toolInvite) {
                adminSeatActionsTarget = nil
                // 先关闭 confirmation dialog，再打开 sheet，避免 iOS 同帧呈现冲突。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    seatInvitePresentation = PartySeatInvitePresentation(seat: seat)
                }
            }
            // Lock / Unlock
            Button(locked ? L10n.PartyRoom.adminActionUnlock : L10n.PartyRoom.adminActionLock) {
                adminSeatActionsTarget = nil
                Task { await store.requestLockSeat(seatIndex: idx, lock: !locked) }
            }
            // H5 `changeMC`：从空 MC 位的管理菜单打开 MC 设置页，而不是直接改当前位。
            // 当前 iOS 的 MC API 权限与顶部工具入口一致，仅房主/平台超管可配置。
            if seat.isMCSeat, store.selfRole == .owner {
                Button(L10n.Party.mcSeatChange) {
                    adminSeatActionsTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        activeRoomTool = .mcSeat
                    }
                }
            }
        }
        Button(L10n.Party.cancel, role: .cancel) { adminSeatActionsTarget = nil }
    }

    // MARK: - 发送公屏

    /// v16.10：内嵌 TextField 发送（对齐 LiveRoomView L400+ onSend）
    /// 成功后清空 inputText + 主动失焦收起键盘（LiveRoomView L417 `inputText = ""` 后键盘继续保持，Party 也保持同款）
    private func sendText() {
        let txt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !txt.isEmpty, store.roomState == .joined else { return }
        store.chat.sendText(txt)
        inputText = ""
        // 与 H5 一致：用户主动发送普通聊天后收起快捷词条栏。
        areQuickPhrasesDismissed = true
    }

    /// 对齐 H5 `getQuickPhrases(2)`：主播端使用 audienceType=2；接口失败不打断进房。
    private func loadQuickPhrases() async {
        do {
            quickPhrases = try await PartyAPI.quickPhrases(audienceType: 2)
                .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.orderNumber < $1.orderNumber }
            areQuickPhrasesDismissed = false
        } catch {
            quickPhrases = []
            AppLogger.party.warning("[PartyRoom] load quick phrases failed error=\(String(describing: error), privacy: .private)")
        }
    }

    /// 快捷词条不改动当前输入内容或键盘焦点；与 H5 `sendQuickPhrase(..., false)` 相同。
    private func sendQuickPhrase(_ phrase: PartyQuickPhrase) {
        let content = phrase.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, store.roomState == .joined else { return }
        store.chat.sendText(content)
        areQuickPhrasesDismissed = true
    }

    // MARK: - 顶部工具栏 handler

    /// v16：关注/取关房主（对齐 H5 header-wrap.vue userStore.followOrNo）
    /// 走 `store.toggleFollowAnchor()` 统一维护 `isFollowingAnchor`；
    /// **成功 toast 由 [FollowListService.followUser] service 层触发 [AppToastCenter] 全局弹出**，
    /// 本 view 不再本地弹（避免与全局 toast 重复展示）。
    /// 进房关注态由 room/enter 接口 `isFollowOwner` 字段初始化，退出重进保持一致。
    private func handleFollowTap() {
        // 用 isSelfRoomOwner 而非 selfRole == .owner：
        // 平台超管 selfRole 被提权为 .owner，但可关注房主 —— 参见 isSelfRoom 相同逻辑
        guard !store.isSelfRoomOwner else {
            AppLogger.party.notice("[PartyRoom] follow: is owner self; skip")
            return
        }
        Task { @MainActor in
            _ = await store.toggleFollowAnchor()
        }
    }

    /// 顶部房主头像与 H5 `openUserCard(ownerInfo.userId)` 对齐，复用房内既有名片卡承载。
    private func handleAnchorTap() {
        guard let ownerId = store.roomInfo?.ownerId, !ownerId.isEmpty else { return }
        userCardForUserId = ownerId
    }

    /// http(s) 活动在应用内展示；后端若配置自定义 scheme 则交给系统处理。
    private func handleCornerBannerTap(_ banner: PartyCornerBanner) {
        guard let rawURL = banner.directUrl, let url = URL(string: rawURL) else { return }
        presentActivityURL(url)
    }

    /// 右下角轮播 Banner 与顶部活动位使用同一跳转策略。
    private func handlePartyBannerTap(_ banner: PartyRoomBanner) {
        guard let rawURL = banner.directUrl, let url = URL(string: rawURL) else { return }
        presentActivityURL(url)
    }

    private func handlePartyGameTap(_ game: PartyBannerGame) {
        guard activePartyGame == nil, game.isLaunchable,
              let roomId = store.roomInfo?.id, !roomId.isEmpty else { return }
        Task { @MainActor in
            guard let url = await PartyGameURLBuilder.makeURL(game: game, roomId: roomId) else { return }
            activePartyGame = PartyGamePresentation(game: game, url: url)
        }
    }

    private func presentActivityURL(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            activeCornerBannerURL = PartyCornerBannerPresentation(url: url)
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// H5 `winner_broadcast` 在房内打开半屏活动页；活动页关闭后仍停留在原 Party 房。
    @MainActor
    private func openWinnerActivity(_ rawURL: String) {
        guard let url = sanitizedWinnerActivityURL(rawURL),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            AppLogger.party.notice("[PartyWinner] ignored invalid activity URL")
            return
        }
        winnerActivityPage = H5Page(
            url: url,
            bridgeMode: .trusted(H5TrustedOriginPolicy(origins: [url])),
            runtimeContext: .activity()
        )
    }

    private func sanitizedWinnerActivityURL(_ rawURL: String) -> URL? {
        guard let url = URL(string: rawURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems?.removeAll { ["roomId", "roomType", "reportParams"].contains($0.name) }
        return components.url
    }

    @MainActor
    private func handleWinnerActivityAction(_ action: H5BridgeAction) {
        switch action {
        case .goLive, .goRoom, .close:
            winnerActivityPage = nil
        case .goProfile(let userId):
            winnerActivityPage = nil
            if let userId, !userId.isEmpty { userCardForUserId = userId }
        default:
            break
        }
    }

    /// v9：公告只读 sheet（对齐 H5 announcement-popup.vue，MVP 只读）
    /// 房主/房管编辑权限 F 期补（PartyAPI.setAnnouncement 端点 + 编辑态 UI）。
    private func handleAnnouncementTap() {
        showAnnouncement = true
    }

    private func handleShareTap() {
        guard let rid = store.roomInfo?.id, !rid.isEmpty else {
            AppLogger.party.notice("[PartyRoom] share tapped but roomId missing")
            return
        }
        showShareInviteSheet = true
        AppLogger.party.info("[PartyRoom] share tapped roomId=\(rid, privacy: .public)")
    }

    private var shareInviteSheet: some View {
        PartyShareInviteSheet(
            roomId: store.roomInfo?.id ?? roomId,
            recentSessions: MessageSessionStore.shared.sessions(in: .flame)
                + MessageSessionStore.shared.sessions(in: .prime)
                + MessageSessionStore.shared.sessions(in: .stranger),
            onInviteCompleted: { showShareInviteSheet = false }
        )
        .presentationDetents([.fraction(0.5), .fraction(0.8)])
        .presentationDragIndicator(.visible)
    }
    private func handleManagementTap() {
        // v7.4.1：房主 + admin 都能打开 tools sheet（对齐 anchorBar canManage 判定；观众依然拦下）
        // Bug 1a 已修 selfRole 优先从 selfSeat.roomRoleType 派生 → admin 权限实时生效
        if store.selfRole == .owner || store.selfRole == .admin {
            activeRoomTool = .tools
        } else {
            AppLogger.party.notice("[PartyRoom] management tapped by audience; ignored")
        }
    }

    /// v8.1 房间工具 sheet（enum-driven 单 sheet 切换）：
    /// - .tools → PartyRoomToolsSheet（3 列网格）
    /// - .settings → 房主设置编辑页
    /// - .blocklist → 黑名单管理页
    @ViewBuilder
    private func roomToolContent(kind: PartyRoomToolSheetKind) -> some View {
        switch kind {
        case .tools:
            PartyRoomToolsSheet(
                isOwner: store.selfRole == .owner,
                // 平台超管在 selfRole 层已提权为 .owner（PartyStore.selfRole 首判 isPlatformAdmin），此参数保留
                // 为语义冗余安全网 —— MC Seat `if isOwner || isPlatformAdmin` 条件下双重命中
                isPlatformAdmin: store.roomInfo?.isPlatformAdmin ?? false,
                onTapSettings: {
                    // 用 Task.sleep 一帧规避 iOS 16 sheet 切换 race
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .settings
                    }
                },
                onTapBlocklist: {
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .blocklist
                    }
                },
                onTapRoomMode: {
                    // E v2 §1：切 Room Mode 模板 grid sheet
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .roomMode
                    }
                },
                onTapMicApplication: {
                    // H5 room-mana-popup 直接切换排麦开关；申请列表仍由底栏申请入口打开。
                    let willEnable = !store.micApplicationSwitchOn
                    let alreadyConfirmed = willEnable ? store.autoEnterOnApplication : store.autoEnterOffApplication
                    if alreadyConfirmed {
                        Task { await store.toggleMicApplicationSwitch(enable: willEnable) }
                    } else {
                        activeRoomTool = .micApplicationSwitchConfirm
                    }
                },
                isRoomLocked: store.roomInfo?.lockFlag == 1,
                isMicApplicationOn: store.micApplicationSwitchOn,
                isMusicAvailable: store.roomInfo?.isRoomMusicAvailable ?? false,
                isMusicEnabled: store.isRoomMusicEnabled,
                isMCSeatEnabled: store.seatList.contains { $0.isMCSeat },
                onTapMusic: {
                    Task { await store.toggleRoomMusic() }
                },
                onTapLockRoom: {
                    // spec §3.4：已锁态直接调 unlockRoom（无弹窗）；未锁态才弹密码输入 sheet
                    if store.roomInfo?.lockFlag == 1 {
                        Task { @MainActor in
                            activeRoomTool = nil
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await store.unlockRoom()
                        }
                    } else {
                        Task { @MainActor in
                            activeRoomTool = nil
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            activeRoomTool = .lockRoom
                        }
                    }
                },
                onTapMCSeat: {
                    // H5 已开启时在 Tools 内直接关闭；未开启时才进入选座页。
                    if store.seatList.contains(where: { $0.isMCSeat }) {
                        Task { await store.closeMCSeat() }
                    } else {
                        Task { @MainActor in
                            activeRoomTool = nil
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            activeRoomTool = .mcSeat
                        }
                    }
                }
            )
            .presentationDetents([.fraction(0.5), .fraction(0.8)])
        case .settings:
            NavigationStack {
                PartyRoomSettingsView(
                    store: PartyRoomSettingsStore(
                        roomId: store.roomInfo?.id ?? roomId,
                        roomName: store.roomInfo?.roomName ?? "",
                        tagline: store.roomInfo?.greetingMessage ?? "",
                        languageCode: store.roomInfo?.roomLanguage ?? "",
                        avatarUrl: store.roomInfo?.roomAvatar,
                        backgroundId: nil
                    ),
                    onSaved: { snapshot in
                        // v8.2：同步 PartyStore.roomInfo → 顶栏立即刷新
                        store.applyRoomSettingsChanges(
                            roomName: snapshot.roomName,
                            roomAvatar: snapshot.avatarUrl,
                            greetingMessage: snapshot.tagline,
                            roomLanguage: snapshot.languageCode
                        )
                        activeRoomTool = nil
                    }
                )
            }
            .preferredColorScheme(.dark)
        case .blocklist:
            NavigationStack {
                PartyBlocklistSheet(store: store)
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.fraction(0.5), .fraction(0.8)])
        case .roomMode:
            // E v2 §1 + §3 Sheet Mount Hoist：Room Mode 模板 grid → onConfirmRequest 上抛 → 切 .roomModeConfirm
            PartyRoomModeSheet(
                store: store,
                onConfirmRequest: { tempId in
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        pendingRoomModeTempId = tempId
                        activeRoomTool = .roomModeConfirm
                    }
                }
            )
            .preferredColorScheme(.dark)
        case .roomModeConfirm:
            // E v2 §1：二次确认 → onConfirm 调 store.switchRoomMode 完成切模板
            PartyRoomModeConfirmSheet(
                tempId: pendingRoomModeTempId ?? 0,
                tempName: nil,
                onCancel: {
                    activeRoomTool = nil
                    pendingRoomModeTempId = nil
                },
                onConfirm: {
                    guard let t = pendingRoomModeTempId else {
                        activeRoomTool = nil
                        return
                    }
                    Task {
                        let before = store.lastError
                        await store.switchRoomMode(to: t)
                        // spec §4 R4：API 失败 → 弹窗保持 + lastError alert 展示；成功才关
                        let apiFailed = (store.lastError != nil) && (store.lastError?.errorDescription != before?.errorDescription)
                        await MainActor.run {
                            if !apiFailed {
                                activeRoomTool = nil
                                pendingRoomModeTempId = nil
                            }
                        }
                    }
                }
            )
            .presentationDetents([.fraction(0.5), .fraction(0.8)])
        case .micApplicationList:
            NavigationStack {
                PartyMicApplicationSheet(store: store, onTapSwitchToggle: {
                    // 先判 autoEnter*Application flag：首次切换弹协议确认；二次直接调 API
                    let willEnable = !store.micApplicationSwitchOn
                    let alreadyConfirmed = willEnable ? store.autoEnterOnApplication : store.autoEnterOffApplication
                    if alreadyConfirmed {
                        Task { await store.toggleMicApplicationSwitch(enable: willEnable) }
                        return
                    }
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .micApplicationSwitchConfirm
                    }
                }, onDismissAfterCancel: {
                    // 对齐安卓 §3.7 giveUpApplyMic → dismiss 弹窗
                    pendingApplySeatIndex = nil
                    activeRoomTool = nil
                }, pendingApplySeatIndex: pendingApplySeatIndex, onDidSubmitApply: {
                    // 对齐安卓 §3.3 h_applySeat 提交后清 pending，避免重复消费；等 IM 分流后 sheet 内 CTA 变"放弃申请"
                    pendingApplySeatIndex = nil
                }, onTapApprove: { item in
                    // 对齐安卓 SeatRosterDialog(isAgreeOnSeatMode=true)：房主 tap Approve → 弹选座 sheet
                    // 关当前 sheet + 350ms 后打开 approveSeatPicker（规避 iOS 16 双 sheet race）
                    // isSheetTransitioning=true 让中间的 activeRoomTool=nil 不触发 onChange 清 candidate
                    approveSeatPickerCandidate = item
                    isSheetTransitioning = true
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .approveSeatPicker
                        isSheetTransitioning = false
                    }
                })
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.fraction(0.5), .fraction(0.8)])
        case .micApplicationSwitchConfirm:
            // E v2 §2 A4：首次切换 Mic Application 开关的协议确认（confirm 后本地 flag 置 true）
            PartyMicApplicationSwitchConfirmSheet(
                enable: !store.micApplicationSwitchOn,
                onCancel: { activeRoomTool = nil },
                onConfirm: {
                    let willEnable = !store.micApplicationSwitchOn
                    Task {
                        await store.toggleMicApplicationSwitch(enable: willEnable)
                        await MainActor.run {
                            if willEnable {
                                store.autoEnterOnApplication = true
                            } else {
                                store.autoEnterOffApplication = true
                            }
                            activeRoomTool = nil
                        }
                    }
                }
            )
            .presentationDetents([.fraction(0.5), .fraction(0.8)])
        case .approveSeatPicker:
            // 对齐安卓 SeatRosterDialog(isAgreeOnSeatMode=true)：房主挑座 sheet
            // approveSeatPickerCandidate 由上一步 Approve tap 设置；nil 兜底关 sheet
            if let candidate = approveSeatPickerCandidate {
                NavigationStack {
                    PartyApproveSeatPickerSheet(store: store, application: candidate) {
                        approveSeatPickerCandidate = nil
                        activeRoomTool = nil
                    }
                }
                .preferredColorScheme(.dark)
                .presentationDetents([.fraction(0.5), .fraction(0.8)])
            } else {
                // 候选 nil（异常）—— empty view 让用户手动 swipe 关（避免 sheet 卡住）
                Color.clear.onAppear { activeRoomTool = nil }
            }
        case .lockRoom:
            NavigationStack {
                PartyLockRoomSheet(store: store)
            }
            .presentationDetents([.fraction(0.5), .fraction(0.8)])
            .preferredColorScheme(.dark)
        case .mcSeat:
            NavigationStack { PartyMCSeatSheet(store: store) }
                .presentationDetents([.fraction(0.5), .fraction(0.8)])
                .preferredColorScheme(.dark)
        case .privateCall:
            // F-spec §5.1 v5：房主开开关时拉直播设置同款礼物面板（CommonGiftPanel.callGate + 蓝钻）
            // 用户 confirm 选中礼物 → 调 PartyAPI.updatePartyPrivateCall(enable=1, giftId) → 关 sheet
            // 用户 confirm 但 gift=nil → 视为放弃，不 API，仅关 sheet（对齐 callGate "移除" 语义）
            // v5-需求 3：关闭态时 confirm 按钮文案改为 "Open private call" 提示"点确认即开启"
            // v5-需求 4：onConfirm 提取 giftIcon/giftPrice 传给 store 立即更新按钮预览（不等下次 enterRoom 回写）
            CommonGiftPanel(config: .callGate(
                minPrice: 0,
                initialSelection: nil,
                onConfirm: { [store] gift in
                    if let gift {
                        let icon = gift.giftSmallImg.isEmpty ? gift.giftImg : gift.giftSmallImg
                        let price = Int(exactly: gift.giftPrice)
                        Task { @MainActor in
                            await store.setPrivateCall(
                                enable: true,
                                giftId: String(gift.id),
                                giftIcon: icon,
                                giftPrice: price
                            )
                            activeRoomTool = nil
                        }
                    } else {
                        activeRoomTool = nil
                    }
                },
                useBlueDiamond: true,
                confirmLabel: privateCallOn ? nil : L10n.Party.privateCallOpenConfirmLabel
            ))
            .presentationDetents([.fraction(0.5), .fraction(0.8)])
            .preferredColorScheme(.dark)
        }
    }

    /// v8 房主设置 sheet（保留 legacy 路径，v8.1 主入口走 activeRoomTool 单 sheet）
    @ViewBuilder
    private var settingsSheet: some View {
        NavigationStack {
            PartyRoomSettingsView(
                store: PartyRoomSettingsStore(
                    roomId: store.roomInfo?.id ?? roomId,
                    roomName: store.roomInfo?.roomName ?? "",
                    tagline: store.roomInfo?.greetingMessage ?? "",
                    languageCode: store.roomInfo?.roomLanguage ?? "",
                    avatarUrl: store.roomInfo?.roomAvatar,
                    backgroundId: nil
                ),
                onSaved: { snapshot in
                    store.applyRoomSettingsChanges(
                        roomName: snapshot.roomName,
                        roomAvatar: snapshot.avatarUrl,
                        greetingMessage: snapshot.tagline,
                        roomLanguage: snapshot.languageCode
                    )
                    showSettings = false
                }
            )
        }
        .preferredColorScheme(.dark)
    }
    /// v9：更多菜单（对齐 H5 more-tool-popup.vue Minimize + Exit 二选一）
    /// 目前 Minimize（PiP）留 F 期，MVP 只提供 Exit + Cancel。
    private func handleMoreTap() {
        showMoreActions = true
    }

    private func handleHeatTap() {
        // 热度入口显示房间贡献榜（与 H5 room-rank wealthRank 同一数据源）。
        activeRankSheet = .contribution
    }
    private func handleViewerTap() {
        // 对齐 H5 header-wrap.vue: userRank tap → showRankPopupType='onlineUser'（apiGetPartyOnlineList）
        activeRankSheet = .viewers
    }
    /// F 里程碑（2026-07-17）表情面板入口（对齐 H5 party-expression-popup.vue showEmojiPopup=true）。
    /// 上麦门槛已在 `PartyRoomInputBar.emojiButton` `isOnSeat` opacity/hitTest 门控 · 此处触发条件即已上麦。
    private func handleEmojiTap() {
        showExpressionPanel = true
    }
    /// v12：消息按钮（对齐 H5 footer-wrap.vue onClickMsgBtn → partyStore.openPartyMessage()）
    /// A 档接入：复用 Live 侧 ConversationSheetContent 半屏消息列表
    private func handleMessageTap() {
        showMessageSheet = true
    }

    /// H5 `party-tool-menu.vue` 聚合工具面板入口。
    private func handleToolMenuTap() {
        showToolMenu = true
    }

    private var hotTaskSheetPresented: Binding<Bool> {
        Binding(
            get: { showHotTaskSheet },
            set: { isPresented in
                showHotTaskSheet = isPresented
                if isPresented { isHotTaskSheetPresentationActive = true }
            }
        )
    }

    private var superWheelPanelPresented: Binding<Bool> {
        Binding(
            get: { superWheelStore.isPanelPresented && !isHotTaskSheetPresentationActive },
            set: { isPresented in
                if !isPresented { superWheelStore.isPanelPresented = false }
            }
        )
    }

    private func presentHotTaskSheet() {
        isHotTaskSheetPresentationActive = true
        showHotTaskSheet = true
    }

    private func presentPendingToolMenuPresentation() {
        guard let presentation = pendingToolMenuPresentation else { return }
        pendingToolMenuPresentation = nil

        switch presentation {
        case .pk:
            handlePkTap()
        case .superWheel:
            if superWheelStore.isActive {
                superWheelStore.isPanelPresented = true
            } else {
                Task { await superWheelStore.prepareConfig() }
            }
        case .luckyNumberSettings:
            showLuckyNumberSettings = true
        }
    }

    /// 麦按钮：若已在麦，直接切自己 mic；未上麦不响应
    private func handleMicTap() {
        guard let me = store.selfSeat else { return }
        if me.isVideoSeat {
            guard let seatIndex = me.seatIndex else { return }
            if me.isSeatMicrophoneProhibited,
               (store.selfRole == .owner || store.selfRole == .admin) {
                Task { await store.requestProhibitSeat(seatIndex: seatIndex, mute: false) }
            } else if me.isUserMicrophoneMuted {
                Task { await store.toggleSelfMedia(type: 1, enable: true) }
            }
            return
        }
        let micOn = (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
        Task { await store.toggleSelfMedia(type: 1, enable: !micOn) }
    }
    private func handleGameTap() {
        // v9：H5 主播端不显示此按钮（APP_USER_ROLE=2 v-if=hasGameCenter 拦截）；
        // showGameButton: false 已在 inputBar 隐藏。此 handler 保留兜底 log
        // TODO(J 里程碑)：若产品要求主播端也有游戏入口，走 H5 iframe pattern
        AppLogger.party.notice("[PartyRoom] game tapped (should be hidden on anchor-end)")
    }
    /// H-5：底部礼物 icon tap → 拉起礼物面板（对齐 H5 party-gift-popup.vue showPartyGiftPopup=true）。
    /// 面板内首次 `.onAppear` 触发 `PartyGiftDataSource.load` → sapi `getPartyRoomGift` 拉列表。
    private func handleGiftTap() {
        giftRecipientOverride = nil
        giftRecipientSelection.reset()
        showGiftPanel = true
    }

    /// H-5：礼物面板 sheet 内容 —— CommonGiftPanel + `.partySend` 工厂配置。
    /// receivers 由 [PartyGiftPanelBridge.makeReceiversConfig] 从 seatList 派生（过滤空 yxAccid/自己）。
    ///
    /// **主播端无充值功能**：`onRechargeRequested` 用 factory 默认空 closure，
    /// balance 胶囊 tap 走 Footer 内 `store.refreshBalance()`（刷新余额）。
    @ViewBuilder
    private var giftPanelSheet: some View {
        // PK RUNNING 期按当前 tab team 过滤 recipientList（对齐 H5 giftPanelTabs 父级 filter）
        let battlingUids: Set<Int64>? = {
            guard battleStore.isRunning else { return nil }
            let members = battleGiftTeam == 2 ? battleStore.blueMembers : battleStore.redMembers
            return Set(members.map { $0.uid })
        }()
        let receivers = PartyGiftPanelBridge.makeReceiversConfig(
            seatList: store.seatList,
            selfYxAccid: SessionStore.shared.user?.yxAccid,
            battlingUids: battlingUids,
            recipientOverride: giftRecipientOverride,
            selectionState: giftRecipientSelection
        )
        // CommonGiftPanel 将 config 存入 StateObject；切换红蓝队或成员变动时必须重建，
        // 否则收礼人行会继续显示初次打开面板时的队伍。
        let receiverRosterID = receivers.items
            .map { "\($0.id):\($0.seatIndex ?? 0)" }
            .joined(separator: ",")
        let receiverConfigID = "\(battleStore.pkId)-\(battleGiftTeam)-\(battlingUids?.sorted().map { String($0) }.joined(separator: ",") ?? "all")-\(receiverRosterID)"
        let config = CommonGiftPanelConfig.partySend(
            roomId: store.roomInfo?.id ?? roomId,
            receivers: receivers,
            onOpenBackpack: { showPartyBackpack = true },
            onSend: { _, _, _ in
                giftSentToast = L10n.giftPickerSentToast
            }
        )
        VStack(spacing: 0) {
            // PK RUNNING 期顶部挂 Red/Blue Tab（对齐 H5 giftPanelTabs.vue）
            if battleStore.isRunning {
                PartyBattleGiftPanelTabs(team: $battleGiftTeam)
            }
            CommonGiftPanel(config: config)
                .id(receiverConfigID)
        }
        .sheet(isPresented: $showPartyBackpack) {
            PartyBackpackGiftSheet(
                roomId: store.roomInfo?.id ?? roomId,
                receivers: receivers,
                recipientSelection: giftRecipientSelection,
                onSent: {
                    giftSentToast = L10n.giftPickerSentToast
                    showPartyBackpack = false
                    showGiftPanel = false
                }
            )
            .presentationDetents([.fraction(0.55), .large])
            .presentationDragIndicator(.visible)
        }
        // RUNNING 期 tab +54pt → fraction 从 0.4 上调到 0.5 容纳；非 PK 期沿用 0.4
        .presentationDetents(battleStore.isRunning ? [.fraction(0.5)] : [.fraction(0.4)])
        .preferredColorScheme(.dark)
    }

    // MARK: - v9 sheets & action dialogs

    /// 公告 sheet（对齐 H5 announcement-popup.vue）。
    /// F 期房主管理批（2026-07-17）：房主/平台超管可切编辑态修改独立 announcement 字段并 save。
    /// 权限判定：`store.selfRole == .owner`（平台超管已在 selfRole 层提权，见 PartyRoomInfo.selfRoleType）。
    @ViewBuilder
    private var announcementSheet: some View {
        NavigationStack {
            let currentText = store.roomInfo?.announcement ?? ""
            let canEdit = store.selfRole == .owner
            ScrollView {
                if isEditingAnnouncement {
                    // 编辑态：TextEditor + placeholder overlay（对齐 H5 form 输入体感）
                    ZStack(alignment: .topLeading) {
                        if announcementDraft.isEmpty {
                            Text(L10n.PartyRoom.announcementPlaceholder)
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $announcementDraft)
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(minHeight: 160)
                            .disabled(isSavingAnnouncement)
                    }
                } else if currentText.isEmpty {
                    Text(L10n.PartyRoom.announcementEmpty)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Text(currentText)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .navigationTitle(L10n.PartyRoom.announcementTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isEditingAnnouncement {
                    // 编辑态：leading=Cancel / trailing=Save
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(L10n.PartyRoom.announcementCancel) {
                            isEditingAnnouncement = false
                            announcementDraft = currentText
                        }
                        .disabled(isSavingAnnouncement)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if isSavingAnnouncement {
                            ProgressView()
                        } else {
                            Button(L10n.PartyRoom.announcementSave) { performSaveAnnouncement() }
                                .disabled(!canSaveAnnouncement)
                        }
                    }
                } else if canEdit {
                    // 只读态且是房主/超管：显示 Edit / Close
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(L10n.PartyRoom.announcementClose) { showAnnouncement = false }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.PartyRoom.announcementEdit) {
                            announcementDraft = currentText
                            isEditingAnnouncement = true
                        }
                    }
                } else {
                    // 只读态且非房主：只有 Close
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.PartyRoom.announcementClose) { showAnnouncement = false }
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.5), .fraction(0.8)])
        .preferredColorScheme(.dark)
        .onChange(of: showAnnouncement) { newVal in
            // dismiss sheet 时同时退出编辑态，避免下次打开残留 dirty draft
            if !newVal {
                isEditingAnnouncement = false
                announcementDraft = ""
            }
        }
    }

    /// F 期房主管理批：Save 通告。成功 toast + 关编辑态 + 关 sheet；失败 toast 保留编辑态供重试。
    private func performSaveAnnouncement() {
        guard !isSavingAnnouncement, canSaveAnnouncement else { return }
        isSavingAnnouncement = true
        let draft = announcementDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let ok = await store.updateAnnouncement(text: draft)
            isSavingAnnouncement = false
            if ok {
                AppToastCenter.shared.show(L10n.PartyRoom.announcementSaveSuccess)
                isEditingAnnouncement = false
                showAnnouncement = false
            } else {
                AppToastCenter.shared.show(L10n.PartyRoom.announcementSaveFailed)
            }
        }
    }

    private var canSaveAnnouncement: Bool {
        let draft = announcementDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !draft.isEmpty && draft != (store.roomInfo?.announcement ?? "")
    }

    /// 更多菜单 action sheet（对齐 H5 more-tool-popup.vue：Minimize + Exit）
    /// Minimize (PiP) 留 F 期，MVP 只提供 Exit + Cancel。
    @ViewBuilder
    private var moreActionsButtons: some View {
        Button(L10n.Party.moreMenuMinimize) {
            guard store.minimizeRoom() else { return }
            dismiss()
        }
        Button(L10n.PartyRoom.moreMenuLeave, role: .destructive) {
            // 退房逻辑（HTTP + RTC + Chat）后台跑；立即 dismiss 让用户感知不到接口延迟。
            // leaveRoom 内同步转 roomState = .leaving，handleDisappear guard 会拒绝重入，无重复请求。
            Task { await store.leaveRoom() }
            dismiss()
        }
        Button(L10n.Party.cancel, role: .cancel) {}
    }

    // MARK: - 底部工具栏覆盖层（message / toolMenu；v13 已删 apply）

    /// 把新加的 footer overlay 挂在 stageContent 上，让 sceneBody 保持轻量
    /// 避免 modifier chain 累加触发 SwiftUI type-check timeout（rule swiftui-body-type-check-timeout §4）
    private var stageContentWithFooterOverlays: some View {
        stageContent
            .sheet(isPresented: $showMessageSheet) { messageSheetContent.giftPanelSheetBackground() }
            .sheet(isPresented: $showToolMenu, onDismiss: presentPendingToolMenuPresentation) {
                PartyRoomToolMenuSheet(
                    luckyNumberStore: luckyNumberStore,
                    roomId: store.roomInfo?.id ?? roomId,
                    // H5 :show-pk = roomTempId===1 && battleStore.isFunctionEnabled，再由组件按管理员身份门控。
                    showPk: battleStore.canManage
                        && battleStore.isFunctionEnabled
                        && store.roomInfo?.roomTempIdInt == 1,
                    showSuperWheel: store.selfRole == .owner || store.selfRole == .admin,
                    isRoomMuted: store.isRoomMuted,
                    onStartPk: {
                        pendingToolMenuPresentation = .pk
                    },
                    onOpenSuperWheel: {
                        pendingToolMenuPresentation = .superWheel
                    },
                    onToggleRoomMute: {
                        store.toggleRoomMute()
                    },
                    onOpenLuckyNumberSettings: {
                        pendingToolMenuPresentation = .luckyNumberSettings
                    }
                )
                .giftPanelSheetBackground()
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
            }
            .sheet(
                isPresented: $superWheelStore.isConfigPresented,
                onDismiss: superWheelStore.presentQueuedPanelAfterConfigDismissal
            ) {
                PartySuperWheelConfigSheet(
                    wheelStore: superWheelStore,
                    roomId: store.roomInfo?.id ?? roomId
                )
                .giftPanelSheetBackground()
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: superWheelPanelPresented) {
                PartySuperWheelPanel(
                    wheelStore: superWheelStore,
                    // H5 仅真实房主可中途关闭并退款；平台管理员的 Party 管理提权不等同该玩法所有权。
                    isRoomOwner: store.isSelfRoomOwner
                )
                .giftPanelSheetBackground()
                .presentationDetents([.fraction(0.65), .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showLuckyNumberSettings) {
                PartyLuckyNumberSettingsSheet(
                    luckyNumberStore: luckyNumberStore,
                    roomId: store.roomInfo?.id ?? roomId,
                    isRoomOwner: store.isLuckyNumberRoomOwner
                )
                .giftPanelSheetBackground()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }

    /// 消息半屏 sheet（复用 Live 侧 ConversationSheetContent 公共组件）
    /// v13：高度对齐 LiveRoomView.messageSheetContent（fraction 0.55 + drag indicator）
    /// 内层 sheet-over-sheet 私聊 detent 由 ConversationSheetContent 内部 chatSheetDetent 管理，键盘弹起自动切 .large
    @ViewBuilder
    private var messageSheetContent: some View {
        ConversationSheetContent(
            store: .shared,
            selfYxAccId: SessionStore.shared.user?.yxAccid ?? "",
            onClose: { showMessageSheet = false }
        )
        .presentationDetents([.fraction(0.55)])
        .presentationDragIndicator(.visible)
    }

}

// MARK: - PartyEnterFloatingOverlay

/// H5 `high-level-user-join.vue` 的房内进场条。
///
/// 状态和 2 秒串行队列由 `PartyStore` 持有；此视图只负责对应的 0.8s 右入、0.8s 停留、
/// 0.4s 左出关键帧，不会在动画完成时抢先消费下一条。
private struct PartyEnterFloatingOverlay: View {
    let message: PartyEnterFloatingMessage?

    var body: some View {
        GeometryReader { proxy in
            if let message {
                PartyEnterFloatingRow(message: message, travelDistance: proxy.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 15)
                    .offset(y: proxy.size.height * 0.46)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PartyEnterFloatingRow: View {
    let message: PartyEnterFloatingMessage
    let travelDistance: CGFloat

    @State private var horizontalOffset: CGFloat = 0
    @State private var opacity: Double = 0

    var body: some View {
        HStack(spacing: 5) {
            if let level = message.userLevel {
                UserLevelBadge(level: max(0, level), size: .small, showsZero: true)
            }
            if message.isVip {
                VIPBadge(size: .small)
            }
            Text(message.nickname)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: 0x1AFFCD))
                .lineLimit(1)
                .frame(maxWidth: 74, alignment: .leading)
            Text(L10n.publicScreenEnteredRoom)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 212, maxWidth: 244, minHeight: 26, alignment: .leading)
        .background { entryBackground }
        .clipShape(Capsule())
        .offset(x: horizontalOffset)
        .opacity(opacity)
        .task(id: message.id) {
            horizontalOffset = max(0, travelDistance - 44)
            opacity = 0
            await Task.yield()
            guard !Task.isCancelled else { return }

            // H5 `high-level-user-join.vue`: 0.8s 右入、0.8s 停留、0.4s 左出。
            withAnimation(.easeOut(duration: 0.8)) { horizontalOffset = 0 }
            withAnimation(.easeOut(duration: 0.64)) { opacity = 1 }
            do {
                try await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.4)) {
                    horizontalOffset = -travelDistance
                }
            } catch {
                return
            }
        }
    }

    @ViewBuilder
    private var entryBackground: some View {
        if let rawURL = Self.levelBorderURL(for: message.userLevel ?? 0),
           let url = URL(string: rawURL) {
            CachedAsyncImage(url: url, contentMode: .fill, persistent: true) {
                standardEntryBackground
            }
        } else {
            standardEntryBackground
        }
    }

    private var standardEntryBackground: LinearGradient {
        let base: Color
        switch message.userLevel ?? 0 {
        case 2...10: base = Color(hex: 0x5E5ACF)
        case 11...20: base = Color(hex: 0xDE8484)
        case 21...30: base = Color(hex: 0xBF865E)
        case 31...40: base = Color(hex: 0xDD6D9B)
        case 41...45: base = Color(hex: 0xE8629A)
        default: base = Color(hex: 0x5F8FBC)
        }
        return LinearGradient(
            colors: [base, base.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private static func levelBorderURL(for level: Int) -> String? {
        switch level {
        case 46...50: return "https://img.hnhily.link/mstatic/live/level_border_7.webp"
        case 51...55: return "https://img.hnhily.link/mstatic/live/level_border_8.webp"
        case 56...60: return "https://img.hnhily.link/mstatic/live/level_border_9.webp"
        case 61...65: return "https://img.hnhily.link/mstatic/live/level_border_10.webp"
        case 66...: return "https://img.hnhily.link/mstatic/live/level_border_12.webp"
        default: return nil
        }
    }
}

// MARK: - PartyRoomBackgroundView

/// 派对房背景渲染器（v17 对齐 H5 `room-bg.vue` 三分支）。
///
/// **URL 分流**：
/// - 结尾 `.svga` → `RemoteSVGAImageView`（loops=0 无限循环，scaleAspectFill）
/// - 结尾 `.mp4` → `LoopingVideoView`（AVQueuePlayer + AVPlayerLooper，resizeAspectFill，muted）
/// - 其他 → `CachedAsyncImage`（静态图，等比填充 + clipped）
///
/// **动态资源 placeholder 层**：动图/视频加载期间显示 `placeholderURL`（后端 imgUrl 缩略图恒静态），
/// 就绪后 0.3s opacity 渐隐 —— 完全对齐 H5 `<Transition name="bg-placeholder">` 0.3s ease。
/// 视觉效果：先看到静态缩略图 → 动图/视频首帧就绪后平滑淡出让位给动态内容，避免白屏。
///
/// **URL 变更处理**：`.onChange(of: effectiveURL)` reset `dynamicReady` → placeholder 重新覆盖 →
/// 底层 `LoopingVideoView` / `RemoteSVGAImageView` 通过 updateUIView 内部 URL diff 换 asset。
///
/// **失败兜底**：动图/视频加载失败时 `dynamicReady` 保持 false → placeholder 常驻，
/// 用户视觉等同于静态图，符合 H5 fallback 精神。
private struct PartyRoomBackgroundView: View {
    let bigImgURL: String?
    let placeholderURL: String?
    let size: CGSize

    /// H5 `DEFAULT_BG`（`room-bg.vue:17`）。bigImgUrl / placeholderURL 都空时最终兜底。
    private static let defaultBG = "https://img.hnhily.link/mstatic/party/bg_party.png"

    @State private var dynamicReady = false

    private var effectiveURL: String {
        if let s = bigImgURL, !s.isEmpty { return s }
        if let s = placeholderURL, !s.isEmpty { return s }
        return Self.defaultBG
    }

    private var effectivePlaceholder: String {
        if let s = placeholderURL, !s.isEmpty { return s }
        return Self.defaultBG
    }

    var body: some View {
        let url = effectiveURL
        let kind = MediaAssetKind(urlString: url)
        return ZStack {
            mainContent(kind: kind, url: url)

            // 动态资源加载中的静态覆盖（就绪后 0.3s opacity 淡出）
            if kind != .image, !dynamicReady {
                staticImageView(urlStr: effectivePlaceholder)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.3), value: dynamicReady)
        .onAppear {
            AppLogger.party.info("[PartyRoom] bg url=\(url, privacy: .public) kind=\(String(describing: kind), privacy: .public)")
        }
        .onChange(of: url) { _ in
            dynamicReady = false
        }
    }

    @ViewBuilder
    private func mainContent(kind: MediaAssetKind, url: String) -> some View {
        switch kind {
        case .image:
            staticImageView(urlStr: url)
        case .svga:
            RemoteSVGAImageView(
                url: URL(string: url),
                loops: 0,
                contentMode: .scaleAspectFill,
                onFirstPlay: { dynamicReady = true }
            )
            .frame(width: size.width, height: size.height)
            .clipped()
        case .mp4:
            LoopingVideoView(url: URL(string: url)) {
                dynamicReady = true
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func staticImageView(urlStr: String) -> some View {
        CachedAsyncImage(url: URL(string: urlStr), contentMode: .fill, persistent: true) {
            Image("partyRoomBg")
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - PartyShareInviteSheet (H5 user share-list-wrap.vue)

/// H5 用户端同款的站内房间邀请：最近聊天 / 关注 / 粉丝三类联系人可多选，确认后调用 inviteUserRoom。
private struct PartyShareInviteSheet: View {
    enum Tab: Int, CaseIterable, Identifiable {
        case recent, following, followers
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .recent: return L10n.liveRoomSheetMessagesTitle
            case .following: return L10n.profileFollowing
            case .followers: return L10n.profileFollowers
            }
        }
    }

    let roomId: String
    let recentSessions: [MessageSession]
    let onInviteCompleted: () -> Void

    @State private var tab: Tab = .recent
    @State private var remoteRecipients: [Tab: [PartyShareRecipient]] = [:]
    @State private var selectedYxAccids = Set<String>()
    @State private var isLoading = false
    @State private var isInviting = false

    private var recipients: [PartyShareRecipient] {
        switch tab {
        case .recent:
            var seen = Set<String>()
            return recentSessions
                .filter { seen.insert($0.id).inserted }
                .map { PartyShareRecipient(yxAccid: $0.id, userId: nil, nickname: $0.peerNickname, icon: $0.peerAvatarURL) }
        case .following, .followers:
            return remoteRecipients[tab] ?? []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleView
            tabPicker
            recipientList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            inviteButton
        }
        .task { loadRemoteRecipientsIfNeeded() }
    }

    private var titleView: some View {
        Text(L10n.Party.shareInviteTitle)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.top, 16)
            .padding(.bottom, 14)
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .onChange(of: tab) { _ in loadRemoteRecipientsIfNeeded() }
    }

    @ViewBuilder
    private var recipientList: some View {
        if isLoading {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if recipients.isEmpty {
            EmptyStateView(textFont: .subheadline)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(recipients, content: recipientRow)
                }
            }
        }
    }

    private func recipientRow(_ recipient: PartyShareRecipient) -> some View {
        let isSelected = selectedYxAccids.contains(recipient.yxAccid)
        let displayName = recipient.nickname?.isEmpty == false ? recipient.nickname! : L10n.anonymous

        return Button { toggle(recipient.yxAccid) } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: URL(string: recipient.icon ?? ""), contentMode: .fill) {
                    Circle().fill(Color.white.opacity(0.15))
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())

                Text(displayName)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.Palette.partyRoomFollowFill : .white.opacity(0.45))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
    }

    private var inviteButton: some View {
        Button(action: invite) {
            Text(L10n.commonConfirm)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .foregroundStyle(.white)
        .background(selectedYxAccids.isEmpty || isInviting ? Color.white.opacity(0.2) : Theme.Palette.partyRoomFollowFill)
        .clipShape(Capsule())
        .padding(16)
        .disabled(selectedYxAccids.isEmpty || isInviting)
    }

    private func toggle(_ yxAccid: String) {
        if selectedYxAccids.contains(yxAccid) { selectedYxAccids.remove(yxAccid) }
        else { selectedYxAccids.insert(yxAccid) }
    }

    private func loadRemoteRecipientsIfNeeded() {
        guard tab != .recent, remoteRecipients[tab] == nil, !isLoading else { return }
        isLoading = true
        let requestedTab = tab
        Task {
            defer { isLoading = false }
            do {
                remoteRecipients[requestedTab] = try await PartyAPI.shareFollowUsers(
                    followType: requestedTab == .following ? 0 : 1
                )
            } catch {
                AppLogger.party.error("[PartyShare] load recipients failed: \(String(describing: error), privacy: .public)")
                remoteRecipients[requestedTab] = []
            }
        }
    }

    private func invite() {
        guard !selectedYxAccids.isEmpty, !isInviting else { return }
        isInviting = true
        let invitees = Array(selectedYxAccids)
        Task {
            defer { isInviting = false }
            do {
                try await PartyAPI.inviteUsersToRoom(roomId: roomId, yxAccidList: invitees)
                AppToastCenter.shared.show(L10n.Party.shareInviteSent)
                onInviteCompleted()
            } catch {
                AppLogger.party.error("[PartyShare] invite failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// `getFollowInfoList` 的联系人字段；兼容用户端接口的 String/Int userId 混发。
struct PartyShareRecipient: Decodable, Identifiable, Hashable {
    let yxAccid: String
    let userId: String?
    let nickname: String?
    let icon: String?

    var id: String { yxAccid }

    init(yxAccid: String, userId: String?, nickname: String?, icon: String?) {
        self.yxAccid = yxAccid; self.userId = userId; self.nickname = nickname; self.icon = icon
    }

    enum CodingKeys: String, CodingKey { case yxAccid, userId, nickname, nickName, icon, avatar, userAvatar }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        yxAccid = try c.decode(String.self, forKey: .yxAccid)
        if let value = try? c.decode(String.self, forKey: .userId) { userId = value }
        else if let value = try? c.decode(Int64.self, forKey: .userId) { userId = String(value) }
        else { userId = nil }
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? (try? c.decode(String.self, forKey: .nickName))
        icon = (try? c.decode(String.self, forKey: .icon)) ?? (try? c.decode(String.self, forKey: .avatar)) ?? (try? c.decode(String.self, forKey: .userAvatar))
    }
}

/// `SFSafariViewController` 的 SwiftUI 承载；以 sheet 展示，关闭后仍停留在当前 Party 房。
private struct PartyActivitySafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct PartyCornerBannerPresentation: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 半屏游戏展示上下文。游戏页由一个唯一的房间级 sheet 承载，避免轮播中多页重复呈现。
private struct PartyGamePresentation: Identifiable {
    let game: PartyBannerGame
    let url: URL

    var id: String { "\(game.id)_\(url.absoluteString)" }

    /// H5 默认半屏游戏为正方形；`lingxian` 使用 375:530 的高画布。
    var preferredHeight: CGFloat {
        let screen = UIScreen.main.bounds
        let typeFromURL = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { ["gameType", "yomiGameType"].contains($0.name) })?
            .value?
            .lowercased()
        let gameHeight = (typeFromURL ?? game.gameType?.lowercased()) == "lingxian"
            ? screen.width / 375 * 530
            : screen.width
        return min(screen.height * 0.82, gameHeight + 36)
    }
}

/// H5 `homeStore.openGame(item, 'partyBanner')` 的原生 URL 组装。
/// URL 仅在这一处构造，确保所有游戏类型携带同一份 room/path ext，并杜绝 token 写入日志。
@MainActor
private enum PartyGameURLBuilder {
    private static let partyPath = "partyBanner"

    static func makeURL(game: PartyBannerGame, roomId: String) async -> URL? {
        guard !game.gameId.isEmpty,
              let rawLink = game.gameLink, !rawLink.isEmpty else {
            return nil
        }
        let normalized = rawLink
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "%26", with: "&", options: .caseInsensitive)
        let gameType = game.gameType?.lowercased() ?? ""
        let ext = buildExt(gameId: game.gameId, gameSize: "half", roomId: roomId)

        if gameType == "yomi" {
            return await makeYomiURL(
                rawLink: normalized,
                game: game,
                roomId: roomId,
                ext: ext
            )
        }

        guard let session = SessionStore.shared.user,
              let userId = session.userId,
              let imToken = session.imToken, !imToken.isEmpty else {
            AppLogger.party.notice("[PartyGame] launch blocked: missing game session gameId=\(game.gameId, privacy: .public)")
            return nil
        }

        if gameType == "hg" {
            return replacingQueryItems(
                in: normalized,
                values: [
                    "uid": String(userId),
                    "token": imToken,
                    "lang": hotGameLanguage,
                    "gameType": "hg",
                    "ext": ext,
                ]
            )
        }

        return replacingQueryItems(
            in: normalized,
            values: [
                "token": imToken,
                "uid": String(userId),
                "ext": ext,
            ]
        )
    }

    private static func makeYomiURL(
        rawLink: String,
        game: PartyBannerGame,
        roomId: String,
        ext: String
    ) async -> URL? {
        let tokenCode: PartyGameTokenCode?
        do {
            tokenCode = try await PartyAPI.gameTokenCode()
        } catch {
            AppLogger.party.notice("[PartyGame] getTokenCode failed gameId=\(game.gameId, privacy: .public) err=\(String(describing: error), privacy: .private)")
            return validatedWebURL(rawLink)
        }
        guard let tokenCode else {
            AppLogger.party.notice("[PartyGame] getTokenCode empty gameId=\(game.gameId, privacy: .public)")
            return validatedWebURL(rawLink)
        }

        if rawLink.range(of: "(?:^|[?&])version=v4(?:&|$)", options: .regularExpression) != nil {
            guard var components = URLComponents(string: rawLink) else {
                AppLogger.party.notice("[PartyGame] invalid Yomi v4 URL gameId=\(game.gameId, privacy: .public)")
                return nil
            }
            var queryItems = components.queryItems ?? []
            let configuredSize = queryItems
                .first(where: { $0.name.caseInsensitiveCompare("platPayload") == .orderedSame })?
                .value
            queryItems.removeAll {
                $0.name.caseInsensitiveCompare("platPayload") == .orderedSame
            }
            components.queryItems = queryItems
            let v4Ext = buildExt(
                gameId: game.gameId,
                gameSize: configuredSize?.isEmpty == false ? configuredSize! : "half",
                roomId: roomId
            )
            appendQueryItems(
                to: &components,
                values: [
                    "lang": language,
                    "platUserId": tokenCode.userId,
                    "platAuthCode": tokenCode.code,
                    "platPayload": v4Ext,
                ]
            )
            guard let finalURL = components.url else { return nil }
            return validatedWebURL(finalURL)
        }

        let usesPlatPayload = URLComponents(string: rawLink)?.queryItems?
            .contains(where: { $0.name.caseInsensitiveCompare("platPayload") == .orderedSame }) == true
        var values = [
            "gameType": game.gameId,
            "yomiGameType": game.gameType ?? "yomi",
            "code": tokenCode.code,
            "userId": tokenCode.userId,
            "lang": language,
            "roomId": game.appIds ?? "",
            usesPlatPayload ? "platPayload" : "merchantPayload": ext,
        ]
        if let merchant = tokenCode.merchant { values["merchant"] = merchant }
        if let platform = tokenCode.platform { values["platform"] = platform }
        return replacingQueryItems(in: rawLink, values: values)
    }

    private static func buildExt(gameId: String, gameSize: String, roomId: String) -> String {
        "\(gameId)_\(gameSize)__path$\(partyPath)__roomid$\(roomId)"
    }

    private static var language: String {
        AppLocaleStore.shared.effectiveLanguage.rawValue
    }

    private static var hotGameLanguage: String {
        ["en", "ar", "tr"].contains(language) ? language : "en"
    }

    private static func replacingQueryItems(in rawLink: String, values: [String: String]) -> URL? {
        guard var components = URLComponents(string: rawLink) else {
            AppLogger.party.notice("[PartyGame] invalid game URL")
            return nil
        }
        appendQueryItems(to: &components, values: values)
        guard let finalURL = components.url else { return nil }
        return validatedWebURL(finalURL)
    }

    private static func validatedWebURL(_ rawLink: String) -> URL? {
        URL(string: rawLink).flatMap(validatedWebURL)
    }

    private static func validatedWebURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            AppLogger.party.notice("[PartyGame] rejected non-web game URL")
            return nil
        }
        return url
    }

    private static func appendQueryItems(to components: inout URLComponents, values: [String: String]) {
        var items = components.queryItems ?? []
        for (key, value) in values {
            items.removeAll { $0.name.caseInsensitiveCompare(key) == .orderedSame }
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
    }
}

/// H5 的 iframe 半屏游戏原生承载。离开 sheet 时停止加载，防止已关闭游戏继续占用网络与 JS 计时器。
private struct PartyGameWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 游戏链接含本次会话的临时鉴权参数，关闭半屏游戏后不保留第三方 cookie/cache。
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        view.load(URLRequest(url: url))
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
}

private struct PartyHalfScreenGameSheet: View {
    let presentation: PartyGamePresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PartyGameWebView(url: presentation.url)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9), .black.opacity(0.45))
                    .padding(10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.mediaPreviewClose)
        }
        .background(Color.black)
    }
}

/// Party 房背包礼物。普通礼物面板与背包库存使用不同后端域，故由内层 sheet 独立承载；
/// 普通礼物面板保持打开，以符合 H5 在背包和礼物分类间切换时不丢收礼人选择的行为。
private struct PartyBackpackGiftSheet: View {
    let roomId: String
    let receivers: ReceiversConfig
    let onSent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recipientSelection: GiftRecipientSelectionState
    @State private var gifts: [PartyBackpackGift] = []
    @State private var selectedGiftID: String?
    @State private var count = 1
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var isSending = false
    @State private var loadFailed = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    init(
        roomId: String,
        receivers: ReceiversConfig,
        recipientSelection: GiftRecipientSelectionState,
        onSent: @escaping () -> Void
    ) {
        self.roomId = roomId
        self.receivers = receivers
        self.onSent = onSent
        _recipientSelection = ObservedObject(wrappedValue: recipientSelection)
    }

    var body: some View {
        ZStack {
            Theme.Palette.partyRoomBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                receiverRow
                content
                Divider().overlay(Color.white.opacity(0.1))
                footer
            }
        }
        .task { await reload() }
        .onChange(of: recipientSelection.ids) { _ in clampCount() }
        .preferredColorScheme(.dark)
    }

    private var receiverRow: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(receivers.items) { receiver in
                        Button { toggleReceiver(receiver.id) } label: {
                            ZStack(alignment: .bottomTrailing) {
                                CachedAsyncImage(url: receiver.avatarURL, contentMode: .fill, persistent: true) {
                                    Circle().fill(Color.white.opacity(0.12))
                                }
                                .frame(width: 36, height: 36)
                                .clipShape(Circle())

                                Image(systemName: recipientSelection.ids.contains(receiver.id)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(recipientSelection.ids.contains(receiver.id) ? .pink : .white.opacity(0.65))
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                            .opacity(recipientSelection.ids.contains(receiver.id) ? 1 : 0.52)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 10)
            }

            if receivers.showAllButton, !receivers.items.isEmpty {
                Button {
                    let allIDs = Set(receivers.items.map(\.id))
                    if recipientSelection.ids == allIDs {
                        if receivers.items.count == 1 {
                            recipientSelection.replace(with: [])
                        } else {
                            let fallback = receivers.initialSelection.intersection(allIDs)
                            recipientSelection.replace(with: fallback.isEmpty
                                ? Set([receivers.items.first?.id].compactMap { $0 })
                                : fallback)
                        }
                    } else {
                        recipientSelection.replace(with: allIDs)
                    }
                    clampCount()
                } label: {
                    Image(systemName: recipientSelection.ids.count == receivers.items.count
                          ? "checkmark.circle.fill"
                          : "person.2.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.03))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && gifts.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed && gifts.isEmpty {
            Button(L10n.giftPickerRetry) { Task { await reload() } }
                .buttonStyle(.bordered)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if gifts.isEmpty {
            EmptyStateView(style: .compact, textFont: .system(size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(gifts) { gift in
                        giftCell(gift)
                            .onAppear {
                                guard gift.id == gifts.last?.id, hasMore, !isLoading else { return }
                                Task { await loadNextPage() }
                            }
                    }
                }
                .padding(12)

                if isLoading {
                    ProgressView().tint(.white).padding(.bottom, 8)
                }
            }
        }
    }

    private func giftCell(_ gift: PartyBackpackGift) -> some View {
        let isSelected = selectedGiftID == gift.id
        let isSendable = isSendableInParty(gift)
        return Button {
            guard isSendable else { return }
            selectedGiftID = gift.id
            count = 1
        } label: {
            VStack(spacing: 4) {
                CachedAsyncImage(url: gift.giftIcon.flatMap(URL.init(string:)),
                                 contentMode: .fit,
                                 persistent: true,
                                 cdn: (.gift, .fit)) {
                    Color.white.opacity(0.06)
                }
                .frame(width: 50, height: 50)

                Text(gift.giftName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                HStack(spacing: 2) {
                    Image("partyGems")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 10, height: 10)
                    Text("\(gift.giftPrice)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                }

                Text("x\(gift.quantity)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Palette.brandPink))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .opacity(isSendable ? 1 : 0.42)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.Palette.brandPink.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Theme.Palette.brandPink : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isSendable || isSending)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { adjustCount(by: -1) } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(count > 1 ? .white : .white.opacity(0.28))
            }
            .buttonStyle(.plain)
            .disabled(count <= 1 || isSending)

            Menu {
                ForEach([1, 5, 10, 20, 50, 99].filter { $0 <= maximumCount }, id: \.self) { value in
                    Button("\(value)") { count = value }
                }
            } label: {
                Text("\(count)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(minWidth: 28)
            }
            .disabled(isSending)

            Button { adjustCount(by: 1) } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(count < maximumCount ? .white : .white.opacity(0.28))
            }
            .buttonStyle(.plain)
            .disabled(count >= maximumCount || isSending)

            Spacer(minLength: 0)

            Button { Task { await send() } } label: {
                Group {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Text(L10n.giftPickerSend)
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundColor(.white)
                .frame(minWidth: 88, minHeight: 36)
                .padding(.horizontal, 18)
                .background(Capsule().fill(canSend ? Theme.Palette.brandPink : Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var selectedGift: PartyBackpackGift? {
        gifts.first { $0.id == selectedGiftID }
    }

    private var maximumCount: Int {
        guard let selectedGift, !recipientSelection.ids.isEmpty else { return 1 }
        return max(1, min(99, selectedGift.quantity / recipientSelection.ids.count))
    }

    private var canSend: Bool {
        !isSending
            && !roomId.isEmpty
            && selectedGift != nil
            && !recipientSelection.ids.isEmpty
            && count <= maximumCount
            && (selectedGift.map { count * recipientSelection.ids.count <= $0.quantity } ?? false)
    }

    private func isSendableInParty(_ gift: PartyBackpackGift) -> Bool {
        // H5 `backpackSendable`: 贴纸和幸运礼物只允许直播；Party 对应 display-scene dictValue=4。
        if gift.giftTypeV2 == 5 || gift.giftTypeV2 == 6 { return false }
        guard let scenes = gift.giftDisplayScene, !scenes.isEmpty else { return true }
        return scenes.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .contains("4")
    }

    private func toggleReceiver(_ id: String) {
        if recipientSelection.ids.contains(id) {
            var next = recipientSelection.ids
            next.remove(id)
            recipientSelection.replace(with: next)
        } else if receivers.allowMultiSelect {
            var next = recipientSelection.ids
            next.insert(id)
            recipientSelection.replace(with: next)
        } else {
            recipientSelection.replace(with: [id])
        }
        clampCount()
    }

    private func adjustCount(by delta: Int) {
        count = min(maximumCount, max(1, count + delta))
    }

    private func clampCount() {
        count = min(maximumCount, max(1, count))
    }

    private func reload() async {
        page = 1
        gifts = []
        hasMore = false
        loadFailed = false
        await loadPage(reset: true)
    }

    private func loadNextPage() async {
        await loadPage(reset: false)
    }

    private func loadPage(reset: Bool) async {
        guard !isLoading || reset else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await PartyAPI.partyBackpack(page: page)
            let validGifts = response.list.filter { $0.giftId > 0 && $0.quantity > 0 }
            if reset {
                gifts = validGifts
            } else {
                gifts.append(contentsOf: validGifts.filter { candidate in !gifts.contains(where: { $0.id == candidate.id }) })
            }
            hasMore = response.hasMore
            if response.hasMore { page += 1 }
            if selectedGift.flatMap({ gift in gifts.contains(where: { $0.id == gift.id }) ? gift : nil }) == nil {
                selectedGiftID = nil
                count = 1
            }
        } catch {
            loadFailed = true
            AppLogger.party.error("[PartyBackpack] load failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func send() async {
        guard let gift = selectedGift,
              isSendableInParty(gift),
              canSend else { return }
        let recipients = Array(recipientSelection.ids)
        isSending = true
        defer { isSending = false }
        do {
            let remaining = try await PartyAPI.sendPartyBackpackGift(
                roomId: roomId,
                giftId: gift.giftId,
                num: count,
                yxAccidList: recipients
            )
            let fallbackRemaining = max(0, gift.quantity - count * recipients.count)
            let nextQuantity = remaining ?? fallbackRemaining
            if nextQuantity == 0 {
                gifts.removeAll { $0.id == gift.id }
                selectedGiftID = nil
            } else if let index = gifts.firstIndex(where: { $0.id == gift.id }) {
                // 保持库存的其余服务端字段不变，只同步本次接口确认后的剩余数量。
                gifts[index] = PartyBackpackGift(
                    backpackId: gift.backpackId,
                    giftId: gift.giftId,
                    quantity: nextQuantity,
                    giftName: gift.giftName,
                    giftPrice: gift.giftPrice,
                    giftIcon: gift.giftIcon,
                    giftTypeV2: gift.giftTypeV2,
                    giftDisplayScene: gift.giftDisplayScene,
                    sendable: gift.sendable,
                    remainingTimeDesc: gift.remainingTimeDesc
                )
            }
            count = 1
            onSent()
            dismiss()
        } catch {
            AppLogger.party.error("[PartyBackpack] send failed: \(String(describing: error), privacy: .private)")
        }
    }
}
