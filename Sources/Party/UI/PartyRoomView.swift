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
    /// v8 房主设置页 sheet
    @State private var showSettings: Bool = false
    /// P2-10：sortedSeats 缓存
    @State private var sortedSeatsCache: [PartyRoomSeat] = []
    /// 聊天区 tab（视觉状态本地维护；MVP 阶段 All/Chat/Gift 共用同一消息列表，
    /// 实际按 kind 过滤留待 F 期在 PartyMessageListView 内实现）
    @State private var chatFilter: PartyRoomChatFilter = .all

    // MARK: - 顶层 body

    var body: some View {
        sceneBody
            .giftEffectScene(.party, scopeId: store.roomInfo?.id ?? roomId)
    }

    /// 拆两层规避 SwiftUI type-check timeout（[swiftui-body-type-check-timeout] rule）：
    /// body 已含 modifier + 嵌套 ZStack，直接挂 alert/toolbar/onAppear 编译器负载过高。
    private var sceneBody: some View {
        stageContent
            // 隐藏 nav bar：Party 房是全屏视觉铺满自定义顶栏，无系统 nav bar。
            // 保留 navigationBarBackButtonHidden 副作用禁 interactive pop（对齐 [default-swipe-back-on-push-pages] 业务态防误退例外）。
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { settingsSheet }
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
            isFollowing: false,
            // v3：判"自己的房间" —— selfRole == .owner（对齐 PartyRoomInfo.selfRoleType 优先 roomRoleType，兜底 ownerId 比较）
            isSelfRoom: store.selfRole == .owner,
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

    // MARK: - 大麦位（3 格铺满宽度）

    private var bigSeatRow: some View {
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
            // 若模板不足 3 个大位，补占位保持视觉平衡
            ForEach(bigSeatPlaceholders, id: \.self) { _ in
                emptyBigSeatPlaceholder
            }
        }
        // TODO(F 期)：目前"大/小位"按 seatIndex 前 3 划分，依赖后端约定 videoSeat 排在 seatIndex 1..N。
        // 若后端派 videoSeat 到 seatIndex ≥ 4，那些视频位会静默丢流（Small cell 只 render 头像）。
        // F 期改为按 seat.seatType 分组（type==1 → 大位 grid, type==2 → 小位 grid）
    }

    private var bigSeats: [PartyRoomSeat] {
        Array(sortedSeatsCache.prefix(3))
    }

    private var bigSeatPlaceholders: [Int] {
        let n = 3 - bigSeats.count
        return n > 0 ? Array(0..<n) : []
    }

    private var emptyBigSeatPlaceholder: some View {
        // seatList 到位前的骨架占位：填色必须与 PartyRoomBigSeatCell 空位分支（Color.white.opacity(0.15)）
        // 完全一致，避免用 partyRoomSeatFill 深灰导致进房瞬间「黑闪 → 亮灰」的两阶段闪烁
        Rectangle()
            .fill(Color.white.opacity(0.15))
            // 与 PartyRoomBigSeatCell 保持一致的 9:16 竖屏比例，避免 HStack 内格子高度参差
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
    }

    // MARK: - 小麦位（10 格 5×2）

    private var smallSeatGrid: some View {
        LazyVGrid(columns: smallSeatColumns, spacing: 14) {
            ForEach(smallSeats, id: \.stableId) { seat in
                PartyRoomSmallSeatCell(seat: seat)
                    .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, Theme.Metric.partyRoomScreenH)
    }

    private var smallSeatColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(),
                                  spacing: Theme.Metric.partyRoomSmallSeatGap),
              count: 5)
    }

    private var smallSeats: [PartyRoomSeat] {
        Array(sortedSeatsCache.dropFirst(3))
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
            speakerOn: true, // 扬声器 UI 态占位；F 期接入实际扬声器路由
            onSubmit: sendText,
            onEmojiTap: handleEmojiTap,
            onSpeakerTap: handleSpeakerTap,
            onMicTap: handleMicTap,
            onGameTap: handleGameTap,
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
        await store.enterRoom(roomId: roomId)
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

    // MARK: - 顶部工具栏 / 底部工具栏占位（F 期接入具体面板）

    private func handleFollowTap() {
        AppLogger.party.notice("[PartyRoom] follow tapped (TODO F)")
    }
    private func handleAnnouncementTap() {
        AppLogger.party.notice("[PartyRoom] announcement tapped (TODO F)")
    }
    private func handleShareTap() {
        AppLogger.party.notice("[PartyRoom] share tapped (TODO F)")
    }
    private func handleManagementTap() {
        // v8：房主 → 打开设置 sheet；非房主 → 现有 stub（F 期为房管抽独立菜单）
        if store.selfRole == .owner {
            showSettings = true
        } else {
            AppLogger.party.notice("[PartyRoom] management tapped by non-owner (TODO F)")
        }
    }

    /// v8 房主设置 sheet：内嵌 NavigationStack 支持 Admin 子页 push
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
                    backgroundId: nil     // 由 Store.loadCurrentBackground 拉 getRoomBgImage 填充
                ),
                onSaved: {
                    // 保存成功后关 sheet；store.roomInfo 刷新由 F 期加接口（reloadRoomInfo）
                    showSettings = false
                }
            )
        }
        .preferredColorScheme(.dark)
    }
    private func handleMoreTap() {
        // MVP：顶部更多 = 退房入口（对齐旧版 header 的 ✕ 按钮语义）
        Task {
            await store.leaveRoom()
            dismiss()
        }
    }
    private func handleHeatTap() {
        AppLogger.party.notice("[PartyRoom] heat tapped (TODO F)")
    }
    private func handleViewerTap() {
        AppLogger.party.notice("[PartyRoom] viewer list tapped (TODO F)")
    }
    private func handleEmojiTap() {
        AppLogger.party.notice("[PartyRoom] emoji tapped (TODO F)")
    }
    private func handleSpeakerTap() {
        AppLogger.party.notice("[PartyRoom] speaker tapped (TODO F)")
    }
    /// 麦按钮：若已在麦，直接切自己 mic；未上麦不响应
    private func handleMicTap() {
        guard let me = store.selfSeat else { return }
        let micOn = (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
        Task { await store.toggleSelfMedia(type: 1, enable: !micOn) }
    }
    private func handleGameTap() {
        AppLogger.party.notice("[PartyRoom] game tapped (TODO J)")
    }
    private func handleGiftTap() {
        sendDemoGift()
    }
}
