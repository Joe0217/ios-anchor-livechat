import SwiftUI

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

    @ObservedObject private var store = PartyStore.shared
    @Environment(\.dismiss) private var dismiss
    /// v5.3.3 真根因坑：SwiftUI 在 ScenePhase=.background 时也会调度 onDisappear，
    /// 必须双守卫防误退房。
    @Environment(\.scenePhase) private var scenePhase

    @State private var inputText: String = ""
    @State private var showSelfActions: Bool = false
    @State private var showError: Bool = false
    @State private var didStartEnter: Bool = false
    /// v8 房主设置页 sheet（保留供其他路径直接触发；v8.1 主入口改走 activeRoomTool = .settings）
    @State private var showSettings: Bool = false
    /// v8.1 房间工具 sheet（enum-driven 单 sheet 切换，规避 iOS 16 双 sheet race）
    @State private var activeRoomTool: PartyRoomToolSheetKind? = nil
    /// tools sheet 内 stub 项 tap 时 toast
    @State private var stubToolToast: String? = nil
    /// E v2 §1：Room Mode 二次确认 sheet 之间共享的 pending tempId（模板 grid 选中 → 弹确认 sheet）
    @State private var pendingRoomModeTempId: Int? = nil
    /// v9：公告只读 sheet 显隐（对齐 H5 announcement-popup.vue，MVP 只读；房主/房管编辑权限 F 期补）
    @State private var showAnnouncement: Bool = false
    /// v9：更多菜单 action sheet 显隐（对齐 H5 more-tool-popup.vue Minimize/Exit）
    @State private var showMoreActions: Bool = false
    // v16（2026-07-14）：关注态改从 `store.isFollowingAnchor` 读，进房时 room/enter 接口的
    // `isFollowOwner` 字段初始化；本地 @State 已删除以避免"退出重进显示未关注"的状态漂移。
    /// v12：底部工具栏 message 按钮 → 复用 Live 侧 ConversationSheetContent 半屏消息列表
    @State private var showMessageSheet: Bool = false
    /// v12：底部工具栏 toolMenu 按钮 confirmationDialog（对齐 H5 party-tool-menu.vue PK/Lucky Number/Room Mute）
    @State private var showToolMenu: Bool = false
    /// v12：消息未读徽章（对齐 [swiftui-keepalive-publisher-isolation] 复用 Live 侧 bridge pattern）
    @StateObject private var unreadBridge = MessageEntryUnreadBridge()
    /// P2-10：sortedSeats 缓存
    @State private var sortedSeatsCache: [PartyRoomSeat] = []
    /// 聊天区 tab（视觉状态本地维护；MVP 阶段 All/Chat/Gift 共用同一消息列表，
    /// 实际按 kind 过滤留待 F 期在 PartyMessageListView 内实现）
    @State private var chatFilter: PartyRoomChatFilter = .all
    /// v15：他人麦位 tap → UserCardPopup 显示（对齐 H5 openUserCard；nil = 不显示）
    @State private var userCardForUserId: String? = nil
    /// v15：已在 A 麦位点 B 空位 → 切麦确认（对齐 H5 EnterSwitchPopup；nil = 不显示）
    @State private var switchSeatPendingTarget: PartyRoomSeat? = nil
    /// v15：房主/房管点空位 → 弹管理动作 dialog（Take/Lock/Unlock；对齐 H5 my-mic-tool.vue 简化版）
    @State private var adminSeatActionsTarget: PartyRoomSeat? = nil
    /// v15：房主/房管点他人占用位 → 弹管理动作 dialog（Mute/Unmute + View Profile；对齐 H5 feachProhibitSeat 语义）
    @State private var otherSeatAdminActionsTarget: PartyRoomSeat? = nil
    /// H-5：礼物面板 sheet 显隐（点底部礼物 icon 触发；对齐 H5 party-gift-popup.vue showPartyGiftPopup）
    @State private var showGiftPanel: Bool = false
    /// H-5：送礼成功 toast（sheet 内触发；主 body overlay 显示避免被 sheet 遮挡）
    @State private var giftSentToast: String? = nil
    /// H-5：Recharge 按钮 toast（充值功能未接入前的占位提示）
    @State private var giftRechargeToast: String? = nil

    // MARK: - 顶层 body

    var body: some View {
        sceneBody
            .giftEffectScene(.party, scopeId: store.roomInfo?.id ?? roomId)
            // v23（2026-07-13）派对房进场特效：与 giftEffectScene 并列驱动 EnterEffectCenter
            // scopeId 同源用 roomInfo?.id（与 PartyStore.didReceiveEnterAnimation 内 EnterEffectCenter.enqueue 的 scopeId 强对齐）
            .enterEffectScene(.party, scopeId: store.roomInfo?.id ?? roomId)
    }

    /// 拆两层规避 SwiftUI type-check timeout（[swiftui-body-type-check-timeout] rule）：
    /// body 已含 modifier + 嵌套 ZStack，直接挂 alert/toolbar/onAppear 编译器负载过高。
    private var sceneBody: some View {
        stageContentWithFooterOverlays
            // 隐藏 nav bar：Party 房是全屏视觉铺满自定义顶栏，无系统 nav bar。
            // 保留 navigationBarBackButtonHidden 副作用禁 interactive pop（对齐 [default-swipe-back-on-push-pages] 业务态防误退例外）。
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { settingsSheet }
            .sheet(isPresented: $showAnnouncement) { announcementSheet }
            // v8.1 房间工具 sheet（单一挂点，enum 切换 tools / settings 内嵌 push）
            .sheet(item: $activeRoomTool) { kind in
                roomToolContent(kind: kind)
            }
            // H-5：底部礼物 icon → CommonGiftPanel sheet（对齐 H5 party-gift-popup.vue）
            .sheet(isPresented: $showGiftPanel) { giftPanelSheet }
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
                if let t = stubToolToast {
                    Text(t)
                        .toastStyle()
                        .transition(Toast.transition)
                        .task(id: t) {
                            try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                            stubToolToast = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: stubToolToast == nil)
            .confirmationDialog(L10n.PartyRoom.moreMenuTitle, isPresented: $showMoreActions, titleVisibility: .visible) {
                moreActionsButtons
            }
            .onAppear(perform: handleAppear)
            .onChange(of: store.seatList, perform: handleSeatListChange)
            .onDisappear(perform: handleDisappear)
            .alert(L10n.Party.inviteTitle, isPresented: invitePresented) {
                inviteAlertButtons
            } message: {
                inviteAlertMessage
            }
            .alert(L10n.Party.alertTitle, isPresented: $showError) {
                Button(L10n.Party.ok) { store.clearLastError() }
            } message: {
                Text(store.lastError?.errorDescription ?? "")
            }
            .onChange(of: store.lastError?.errorDescription ?? "", perform: handleLastErrorChange)
            .confirmationDialog(L10n.Party.selfActionsTitle, isPresented: $showSelfActions) {
                selfActionsButtons
            }
            // v15：他人麦位 tap → UserCardPopup（对齐 H5 openUserCard）
            .overlay { userCardOverlay }
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
            // v15：房主/房管点他人占用位 → 管理动作 dialog（Mute / Unmute / View Profile）
            .confirmationDialog(
                L10n.PartyRoom.otherSeatAdminActionsTitle,
                isPresented: otherSeatAdminActionsPresented,
                titleVisibility: .visible
            ) {
                otherSeatAdminActionsButtons
            }
            .preferredColorScheme(.dark)
    }

    // MARK: - 全屏 stage

    private var stageContent: some View {
        ZStack {
            backgroundLayer
            contentColumn
            // v8：进房 loading overlay（对齐 H5 clickRoomItem 全屏 isSearchLoading 反馈）
            // 显示条件：preparing / entering 态；joined 或 ended 时消失让房内 UI 显现
            if store.roomState == .preparing || store.roomState == .entering {
                enterLoadingOverlay
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
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

    /// 背景层：房间大图 + 深色遮罩
    private var backgroundLayer: some View {
        ZStack {
            Image("partyRoomBg")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            Theme.Palette.partyRoomOverlay
                .ignoresSafeArea()
        }
    }

    /// 内容层
    private var contentColumn: some View {
        VStack(spacing: 0) {
            anchorBar
                // v3：上内边距再 +6pt（8 → 16 → 22），与 status bar/dynamic island 更宽松呼吸位
                .padding(.top, 22)
            bigSeatRow
            smallSeatGrid
                .padding(.top, 12)
            chatArea
            Spacer(minLength: 0)
            inputBar
        }
    }

    // MARK: - 顶部主播条

    private var anchorBar: some View {
        PartyRoomAnchorBar(
            roomName: store.roomInfo?.roomName ?? L10n.Party.defaultRoomName,
            roomId: store.roomInfo?.id ?? roomId,
            anchorAvatarURL: store.roomInfo?.roomAvatar,
            // v12：头像装饰框 URL（async 从 apiPartyGetUser 拉；对齐 H5 head-frame.vue）
            headFrameURL: store.ownerHeadFrameURL,
            wealthText: heatText,
            honorText: heatText,
            audienceCountText: "\(store.roomInfo?.onlineCount ?? 0)",
            isFollowing: store.isFollowingAnchor,
            isSelfRoom: store.selfRole == .owner,
            canManage: store.selfRole == .owner || store.selfRole == .admin,
            canStartPk: (store.selfRole == .owner || store.selfRole == .admin) && (store.roomInfo?.roomTempIdInt == 1),
            onFollowTap: handleFollowTap,
            onPkTap: handlePkTap,
            onAnnouncementTap: handleAnnouncementTap,
            onShareTap: handleShareTap,
            onManagementTap: handleManagementTap,
            onMoreTap: handleMoreTap,
            onRankTap: handleRankTap,
            onViewerTap: handleViewerTap
        )
    }

    private func handlePkTap() {
        AppLogger.party.notice("[PartyRoom] pk tapped (TODO G-milestone PK flow)")
    }

    private func handleRankTap(_ kind: PartyRankKind) {
        AppLogger.party.notice("[PartyRoom] rank tapped kind=\(String(describing: kind), privacy: .public) (TODO F-milestone rank sheet)")
    }

    private var heatText: String {
        let heat = store.roomInfo?.heatValue ?? 0
        return PartyNumberFormat.compact(heat)
    }

    // MARK: - 大麦位（按模板动态：0/1/2/3/6+ 视频位）

    /// v12（对齐 H5 蓝本 livechat-h5/src/components/party/components/main-wrap.vue）：
    /// - `1`：外层 `.video-wrap h-180` 全宽容器（小屏 <380pt 高 156pt），内层视频 cell `w-186` 居中
    /// - `6`：`.video-wrap-6 grid grid-cols-3 gap-1 px-1`，每 cell `aspect-[6/5]`
    /// - `2/3/其他`：v11 沿用 HStack 均分屏宽，每 cell 9/16 竖屏
    /// - `0`：整行隐藏（纯语聊模板）
    @ViewBuilder
    private var bigSeatRow: some View {
        if bigSeats.count == 1 {
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
        let containerHeight: CGFloat = UIScreen.main.bounds.width < 380 ? 156 : 180
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
            .onTapGesture { handleSeatTap(seat) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: containerHeight)
    }

    /// v12：6 视频位模板 —— 3 列 × 2 行 grid（对齐 H5 `grid grid-cols-3 gap-1 px-1` + `aspect-[6/5]`）
    private var sixBigSeatGrid: some View {
        LazyVGrid(columns: sixBigSeatColumns, spacing: 4) {
            ForEach(bigSeats, id: \.stableId) { seat in
                PartyRoomBigSeatCell(
                    seat: seat,
                    isSelf: isSelf(seat),
                    isLocalCameraActive: store.isLocalCameraActive,
                    camera: store.camera,
                    engine: store.rtc,
                    aspectRatio: 6.0 / 5.0
                )
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, 4)
    }

    private var sixBigSeatColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
    }

    /// v11 沿用：2/3/其他 count → HStack 均分屏宽 + 每 cell 9/16 竖屏
    private var multiBigSeatRow: some View {
        HStack(spacing: Theme.Metric.partyRoomBigSeatGap) {
            ForEach(bigSeats, id: \.stableId) { seat in
                PartyRoomBigSeatCell(
                    seat: seat,
                    isSelf: isSelf(seat),
                    isLocalCameraActive: store.isLocalCameraActive,
                    camera: store.camera,
                    engine: store.rtc
                )
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        // v9：已按 seat.seatType 分组（video→大位，voice→小位）—— 对齐 H5 main-wrap.vue
    }

    /// v9：按 seatType 分组（对齐 H5 main-wrap.vue slice(0, videoMicNum)）
    private var bigSeats: [PartyRoomSeat] {
        sortedSeatsCache.filter { $0.seatType == PartyRoomSeatType.video.rawValue }
    }

    // MARK: - 小麦位（按模板动态列数）

    /// v11：按模板动态渲染 —— smallSeats.count == 0（纯视频模板）时整个 grid 隐藏
    @ViewBuilder
    private var smallSeatGrid: some View {
        if !smallSeats.isEmpty {
            LazyVGrid(columns: smallSeatColumns, spacing: 14) {
                ForEach(smallSeats, id: \.stableId) { seat in
                    PartyRoomSmallSeatCell(seat: seat)
                        .onTapGesture { handleSeatTap(seat) }
                }
            }
            .padding(.horizontal, Theme.Metric.partyRoomScreenH)
        }
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
            lastGiftEvent: store.lastGiftEvent
        )
        .padding(.top, 6)
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
            onSubmit: sendText,
            onEmojiTap: handleEmojiTap,
            onMessageTap: handleMessageTap,
            onMicTap: handleMicTap,
            onGameTap: handleGameTap,
            onToolMenuTap: handleToolMenuTap,
            onGiftTap: handleGiftTap
        )
        // v2：下内边距 +12pt（原 8 → 20），让按钮行距 home indicator 更宽松呼吸位
        // padding 挂在 .background 之前，背景 frame 仍覆盖含 padding 区域并继续 ignoresSafeArea 延伸到物理底
        .padding(.bottom, 20)
        .background(
            Rectangle().fill(Color.black.opacity(0.15))
                .ignoresSafeArea(edges: .bottom)
        )
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
            Text(String(format: L10n.Party.inviteMessageFormat,
                        i.fromNickname ?? L10n.Party.defaultUser,
                        i.seatIndex))
        }
    }

    // MARK: - 自己麦位 sheet

    @ViewBuilder private var selfActionsButtons: some View {
        if let me = store.selfSeat {
            let micOn = (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
            Button(micOn ? L10n.Party.selfMicOff : L10n.Party.selfMicOn) {
                Task { await store.toggleSelfMedia(type: 1, enable: !micOn) }
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
        AutoOfflineMonitor.shared.suspend()
        // 用户诉求 2026-07-09：进派对房 = 独占摄像头，若匹配中先静默关匹配
        if MatchStore.shared.state == .matching {
            Task { await MatchStore.shared.closeMatch(silent: true) }
        }
        // P2-10：onAppear 同步 cache 一次仅作为"上次会话残留"兜底
        sortedSeatsCache = store.seatList.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }
        guard !didStartEnter else { return }
        didStartEnter = true
        Task { await ensureEntered() }
    }

    /// 双守卫防误退房：scenePhase != .background + 仅活跃态才 leave
    private func handleDisappear() {
        guard scenePhase != .background else { return }
        AutoOfflineMonitor.shared.resume()
        if store.roomState == .joined || store.roomState == .entering {
            Task { await store.leaveRoom() }
        }
    }

    private func handleSeatListChange(_ newList: [PartyRoomSeat]) {
        sortedSeatsCache = newList.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }
    }

    private func handleLastErrorChange(_ msg: String) {
        showError = !msg.isEmpty
    }

    private func ensureEntered() async {
        if store.roomState == .joined, store.roomInfo?.id == roomId { return }
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
    /// 2. 他人占用麦位 → userCard（弹 UserCardPopup）
    /// 3. **管理员（房主/房管）点空位 → adminSeatActionsTarget（Take/Lock/Unlock dialog）**
    /// 4. 空锁麦位 (lockFlag=1) → toast "The seat is locked"（非管理员）
    /// 5. 空视频位 + 非管理员 → toast "Requires invitation..."
    /// 6. 空语音位 + 已在其他麦位 → switchSeatPendingTarget（切麦确认）
    /// 7. 空语音位 + 未在任何麦位 → 直接 onSeat
    private func handleSeatTap(_ seat: PartyRoomSeat) {
        if isSelf(seat) {
            showSelfActions = true
            return
        }
        let isManager = store.selfRole == .owner || store.selfRole == .admin
        if seat.occupied, let uid = seat.userId, !uid.isEmpty {
            // v15：房主/房管点他人占用位 → 管理 dialog（Mute/Unmute + View Profile）
            // 非管理员 → 直接 UserCard（对齐 H5 openUserCard）
            if isManager {
                otherSeatAdminActionsTarget = seat
            } else {
                userCardForUserId = uid
            }
            return
        }
        guard let idx = seat.seatIndex else { return }
        if isManager {
            adminSeatActionsTarget = seat
            return
        }
        if (seat.lockFlag ?? 0) == 1 {
            stubToolToast = L10n.PartyRoom.seatLockedToast
            return
        }
        if seat.seatType == PartyRoomSeatType.video.rawValue {
            stubToolToast = L10n.PartyRoom.videoSeatNeedsInviteToast
            return
        }
        // 空语音位（非管理员）
        if store.selfSeat != nil {
            switchSeatPendingTarget = seat
            return
        }
        Task { await store.requestOnSeat(seatIndex: idx) }
    }

    // MARK: - v15 UserCard overlay

    @ViewBuilder
    private var userCardOverlay: some View {
        if let uid = userCardForUserId {
            UserCardPopup(
                userId: uid,
                isPresented: Binding(
                    get: { userCardForUserId != nil },
                    set: { if !$0 { userCardForUserId = nil } }
                )
            )
        }
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
            // Lock / Unlock
            Button(locked ? L10n.PartyRoom.adminActionUnlock : L10n.PartyRoom.adminActionLock) {
                adminSeatActionsTarget = nil
                Task { await store.requestLockSeat(seatIndex: idx, lock: !locked) }
            }
        }
        Button(L10n.Party.cancel, role: .cancel) { adminSeatActionsTarget = nil }
    }

    // MARK: - v15 房主/房管他人占用位管理

    private var otherSeatAdminActionsPresented: Binding<Bool> {
        Binding(
            get: { otherSeatAdminActionsTarget != nil },
            set: { if !$0 { otherSeatAdminActionsTarget = nil } }
        )
    }

    /// 房主/房管点他人占用位的动作 dialog：
    /// - **Mute/Unmute（仅语音麦位）**：调 prohibitSeat 切 seatMicrophoneEnabled（对齐 H5 my-mic-tool `!nowSeatIsVideo` 条件）
    /// - **View Profile**：dismiss dialog + 弹 UserCardPopup（保留原查看用户资料能力）
    /// - Kick / Manager 等入口留 Phase 2（需 UserCard 内做，跨场景组件不改）
    @ViewBuilder private var otherSeatAdminActionsButtons: some View {
        if let seat = otherSeatAdminActionsTarget, let idx = seat.seatIndex {
            // Mute/Unmute 仅语音麦位（对齐 H5 v-if=!nowSeatIsVideo）
            if seat.seatType == PartyRoomSeatType.voice.rawValue {
                let muted = (seat.seatMicrophoneEnabled ?? 1) == 0
                Button(muted ? L10n.PartyRoom.adminActionUnmute : L10n.PartyRoom.adminActionMute) {
                    otherSeatAdminActionsTarget = nil
                    Task { await store.requestProhibitSeat(seatIndex: idx, mute: !muted) }
                }
            }
            // View Profile - dismiss + open UserCard
            if let uid = seat.userId, !uid.isEmpty {
                Button(L10n.PartyRoom.adminActionViewProfile) {
                    otherSeatAdminActionsTarget = nil
                    // iOS 16 sheet/dialog race 规避：延一帧再挂 UserCard overlay
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        userCardForUserId = uid
                    }
                }
            }
        }
        Button(L10n.Party.cancel, role: .cancel) { otherSeatAdminActionsTarget = nil }
    }

    // MARK: - 发送公屏 / demo 送礼

    private func sendText() {
        let txt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !txt.isEmpty, store.roomState == .joined else { return }
        store.chat.sendText(txt)
        inputText = ""
    }

    // MARK: - 顶部工具栏 handler

    /// v16：关注/取关房主（对齐 H5 header-wrap.vue userStore.followOrNo）
    /// 走 `store.toggleFollowAnchor()` 统一维护 `isFollowingAnchor`；
    /// **成功 toast 由 [FollowListService.followUser] service 层触发 [AppToastCenter] 全局弹出**，
    /// 本 view 不再本地弹（避免与全局 toast 重复展示）。
    /// 进房关注态由 room/enter 接口 `isFollowOwner` 字段初始化，退出重进保持一致。
    private func handleFollowTap() {
        guard store.selfRole != .owner else {
            AppLogger.party.notice("[PartyRoom] follow: is owner; skip")
            return
        }
        Task { @MainActor in
            _ = await store.toggleFollowAnchor()
        }
    }

    /// v9：公告只读 sheet（对齐 H5 announcement-popup.vue，MVP 只读）
    /// 房主/房管编辑权限 F 期补（PartyAPI.setAnnouncement 端点 + 编辑态 UI）。
    private func handleAnnouncementTap() {
        showAnnouncement = true
    }

    private func handleShareTap() {
        // TODO(F 里程碑)：SwiftUI ShareLink + AppConfig.shareBaseURL + roomId 构造深链；
        // H5 蓝本 share-list-wrap.vue 是分享到 IM 好友（走 NIM 自定义消息），iOS 复用 P2PChatStore；
        // 站外分享用 iOS 原生 ShareLink 兜底。是否需 apiGetShareUrl 短链需 H5 二次校验（api-http-method-strict rule）
        AppLogger.party.notice("[PartyRoom] share tapped (TODO F)")
    }
    private func handleManagementTap() {
        // v8.1：对齐 H5 房主/房管 tap 齿轮弹 tools sheet（Room Tools）。
        // 非普通用户（owner + admin）都可见 tools sheet；普通用户保持 stub log。
        // MVP 目前 selfRole 只区分 owner/audience，admin 待接入实际权限判定后放开。
        if store.selfRole == .owner {
            activeRoomTool = .tools
        } else {
            AppLogger.party.notice("[PartyRoom] management tapped by non-owner (TODO F: admin 权限判定)")
        }
    }

    /// v8.1 房间工具 sheet（enum-driven 单 sheet 切换）：
    /// - .tools → PartyRoomToolsSheet（3 列网格）
    /// - .settings → 房主设置编辑页
    /// - .blocklist → 黑名单页（F 期实现，MVP stub）
    @ViewBuilder
    private func roomToolContent(kind: PartyRoomToolSheetKind) -> some View {
        switch kind {
        case .tools:
            PartyRoomToolsSheet(
                isOwner: store.selfRole == .owner,
                isPlatformAdmin: false,  // TODO(F): 接入 roomInfo.isPlatformAdmin
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
                    // E v2 §2：切 Mic Application 申请列表 sheet
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .micApplicationList
                    }
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
                    // E-spec MC Seat：关 tools sheet + 350ms 后打开 PartyMCSeatSheet
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .mcSeat
                    }
                },
                onTapStub: { label in
                    // 关 sheet + 顶部 toast
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        stubToolToast = "\(label): \(L10n.Party.toolComingSoon)"
                    }
                }
            )
            .presentationDetents([.medium])
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
            .presentationDetents([.medium, .large])
        case .roomMode:
            // E v2 §1 + §3 Sheet Mount Hoist：Room Mode 模板 grid → onConfirmRequest 上抛 → 切 .roomModeConfirm
            NavigationStack {
                PartyRoomModeSheet(
                    store: store,
                    userLevel: AnchorInfoStore.shared.mine?.level ?? 0,
                    onConfirmRequest: { tempId in
                        Task { @MainActor in
                            activeRoomTool = nil
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            pendingRoomModeTempId = tempId
                            activeRoomTool = .roomModeConfirm
                        }
                    }
                )
            }
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
            .presentationDetents([.height(200)])
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
                })
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
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
            .presentationDetents([.height(220)])
        case .lockRoom:
            NavigationStack {
                PartyLockRoomSheet(store: store)
            }
            .presentationDetents([.height(320)])
            .preferredColorScheme(.dark)
        case .mcSeat:
            NavigationStack { PartyMCSeatSheet(store: store) }
                .presentationDetents([.medium, .large])
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
        // TODO(F 里程碑)：新建 PartyRoomRankSheet 展示房间热度/贡献榜（H5 蓝本 room-rank.vue tab=wealthRank/honorRank）；
        // 数据源 apiPartyContributionRank / apiPartyHonorRank 需 H5 二次校验字面 path。
        AppLogger.party.notice("[PartyRoom] heat tapped (TODO F)")
    }
    private func handleViewerTap() {
        // TODO(F 里程碑)：新建 PartyRoomViewerListSheet 复用 UserWeeklyRankSheetView pattern；
        // 数据源直接消费 store.roomInfo.onlineUserList，cell tap → UserCardPopup（H-0 已就绪）；
        // onlineCount==0 时按 H5 语义应隐藏按钮（当前 UX 常显）
        AppLogger.party.notice("[PartyRoom] viewer list tapped (TODO F)")
    }
    private func handleEmojiTap() {
        // TODO(F 里程碑)：H5 蓝本 party-expression-popup.vue —— 表情面板走独立 IM 消息码 + SVGA 广播；
        // 上麦门槛 v-if inPartyRole > -1 已在 PartyRoomInputBar isOnSeat 处过滤；
        // 面板本身需 apiPartyEmojiList + apiPartySendEmoji 端点接入
        AppLogger.party.notice("[PartyRoom] emoji tapped (TODO F)")
    }
    /// v12：消息按钮（对齐 H5 footer-wrap.vue onClickMsgBtn → partyStore.openPartyMessage()）
    /// A 档接入：复用 Live 侧 ConversationSheetContent 半屏消息列表
    private func handleMessageTap() {
        showMessageSheet = true
    }

    /// v12：更多工具菜单（对齐 H5 party-tool-menu.vue PK/Lucky Number/Room Mute 汇总）
    /// B 档 stub：弹 confirmationDialog 汇总 3 入口；接口 F/G 期接
    /// TODO(F/G 里程碑)：
    ///   - Room Mute → PartyRTCEngine.setMuteAllRemoteAudio(Bool) + Store isRoomMuted
    ///   - Start PK → G 期；roomTempId===1 && battleStore.isFunctionEnabled 双门槛
    ///   - Lucky Number → F 期；usePartyLuckyNumber.generate() + 配置面板
    private func handleToolMenuTap() {
        showToolMenu = true
    }

    /// 麦按钮：若已在麦，直接切自己 mic；未上麦不响应
    private func handleMicTap() {
        guard let me = store.selfSeat else { return }
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
        showGiftPanel = true
    }

    /// H-5：礼物面板 sheet 内容 —— CommonGiftPanel + `.partySend` 工厂配置。
    /// receivers 由 [PartyGiftPanelBridge.makeReceiversConfig] 从 seatList 派生（过滤空 yxAccid/自己）。
    @ViewBuilder
    private var giftPanelSheet: some View {
        let receivers = PartyGiftPanelBridge.makeReceiversConfig(
            seatList: store.seatList,
            selfUserId: store.myUserIdString
        )
        let config = CommonGiftPanelConfig.partySend(
            roomId: store.roomInfo?.id ?? roomId,
            receivers: receivers,
            onRechargeRequested: {
                giftRechargeToast = L10n.giftPickerRechargeToast
            },
            onSend: { _, _, _ in
                giftSentToast = L10n.giftPickerSentToast
            }
        )
        CommonGiftPanel(config: config)
            .overlay(alignment: .top) {
                if let t = giftRechargeToast {
                    Text(t)
                        .toastStyle()
                        .transition(Toast.transition)
                        .task(id: t) {
                            try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                            giftRechargeToast = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: giftRechargeToast == nil)
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
    }

    // MARK: - v9 sheets & action dialogs

    /// 公告只读 sheet（对齐 H5 announcement-popup.vue MVP 分档）。
    /// H5 房主/管理员可编辑，本轮只读；F 期补编辑权限流程。
    @ViewBuilder
    private var announcementSheet: some View {
        NavigationStack {
            let text = store.roomInfo?.greetingMessage ?? ""
            ScrollView {
                if text.isEmpty {
                    Text(L10n.PartyRoom.announcementEmpty)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .navigationTitle(L10n.PartyRoom.announcementTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.PartyRoom.announcementClose) { showAnnouncement = false }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    /// 更多菜单 action sheet（对齐 H5 more-tool-popup.vue：Minimize + Exit）
    /// Minimize (PiP) 留 F 期，MVP 只提供 Exit + Cancel。
    @ViewBuilder
    private var moreActionsButtons: some View {
        Button(L10n.PartyRoom.moreMenuLeave, role: .destructive) {
            Task {
                await store.leaveRoom()
                dismiss()
            }
        }
        Button(L10n.Party.cancel, role: .cancel) {}
    }

    // MARK: - v13 底部工具栏覆盖层（message / toolMenu；v13 已删 apply）

    /// 把新加的 footer overlay 挂在 stageContent 上，让 sceneBody 保持轻量
    /// 避免 modifier chain 累加触发 SwiftUI type-check timeout（rule swiftui-body-type-check-timeout §4）
    private var stageContentWithFooterOverlays: some View {
        stageContent
            .sheet(isPresented: $showMessageSheet) { messageSheetContent }
            .confirmationDialog(L10n.PartyRoom.toolMenuTitle,
                                isPresented: $showToolMenu,
                                titleVisibility: .visible) { toolMenuButtons }
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

    /// 更多工具菜单 dialog（B 档 stub）—— 汇总 PK / Lucky Number / Room Mute 三入口 + Cancel
    @ViewBuilder
    private var toolMenuButtons: some View {
        // TODO(G 里程碑)：Start PK —— roomTempId===1 && battleStore.isFunctionEnabled 双门槛
        Button(L10n.PartyRoom.toolMenuStartPk) {
            AppLogger.party.notice("[PartyRoom] toolMenu.startPk tapped (TODO G)")
        }
        // TODO(F 里程碑)：Lucky Number generate/settings —— usePartyLuckyNumber.generate() + 配置面板
        Button(L10n.PartyRoom.toolMenuLuckyNumber) {
            AppLogger.party.notice("[PartyRoom] toolMenu.luckyNumber tapped (TODO F)")
        }
        // TODO(F 里程碑)：Room Mute —— PartyRTCEngine.setMuteAllRemoteAudio(Bool) + Store isRoomMuted
        Button(L10n.PartyRoom.toolMenuRoomMute) {
            AppLogger.party.notice("[PartyRoom] toolMenu.roomMute tapped (TODO F)")
        }
        Button(L10n.Party.cancel, role: .cancel) {}
    }
}
