import SwiftUI

/// 派对房核心舞台（spec §1.4.7 + §1.0.3 公共耦合显式标注）。
///
/// 结构：
/// ┌───────────────────────────┐
/// │ 房名 | 在线 N | × 退房      │ 顶栏
/// ├───────────────────────────┤
/// │ 麦位网格（4 列，按 seatIndex）│
/// │   语聊位 / 视频位混合          │
/// ├───────────────────────────┤
/// │ 公屏列表（自动滚到底）         │
/// │   ... 历史 30 条 ...         │
/// │   [text] [send] [gift]       │
/// └───────────────────────────┘
///
/// MVP 行为：
/// - onAppear：state != joined 时 enterRoom；若残留房与目标不一致先 forceLeave 强清
/// - 麦位点击：自己空 → 上麦；自己已在麦 → 弹下麦/媒体切换/退房
/// - 视频位邀请：pendingVideoSeatInvite != nil 时 alert 接受/拒绝
/// - 送礼骨架：固定 demo giftId=1 给当前在麦的第一个非自己用户
struct PartyRoomView: View {
    let roomId: String

    @ObservedObject private var store = PartyStore.shared
    // P1-6：chat 不在顶层观测 — 移到 PartyMessageListView 子 view + PartyRoomHeaderView 子 view 内单独观测
    // chat.messages 高频变化（>5 条/秒）不再触发 PartyRoomView body 重算 → 麦位区/视频区稳定

    @Environment(\.dismiss) private var dismiss
    /// v5.3.3 真根因坑：SwiftUI 在 ScenePhase=.background 时也会调度 onDisappear（snapshot 用），
    /// 必须双守卫（scenePhase != .background + state != .joined/.entering）防误退房。
    @Environment(\.scenePhase) private var scenePhase
    @State private var inputText: String = ""
    @State private var showSelfActions: Bool = false
    @State private var showError: Bool = false
    /// 守卫：onAppear 只触发一次进房（PartyRoomView 一次性进入；pop 后销毁，不会 re-appear）
    @State private var didStartEnter: Bool = false
    /// P2-10：sortedSeats 缓存，仅在 store.seatList 真正变化时重算（onChange 触发）
    /// 避免 body 内 computed property 每次重算都 O(n log n) 排序
    @State private var sortedSeatsCache: [PartyRoomSeat] = []

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            header
            seatGrid
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
            Divider()
            // P1-6：抽子 view 切断 chat 维度失效——chat.messages / chat.onlineCount 高频变化不再波及麦位区
            // 注：store.lastGiftEvent 仍在父 body 内被参数读取，礼物到达时父 body 会重 evaluate（频率低，且 P1-8 已让 cell re-init 极廉价）
            PartyMessageListView(chat: store.chat, lastGiftEvent: store.lastGiftEvent)
            inputBar
        }
        .navigationBarBackButtonHidden(true)
        .toolbar { ToolbarItem(placement: .navigationBarLeading) { EmptyView() } }
        // 用 .onAppear + 独立 Task（脱离 view lifecycle），避免父 view re-evaluate
        // 触发 .task cancellation 导致 URLSession 抛 -999 cancelled（PartyRoomView 是叶子页面，
        // pop 后销毁不会 re-appear，didStartEnter 守卫一次即可）
        .onAppear {
            // 长时间无操作自动离线：派对房中暂停监测（对齐 H5 isBusy 停 timer）
            AutoOfflineMonitor.shared.suspend()
            // P2-10：onAppear 同步 cache 一次仅作为"上次会话残留"兜底
            // —— enterRoom() 是同帧异步 Task，首次进入时 store.seatList 通常为 [] → 该行为 no-op；
            // 后续真值靠 .onChange(of: store.seatList) 在 enterRoom 写入后填充
            sortedSeatsCache = store.seatList.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }
            guard !didStartEnter else { return }
            didStartEnter = true
            Task { await ensureEntered() }
        }
        // P2-10：seatList 变化时一次性重排，避免 body 重算时每次都 O(n log n) 排序
        .onChange(of: store.seatList) { newList in
            sortedSeatsCache = newList.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }
        }
        .onDisappear {
            // v5.3.3 真根因双守卫：(1) scenePhase != .background 防切后台误退房（系统 snapshot 也调 onDisappear）；
            // (2) 仅当处于活跃房态时才 leave，避免重复退房。真正退房路径仍走顶栏 ✕ 按钮显式调 leaveRoom。
            guard scenePhase != .background else { return }
            // 长时间无操作自动离线：与 onAppear.suspend 配对
            AutoOfflineMonitor.shared.resume()
            if store.roomState == .joined || store.roomState == .entering {
                Task { await store.leaveRoom() }
            }
        }
        // 视频位邀请弹窗（spec §1.4.4 仅接被邀响应）
        .alert(L10n.Party.inviteTitle, isPresented: invitePresented) {
            Button(L10n.Party.inviteAccept) { Task { await store.acceptVideoSeatInvite() } }
            Button(L10n.Party.inviteReject, role: .cancel) { Task { await store.rejectVideoSeatInvite() } }
        } message: {
            if let i = store.pendingVideoSeatInvite {
                Text(String(format: L10n.Party.inviteMessageFormat, i.fromNickname ?? L10n.Party.defaultUser, i.seatIndex))
            }
        }
        // 错误 toast
        .alert(L10n.Party.alertTitle, isPresented: $showError) {
            Button(L10n.Party.ok) { store.clearLastError() }
        } message: {
            Text(store.lastError?.errorDescription ?? "")
        }
        .onChange(of: store.lastError?.errorDescription ?? "") { msg in
            showError = !msg.isEmpty
        }
        // 自己点麦位 sheet
        .confirmationDialog(L10n.Party.selfActionsTitle, isPresented: $showSelfActions) {
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
    }

    // MARK: - 顶栏

    /// P1-6：header 抽子 view，chat 由本子 view 观测；顶层 PartyRoomView 不再持 chat 引用
    private var header: some View {
        PartyRoomHeaderView(
            roomName: store.roomInfo?.roomName ?? L10n.Party.defaultRoomName,
            chat: store.chat,
            roomState: store.roomState,
            onLeave: {
                Task {
                    await store.leaveRoom()
                    dismiss()
                }
            }
        )
    }

    // MARK: - 麦位网格

    private var seatGrid: some View {
        // P1-8：cell 改为参数注入，不再 @ObservedObject store；
        // 在父 view 一次性提取需要的字段下发，避免 9-12 个 cell × 11 个 @Published 字段的失效风暴
        LazyVGrid(columns: columns, spacing: 14) {
            // P1-5：用 stableId（seatIndex 衍生，麦位号 1-13 唯一），避免 PartyRoomSeat.id String? 多 nil 时 Identity 坍缩 → PartyRemoteVideoView 远端黑屏
            ForEach(sortedSeats, id: \.stableId) { seat in
                PartySeatItemView(
                    seat: seat,
                    isSelf: isSelf(seat),
                    isLocalCameraActive: store.isLocalCameraActive,
                    camera: store.camera,
                    engine: store.rtc
                )
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, 12)
    }

    /// P2-10：sortedSeats 用 @State 缓存 + onChange 触发；避免 body 重算时全量 O(n log n) 排序 + 数组拷贝
    private var sortedSeats: [PartyRoomSeat] {
        // 实际渲染走 @State sortedSeatsCache（line 见 onChange 钩子）
        sortedSeatsCache
    }

    private func isSelf(_ seat: PartyRoomSeat) -> Bool {
        guard let me = store.myUserIdString else { return false }
        return seat.userId == me
    }

    private func handleSeatTap(_ seat: PartyRoomSeat) {
        // 自己已在麦：弹自己操作 sheet
        if isSelf(seat) {
            showSelfActions = true
            return
        }
        // 自己未在麦 + 该位空：尝试上麦
        if store.selfSeat == nil, !seat.occupied, let idx = seat.seatIndex {
            Task { await store.requestOnSeat(seatIndex: idx) }
            return
        }
        // 他人已占位：MVP 不弹管理操作（推 F 期）
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(L10n.Party.inputPlaceholder, text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendText)
            Button {
                sendText()
            } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 18))
            }
            Button {
                sendDemoGift()
            } label: {
                Image(systemName: "gift.fill").font(.system(size: 18)).foregroundColor(.pink)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
    }

    private func sendText() {
        let txt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !txt.isEmpty, store.roomState == .joined else { return }
        store.chat.sendText(txt)  // P1-6：通过 store 拿 chat 实例，避免顶层观测
        inputText = ""
    }

    /// 送礼骨架：固定 demo giftId=1 num=1 → 当前在麦的第一个非自己用户。
    /// `yxAccidList` 必须用 `yxAccid`（云信 accid），不是 `userId`。
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

    // MARK: - 状态机入口

    private var invitePresented: Binding<Bool> {
        Binding(
            get: { store.pendingVideoSeatInvite != nil },
            set: { if !$0 { store.clearPendingVideoSeatInvite() } }
        )
    }

    private func ensureEntered() async {
        if store.roomState == .joined, store.roomInfo?.id == roomId { return }
        if store.roomState != .idle, store.roomState != .ended {
            // 残留房不一致 → 先清
            await store.forceLeaveRoom(.userRequest)
        }
        await store.enterRoom(roomId: roomId)
    }
}
