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
    @ObservedObject private var chat = PartyStore.shared.chat

    @Environment(\.dismiss) private var dismiss
    @State private var inputText: String = ""
    @State private var showSelfActions: Bool = false
    @State private var showError: Bool = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            header
            seatGrid
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
            Divider()
            messageList
            inputBar
        }
        .navigationBarBackButtonHidden(true)
        .toolbar { ToolbarItem(placement: .navigationBarLeading) { EmptyView() } }
        .task { await ensureEntered() }
        .onDisappear {
            if store.roomState == .joined || store.roomState == .entering {
                Task { await store.leaveRoom() }
            }
        }
        // 视频位邀请弹窗（spec §1.4.4 仅接被邀响应）
        .alert("视频位邀请", isPresented: invitePresented) {
            Button("接受") { Task { await store.acceptVideoSeatInvite() } }
            Button("拒绝", role: .cancel) { Task { await store.rejectVideoSeatInvite() } }
        } message: {
            if let i = store.pendingVideoSeatInvite {
                Text("\(i.fromNickname ?? "用户") 邀请你上视频位 \(i.seatIndex)")
            }
        }
        // 错误 toast
        .alert("提示", isPresented: $showError) {
            Button("好的") { store.clearLastError() }
        } message: {
            Text(store.lastError?.errorDescription ?? "")
        }
        .onChange(of: store.lastError?.errorDescription ?? "") { msg in
            showError = !msg.isEmpty
        }
        // 自己点麦位 sheet
        .confirmationDialog("我的麦位", isPresented: $showSelfActions) {
            if let me = store.selfSeat {
                let micOn = (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
                Button(micOn ? "关麦克风" : "开麦克风") {
                    Task { await store.toggleSelfMedia(type: 1, enable: !micOn) }
                }
                if me.seatType == 1 {
                    let camOn = (me.cameraEnabled ?? 0) == 1
                    Button(camOn ? "关摄像头" : "开摄像头") {
                        Task { await store.toggleSelfMedia(type: 2, enable: !camOn) }
                    }
                }
                Button("下麦", role: .destructive) {
                    Task { await store.requestDownSeat() }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.roomInfo?.roomName ?? "派对房")
                    .font(.system(size: 16, weight: .semibold))
                Text("在线 \(store.onlineUserCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            stateBadge
            Button {
                Task {
                    await store.leaveRoom()
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
    }

    private var stateBadge: some View {
        let label: String
        let color: Color
        switch store.roomState {
        case .joined:
            label = "已进房"
            color = .green
        case .entering, .preparing:
            label = "进房中…"
            color = .orange
        case .leaving:
            label = "退房中…"
            color = .orange
        case .ended:
            label = "已离开"
            color = .secondary
        case .idle:
            label = "—"
            color = .secondary
        }
        return Text(label)
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
    }

    // MARK: - 麦位网格

    private var seatGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(sortedSeats, id: \.id) { seat in
                PartySeatItemView(seat: seat, isSelf: isSelf(seat), store: store)
                    .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, 12)
    }

    private var sortedSeats: [PartyRoomSeat] {
        store.seatList.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }
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

    // MARK: - 公屏

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(chat.messages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    // 送礼事件落公屏（仅最近一条占位）
                    if let g = store.lastGiftEvent {
                        Text("🎁 \(g.senderNickname ?? "用户") 送出 \(g.giftName ?? "礼物") x\(g.num)")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 12)
                            .id("gift_\(g.timestamp)")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: chat.messages.count) { _ in
                if let last = chat.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func messageRow(_ msg: PartyChatMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if let n = msg.nickname, !n.isEmpty {
                Text("\(n):")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(msg.role == .owner ? .orange : .blue)
            }
            Text(msg.text).font(.system(size: 13))
            Spacer(minLength: 0)
            if msg.isLocal {
                Image(systemName: "clock").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("说点什么…", text: $inputText)
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
        chat.sendText(txt)
        inputText = ""
    }

    /// 送礼骨架：固定 demo giftId=1 num=1 → 当前在麦的第一个非自己用户。
    /// 若无可送目标 → 弹 toast。
    private func sendDemoGift() {
        guard let info = store.roomInfo else { return }
        let target = store.seatList.first { seat in
            guard let uid = seat.userId, !uid.isEmpty else { return false }
            return uid != store.myUserIdString
        }
        guard let targetUid = target?.userId else {
            AppLogger.party.notice("[PartyRoom] no gift target; skip")
            return
        }
        Task {
            do {
                _ = try await PartyAPI.sendGift(
                    roomId: info.id ?? "",
                    giftId: 1,
                    num: 1,
                    yxAccidList: [targetUid]
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
