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
    /// v9：公告只读 sheet 显隐（对齐 H5 announcement-popup.vue，MVP 只读；房主/房管编辑权限 F 期补）
    @State private var showAnnouncement: Bool = false
    /// v9：更多菜单 action sheet 显隐（对齐 H5 more-tool-popup.vue Minimize/Exit）
    @State private var showMoreActions: Bool = false
    /// v9：关注态本地缓存（进房后 FollowListService 拉不到，采用乐观切换；F 期加接口拉初始态）
    @State private var isFollowingOwner: Bool = false
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
            heatText: heatText,
            viewerCountText: "\(store.roomInfo?.onlineCount ?? 0)",
            isFollowing: isFollowingOwner,
            // v3：判"自己的房间" —— selfRole == .owner（对齐 PartyRoomInfo.selfRoleType 优先 roomRoleType，兜底 ownerId 比较）
            isSelfRoom: store.selfRole == .owner,
            // v9：房主+房管有管理权限（对齐 H5 header-wrap.vue v-if=computedRoomRoleType!==NORMAL）
            canManage: store.selfRole == .owner || store.selfRole == .admin,
            onFollowTap: handleFollowTap,
            onAnnouncementTap: handleAnnouncementTap,
            onShareTap: handleShareTap,
            onManagementTap: handleManagementTap,
            onMoreTap: handleMoreTap,
            onHeatTap: handleHeatTap,
            onViewerTap: handleViewerTap
        )
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

    private func handleSeatTap(_ seat: PartyRoomSeat) {
        if isSelf(seat) {
            showSelfActions = true
            return
        }
        if store.selfSeat == nil, !seat.occupied, let idx = seat.seatIndex {
            Task { await store.requestOnSeat(seatIndex: idx) }
            return
        }
    }

    // MARK: - 发送公屏 / demo 送礼

    private func sendText() {
        let txt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !txt.isEmpty, store.roomState == .joined else { return }
        store.chat.sendText(txt)
        inputText = ""
    }

    /// 送礼骨架：固定 demo giftId=1 num=1 → 当前在麦第一个非自己用户
    private func sendDemoGift() {
        guard let info = store.roomInfo else { return }
        let target = store.seatList.first { seat in
            guard let accid = seat.yxAccid, !accid.isEmpty else { return false }
            guard let uid = seat.userId, !uid.isEmpty else { return false }
            return uid != store.myUserIdString
        }
        guard let targetAccid = target?.yxAccid else {
            AppLogger.party.notice("[PartyRoom] no gift target (need yxAccid); skip")
            return
        }
        Task {
            do {
                _ = try await PartyAPI.sendGift(
                    roomId: info.id ?? "",
                    giftId: 1,
                    num: 1,
                    yxAccidList: [targetAccid]
                )
            } catch {
                AppLogger.party.error("[PartyRoom] sendGift failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    // MARK: - 顶部工具栏 handler

    /// v9：关注/取关房主（对齐 H5 header-wrap.vue userStore.followOrNo）
    /// 走 FollowListService.followUser(followUserId:followType:) 已封装的 /api/user/followUser。
    /// **乐观切换**：tap 后立即翻转 UI 态，接口失败静默回滚（提示待 F 期加 toast 基建）。
    /// 初始态 F 期加接口 /api/user/isFollowUser 拉取；MVP 默认 false。
    private func handleFollowTap() {
        guard let ownerIdStr = store.roomInfo?.ownerId,
              let ownerId = Int(ownerIdStr),
              store.selfRole != .owner
        else {
            AppLogger.party.notice("[PartyRoom] follow: no ownerId or is owner; skip")
            return
        }
        let willFollow = !isFollowingOwner
        isFollowingOwner = willFollow // 乐观切换
        Task { @MainActor in
            do {
                try await FollowListService.followUser(
                    followUserId: ownerId,
                    followType: willFollow ? 1 : 2
                )
            } catch {
                AppLogger.party.error("[PartyRoom] follow failed: \(String(describing: error), privacy: .private)")
                isFollowingOwner = !willFollow // 回滚
            }
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
                        stubToolToast = L10n.Party.toolComingSoon
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
            // TODO(F 期)：接入 PartyRoomBlocklistView（H5 blocklist.vue 对应）
            Text("Blocklist coming soon")
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Palette.partyListBackground.ignoresSafeArea())
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
    private func handleGiftTap() {
        // TODO(H 里程碑，礼物+虚拟道具+IM 完善)：接入 CommonGiftPanelConfig.partySend(roomId:receivers:...) 已就绪
        // receivers 装配 = sortedSeatsCache.compactMap { yxAccid+userId 均非空 && 非自己 }
        // balance/backpack/onSend 路由参照 Live 侧 GiftPanel usage
        // MVP 保留 demo 骨架验证 IM/RTC 通路
        sendDemoGift()
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
