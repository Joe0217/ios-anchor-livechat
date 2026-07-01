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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if authorized {
                CameraPreview(camera: camera, agora: agora).ignoresSafeArea()
            }
            // G M3 / spec §6.1：PKArenaView 跨 .starting/.inPK/.punishing 三态用 if 链承载（铁律 §1）；
            // .id("pkArena") 锁 identity 避免 dismantleUIView 反复触发 → AgoraRtcVideoCanvas.view 黑屏。
            // 本端 CameraPreview 不在内重建（铁律 §3）；PKArenaView 仅占右半边盖对手画面。
            if pkStore.state == .starting || pkStore.state == .inPK || pkStore.state == .punishing {
                PKArenaView(store: pkStore, agora: agora)
                    .id("pkArena")
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            VStack(spacing: 12) {
                topBar
                // 独立 ObservableObject，仅本子 view 订阅；高频（2s/次）写不波及 LiveRoomView 整树
                DebugNetworkPanel(debugStore: store.networkDebugStore)
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
        #if DEBUG
        .sheet(isPresented: $showPKDebug) { pkDebugPanel }   // M0 调试入口（仅 DEBUG）
        #endif
        .sheet(isPresented: $showInviteSheet) {
            PKInviteSheet(store: pkStore, isPresented: $showInviteSheet)
        }
        // G M3 / spec §6.1：PK 各态 overlay 合并为单一 PKOverlayHost，避免 5 层 _OverlayModifier
        // 链路 layout pass + 多 overlay 同时订阅 pkStore 触发 body 重算。
        .overlay { PKOverlayHost(pkStore: pkStore, resultBridge: pkResultBridge) }
        .overlay(alignment: .bottomTrailing) {
            PKEntryButton(store: pkStore, showInviteSheet: $showInviteSheet)
                .padding(.trailing, 12)
                .padding(.bottom, 110)        // 让出 bottomBar 高度
        }
        .animation(.easeInOut(duration: 0.2), value: pkStore.state)
        .alert(L10n.liveRoomPermissionAlertTitle, isPresented: $store.permissionDeniedAlert) {
            Button(L10n.liveRoomPermissionAlertOK) { dismiss() }
        } message: {
            Text(L10n.liveRoomPermissionAlertMessage)
        }
        .onAppear {
            camera.renderer.updateParameters(beauty)
            // M2：相机错误转发到 store
            // v5.11 真根因修复：CameraManager 的 onError 3 处调用点全在 DispatchQueue.main.async 内，
            // 已保证 wasInterrupted → interruptionEnded 的 FIFO 派发顺序；此处用 Task { @MainActor in }
            // 二次包装会把 start/stopWatcher 拆到两个独立 Task 排队等 MainActor executor，
            // Swift Task 调度非严格 FIFO → 反序时 stopWatcher 先跑（无操作）后 startWatcher 起孤儿 watcher，
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
            // 进房同步远端 PK 状态（H5 syncPkStateAfterReconnect 同行为）
            Task { await pkStore.reconcileOnReconnect() }
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
            NIMService.shared.unregisterRouter(pkStore.router)
            SystemMessageRouter.shared.liveStore = nil
            // G M3：PKStore teardown 取消倒计时 / 解 NQM 订阅 / 清字段；setCallState 内部 guard 会拦 ended 态调用
            Task { await pkStore.teardown() }
        }
        .onChange(of: store.state) { newState in
            if newState == .ended { dismiss() }
        }
        // v5.8：本体 CameraPreview 的帧 sink 由 CameraManager.subscribers 字典持有，
        // 与 PIP CameraPreview 的 sink 独立共存；PIP 在 dismantleUIView 时精准注销自己那一格，
        // 本体不再依赖任何 SwiftUI re-eval 时机。详见 Sources/Camera/CameraPreview.swift v5.8 注释。
        // 美颜参数变化 → renderer 更新已下沉到 BeautyPanel 子 view（throttle 60ms），父 view 不再监听
        // 直播时长由 LiveStore.elapsedTimerStore 在 attachLiving/teardown 内自管启停；
        // 时间 capsule 通过独立 LiveElapsedCapsule 子 view 订阅，避免 1Hz 触发本树重渲染。
        // D 里程碑：直播态期间收到私 call → CallView 顶层 overlay 覆盖直播画面。
        // 对齐 H5 g-faceTime 浮层模式。state != .idle 时显示（含 .calling/.connecting/.connected/.ended 过渡态）。
        .overlay {
            if callState != .idle {
                // D 里程碑修复（v5.4）：注入直播侧 camera/beauty 复用同一路采集，
                // 避免 CallFaceTimeView 自启第二个 CameraManager 实例抢占摄像头 →
                // reason=3 → 20s watcher → forceEnd endType=5 误下播；同时保留主播美颜参数。
                CallView(store: callStore, liveCamera: camera, liveBeauty: beauty)
                    .transition(.opacity)
            }
        }
        // D 里程碑：通话挂断后 15s 倒计时覆盖层（对齐 H5 liveRoom.vue:218-227 waitingReturnLive）。
        // CallView overlay 在 callState→.ended/.idle 后消失，本覆盖层接力显示倒计时直到 rejoinLive。
        .overlay {
            if store.isWaitingReturnLive {
                returnLiveCountdownOverlay.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: callState)
        .onReceive(callStore.$state) { newState in callState = newState }
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
                    .accessibilityHidden(true)
                Text(L10n.liveRoomCallEndedTitle).font(.caption).bold()
                Text(String(format: L10n.liveRoomReturnCountdownFormat, store.returnLiveCountdown))
                    .font(.caption).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.pink.opacity(0.85), in: Capsule())
            .padding(.top, 80)
            .accessibilityElement(children: .combine)
            Spacer()
        }
    }

    // MARK: - 顶部主播信息栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle().fill(.pink.opacity(0.6)).frame(width: 40, height: 40)
                .overlay(Image(systemName: "person.fill").foregroundStyle(.white))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold().foregroundStyle(.white).lineLimit(1)
                Text(agora.message.isEmpty ? agora.state.label : agora.message)
                    .font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            Spacer()
            // 时间 capsule：joined 时显示 elapsed 时长（独立 store 隔离 1Hz 写）；
            // 未 joined 显示 "Connecting…"——这一态由父 view 的 agora.state 触发 re-eval（极低频）。
            if agora.state == .joined {
                LiveElapsedCapsule(timerStore: store.elapsedTimerStore)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(L10n.liveRoomStatusConnecting)
                        .font(.caption).foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
            }
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.caption2)
                    .accessibilityHidden(true)
                // review 202606260029 P1-1：onlineCount 抽到子 view 内观测，
                // 避免本体 LiveRoomView 因 .enter/.exit 通知频繁重算（含 CameraPreview / RemoteVideoView）。
                OnlineCountText(store: nim.presenceStore)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
            .accessibilityElement(children: .combine)
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

    // MARK: - 公屏消息

    private var publicScreen: some View {
        PublicScreenList(store: nim.messagesStore)
    }

    // MARK: - 底部工具栏

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button { showBeauty = true } label: { toolButton(L10n.liveRoomToolBeauty, system: "wand.and.stars") }
                .disabled(!store.beautyAvailable)
            #if DEBUG
            // G 里程碑 M0 临时入口（仅 DEBUG，release 不带）
            Button { showPKDebug = true } label: { toolButton("PK", system: "person.2.fill") }
            #endif
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
    #endif

    private func toolButton(_ t: String, system: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: system).font(.title3)
                .accessibilityHidden(true)
            Text(t).font(.caption2)
        }
        .foregroundStyle(.white)
        .frame(width: 56, height: 56)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - 美颜面板

    private var beautyPanel: some View {
        BeautyPanel(beauty: beauty, camera: camera)
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
        .presentationDetents([.medium])
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

// MARK: - 网络监控调试面板（v5.1，弱网计数实时显示）
// 独立子 view + 独立 NetworkDebugStore：高频 2s/次的网络计数变化只触发本 view body re-eval，
// 不再影响 LiveRoomView 主树（详见 LiveStore.networkDebugStore）。

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

// MARK: - PublicScreenList：独立订阅 ChatMessagesStore，append 不波及 LiveRoomView
//
// LiveRoomView 顶层 `@StateObject nim` 仍存在，但 messages 字段已迁出到 ChatMessagesStore；
// 本 view 直接订阅 messagesStore，消息 publish 仅触发本子 view 重算，topBar / PKOverlayHost /
// CameraPreview / DebugNetworkPanel 等兄弟子树不受影响（review P1-3）。
private struct PublicScreenList: View {
    @ObservedObject var store: ChatMessagesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.messages.suffix(6)) { msg in
                Text(msg.text)
                    .font(.caption)
                    .foregroundStyle(msg.isSystem ? .yellow.opacity(0.9) : .white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// review 202606260029 P1-1：onlineCount 子 view 内观测。
/// 父 view 顶层不读 `nim.presenceStore.onlineCount`，避免 .enter/.exit 通知触发整树重算。
private struct OnlineCountText: View {
    @ObservedObject var store: ChatPresenceStore

    var body: some View {
        Text("\(store.onlineCount)").font(.caption)
    }
}
