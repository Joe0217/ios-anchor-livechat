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
        .alert("相机权限未开启", isPresented: $store.permissionDeniedAlert) {
            Button("确定") { dismiss() }
        } message: {
            Text("请到 设置 → Hily → 相机 中允许访问")
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
                          nickname: user.nickname ?? "主播",
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
            // 若此时 tearDown camera/agora/nim，则切后台→回前台后 onFrame 永久断开（CameraPreview.updateUIView
            // 虽已兜底重绑，但仍以"真正 dismiss 才清理"为正路径）。
            // 真正 dismiss 的标志：scenePhase != .background（不是切后台）+ store.state == .ended（forceEnd/endLive 完成）。
            guard scenePhase != .background, store.state == .ended else {
                return
            }
            camera.tearDown()
            agora.leave()
            nim.leave()
            camera.stop()
        }
        .onChange(of: store.state) { newState in
            if newState == .ended { dismiss() }
        }
        // D 里程碑：直播态 → 通话态切换时让出/恢复相机硬件（避免双 CameraManager 实例同时
        // 占用 AVCaptureSession 冲突）。callState=1 时 stop，callState=0（resumeCall 倒计时归 0）
        // 时 start 恢复直播预览。
        .onChange(of: store.callState) { newCallState in
            if newCallState == 1 {
                camera.stop()
            } else if newCallState == 0 {
                if authorized { camera.start() }
            }
        }
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
                CallView(store: callStore)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: callStore.state)
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
                Text(agora.state == .joined ? "直播中 \(timeString)" : "连接中…")
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
            Button { showBeauty = true } label: { toolButton("美颜", system: "wand.and.stars") }
                .disabled(!store.beautyAvailable)
            Spacer()
            Button {
                Task { await store.endLive() }
            } label: {
                Text("结束直播").font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Color.red, in: Capsule())
            }
        }
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
            Text("美颜").font(.headline)
            Toggle("美颜开关", isOn: $beauty.enabled).tint(.pink)
            sheetSlider("磨皮", value: $beauty.blur)
            sheetSlider("美白", value: $beauty.whiten)
            sheetSlider("大眼", value: $beauty.eyeEnlarge)
            sheetSlider("瘦脸", value: $beauty.faceThin)
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
