import SwiftUI

/// 直播间（对应 H5 liveRoom）：声网推流 + LiveStore 接管心跳/下播状态机 + 云信公屏。
///
/// M1：LiveStore 接管心跳（10s）与 forceEnd/endLive；
/// M2：注入相机错误回调 / 美颜降级通知 / 权限拒绝 alert / 网络监控转发（store.wire(agora)）；
/// M3：公屏/在线人数迁移到 LiveStore。
struct LiveRoomView: View {
    let roomInfo: LiveRoomInfo
    let title: String
    @ObservedObject var beauty: BeautyParameters

    @StateObject private var store = LiveStore()
    @StateObject private var camera = CameraManager()
    @StateObject private var agora = AgoraManager()
    @StateObject private var nim = NIMChatroomManager()
    /// D 里程碑：监听 CallStore 状态，直播态收到私 call 时用 CallView overlay 覆盖直播画面。
    /// 对齐 H5 g-faceTime 全局浮层模式。RootView 的 ZStack 浮层在 sheet 内不可见，必须在
    /// LiveRoomView 内自己 overlay。
    @ObservedObject private var callStore = CallStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var authorized = false
    @State private var showBeauty = false
    @State private var elapsed = 0

    // ⚠️ G 里程碑 M0 临时调试入口（PR 前删除）：手动加入/离开对手 PK 频道，验证 joinChannelEx 通路
    @State private var showPKDebug = false
    @State private var pkDebugChannel = ""
    @State private var pkDebugOppositeUid = ""
    @State private var pkDebugMessage = ""

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if authorized {
                CameraPreview(camera: camera, agora: agora).ignoresSafeArea()
            }
            VStack(spacing: 12) {
                topBar
                debugNetworkPanel    // v5.1 调试面板（弱网计数实时显示）
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
                publicScreen
                Spacer()
                bottomBar
            }
            .padding()
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showBeauty) { beautyPanel }
        .sheet(isPresented: $showPKDebug) { pkDebugPanel }   // ⚠️ M0 调试入口（PR 前删除）
        .alert(L10n.liveRoomPermissionAlertTitle, isPresented: $store.permissionDeniedAlert) {
            Button(L10n.liveRoomPermissionAlertOK) { dismiss() }
        } message: {
            Text(L10n.liveRoomPermissionAlertMessage)
        }
        .onAppear {
            camera.renderer.updateParameters(beauty)
            // M2：相机错误转发到 store
            camera.onError = { error in
                Task { @MainActor in store.onCameraError(error) }
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
                nim.enter(roomId: "\(yx)",
                          nickname: user.nickname ?? L10n.liveRoomAnchorDefault,
                          account: user.yxAccid ?? "",
                          token: user.imToken ?? "")
            }
            store.attachLiving(roomInfo: roomInfo)
            // D 里程碑：注入 LiveStore 给 CallStore + 挂 observer（直播态期间直播私 call 接听 +
            // 通话挂断后 resumeCall 回直播的协议入口）。weak 引用，LiveRoomView 销毁时自动清理。
            CallStore.shared.liveStore = store
            CallStore.shared.observer = store
        }
        .onDisappear {
            // v5.3.3 真根因修复：SwiftUI 在 ScenePhase=.background 时也会触发 onDisappear（snapshot 用），
            // 若此时 tearDown camera/agora/nim，则切后台→回前台后帧分发永久断开（v5.8 已用 subscribers
            // 字典让每个 CameraPreview 独立注销，仍以"真正 dismiss 才清理"为正路径）。
            // 真正 dismiss 的标志：scenePhase != .background（不是切后台）+ store.state == .ended（forceEnd/endLive 完成）。
            guard scenePhase != .background, store.state == .ended else {
                return
            }
            camera.tearDown()
            // D 里程碑修复（v5.4）：agora.leave 改 async，onDisappear 不是 async 上下文，
            // 包 Task 让出；nim.leave 与 camera.stop 同步走，不依赖 agora 完成。
            Task { await agora.leave() }
            nim.leave()
            camera.stop()
        }
        .onChange(of: store.state) { newState in
            if newState == .ended { dismiss() }
        }
        // v5.8：本体 CameraPreview 的帧 sink 由 CameraManager.subscribers 字典持有，
        // 与 PIP CameraPreview 的 sink 独立共存；PIP 在 dismantleUIView 时精准注销自己那一格，
        // 本体不再依赖任何 SwiftUI re-eval 时机。详见 Sources/Camera/CameraPreview.swift v5.8 注释。
        .onReceive(beauty.objectWillChange) { _ in
            DispatchQueue.main.async { camera.renderer.updateParameters(beauty) }
        }
        .onReceive(ticker) { _ in
            guard agora.state == .joined else { return }
            elapsed += 1
        }
        // D 里程碑：直播态期间收到私 call → CallView 顶层 overlay 覆盖直播画面。
        // 对齐 H5 g-faceTime 浮层模式。state != .idle 时显示（含 .calling/.connecting/.connected/.ended 过渡态）。
        .overlay {
            if callStore.state != .idle {
                // D 里程碑修复（v5.4）：注入直播侧 camera/beauty 复用同一路采集，
                // 避免 CallFaceTimeView 自启第二个 CameraManager 实例抢占摄像头 →
                // reason=3 → 20s watcher → forceEnd endType=5 误下播；同时保留主播美颜参数。
                CallView(store: callStore, liveCamera: camera, liveBeauty: beauty)
                    .transition(.opacity)
            }
        }
        // D 里程碑：通话挂断后 15s 倒计时覆盖层（对齐 H5 liveRoom.vue:218-227 waitingReturnLive）。
        // CallView overlay 在 callStore.state→.ended/.idle 后消失，本覆盖层接力显示倒计时直到 rejoinLive。
        .overlay {
            if store.isWaitingReturnLive {
                returnLiveCountdownOverlay.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: callStore.state)
        .animation(.easeInOut(duration: 0.2), value: store.isWaitingReturnLive)
    }

    // MARK: - D 里程碑：挂断后回直播倒计时覆盖层

    /// v5.6 修订（用户反馈"返回直播后画面卡住"）：
    /// 原全屏黑色 70% 遮罩会盖住本端 CameraPreview，体感等同"画面冻结 15s"。
    /// 改为顶部胶囊提示条：本端摄像头持续可见（CameraManager 一直采集 + render），
    /// 业务上 15s 仍不推流（liveAgora.state=.idle → pushFrame guard 拦截），观众端断流窗口不变。
    private var returnLiveCountdownOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.caption)
                Text(L10n.liveRoomCallEndedTitle).font(.caption).bold()
                Text(String(format: L10n.liveRoomReturnCountdownFormat, store.returnLiveCountdown))
                    .font(.caption).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.pink.opacity(0.85), in: Capsule())
            .padding(.top, 80)
            Spacer()
        }
    }

    // MARK: - 顶部主播信息栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle().fill(.pink.opacity(0.6)).frame(width: 40, height: 40)
                .overlay(Image(systemName: "person.fill").foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold().foregroundStyle(.white).lineLimit(1)
                Text(agora.message.isEmpty ? agora.state.rawValue : agora.message)
                    .font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(agora.state == .joined
                     ? String(format: L10n.liveRoomStatusLiveFormat, timeString)
                     : L10n.liveRoomStatusConnecting)
                    .font(.caption).foregroundStyle(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.caption2)
                Text("\(nim.onlineCount)").font(.caption)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
        }
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

    // MARK: - 网络监控调试面板（v5.1，弱网计数实时显示）

    private var debugNetworkPanel: some View {
        let info = store.networkDebugInfo
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

    // MARK: - 网络弱网降级条幅（NetworkQualityMonitor 触发，恢复时自动消失）

    private func networkBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark").font(.caption)
            Text(text).font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .center)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - 公屏消息

    private var publicScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(nim.messages.suffix(6)) { msg in
                Text(msg.text)
                    .font(.caption)
                    .foregroundStyle(msg.isSystem ? .yellow.opacity(0.9) : .white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部工具栏

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button { showBeauty = true } label: { toolButton(L10n.liveRoomToolBeauty, system: "wand.and.stars") }
                .disabled(!store.beautyAvailable)
            // ⚠️ G 里程碑 M0 临时入口（PR 前删除）
            Button { showPKDebug = true } label: { toolButton("PK", system: "person.2.fill") }
            Spacer()
            Button {
                Task { await store.endLive() }
            } label: {
                Text(L10n.liveRoomEndLive).font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Color.red, in: Capsule())
            }
        }
    }

    // MARK: - G 里程碑 M0 调试面板（PR 前删除）

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
        .presentationDetents([.medium])
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

    private func toolButton(_ t: String, system: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: system).font(.title3)
            Text(t).font(.caption2)
        }
        .foregroundStyle(.white)
        .frame(width: 56, height: 56)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 美颜面板

    private var beautyPanel: some View {
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
        .presentationDetents([.medium])
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

    private var timeString: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}
