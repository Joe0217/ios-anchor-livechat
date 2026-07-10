import SwiftUI
import UIKit  // C-4 Wave1 gap-critic-011：UIImpactFeedbackGenerator / UINotificationFeedbackGenerator

/// 1v1 通话主视图：根据 CallStore.state 在 waiting / faceTime 两态切换。
///
/// happy path UI 骨架：
/// - `.calling + .out` → CallWaitingView（主叫等接听）
/// - `.calling + .in`  → CallWaitingView（被叫等用户决策）
/// - `.connecting / .connected` → CallFaceTimeView（已接通）
/// - `.ended / .idle` → 由父视图（RootView）自行隐藏
///
/// 业务上由 RootView 监听 `CallStore.shared.state != .idle` 决定是否覆盖显示本视图。
struct CallView: View {
    @ObservedObject var store: CallStore
    /// D 里程碑修复（v5.4）：直播私 call 场景由 LiveRoomView 注入直播侧的 camera/beauty，
    /// CallFaceTimeView 复用同一路 AVCaptureSession，避免双 CameraManager 实例抢占前置摄像头
    /// → reason=3 → 20s watcher → forceEnd(endType=5) 误下播；同时保留主播美颜参数。
    /// 非直播态（独立 1v1）保持 nil，CallFaceTimeView 走 `CallFaceTimeFallbackHolder` lazy 路径。
    var liveCamera: CameraManager? = nil
    var liveBeauty: BeautyParameters? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            bodyContent
            // H M4 HUD：sysMsg → CallStore 5 publishers 的可视化
            CallHudOverlay(store: store).allowsHitTesting(false)
            // C 里程碑：弱网 toast 顶部提示（2s 自消，2s 冷却）
            CallNetworkToast(store: store).allowsHitTesting(false)
            // 拨打失败结束原因 toast（对方拒绝 / 无应答 / 正忙 / createCall 失败等）
            // 触发：CallStore.lastError 非空（handleRemoteReject / callOutTimeout / callOut 各失败分支 set）
            // 展示 1.5s 自消；与 scheduleEndedToIdle 1.8s 延迟配合，保证 CallView dismiss 前完整展示
            CallEndReasonToast(store: store).allowsHitTesting(false)
            // C-5 gap-011：充值锁定顶部提示（type=1/3 时叠加）
            if store.isCallWaitLocked {
                CallWaitRechargeTips(store: store)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // DM-20260616-003：黑屏空房间检测倒计时弹窗（对齐 H5 emptyRoomCountdownPop.vue）
            // 不可取消，走满 10s 触发自动挂断（detector 内部逻辑）
            if let remaining = store.emptyRoomCountdownRemaining {
                CallEmptyRoomCountdownOverlay(remaining: remaining)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: store.isCallWaitLocked)
        // C-4 Wave1 gap-critic-011：warning haptic 触发点（弱网 toast + 异常 alert 出现时）
        .onChange(of: store.weakNetworkToastToken) { newValue in
            if newValue != nil { CallHaptics.warning() }
        }
        .onChange(of: store.callAbnormalReason) { newValue in
            if newValue != nil { CallHaptics.warning() }
        }
        // C-5 gap-012：PAY_SUCCESS 2s 后弹 Congrats sheet（token 变化 driven）
        .sheet(isPresented: Binding(
            get: { store.congratsBonusToken != nil },
            set: { if !$0 { store.dismissCongratsBonus() } }
        )) {
            CongratsBonusSheet(bonus: store.lastCongratsBonus) {
                store.dismissCongratsBonus()
            }
            .sheetTopInset()
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
        }
        // Task 10：声明本 view 属于 GiftEffect .call 场景 —— onAppear 时 setActiveScene，onDisappear 时 leaveScene（硬中断+清队列）
        .giftEffectScene(.call, scopeId: store.current.callId ?? "")
    }

    /// v5.5 修复（Bug A/B 同源根因）：消除 switch case 跨分支重建 CallFaceTimeView。
    /// 直播私 call（frontGameType==.live）从 .calling → .connecting → .connected 全程落在同一 if
    /// 分支，CallFaceTimeView 的 view identity 稳定 → CameraPreview / RemoteVideoView 不再被
    /// SwiftUI dismantleUIView + 重建 → MetalPreviewView 实例稳定（onFrame 闭包目标不空窗）
    /// + AgoraRtcVideoCanvas.view 引用稳定（远端首帧到达时 layer 就绪 → 不黑屏）。
    /// 独立 1v1（frontGameType != .live）保留 Waiting → FaceTime 切换（无前置画面要保持）。
    @ViewBuilder
    private var bodyContent: some View {
        if store.state == .calling, store.current.frontGameType != .live {
            CallWaitingView(store: store)
        } else if store.state == .calling || store.state == .connecting || store.state == .connected {
            CallFaceTimeView(store: store, agora: store.agora, liveCamera: liveCamera, liveBeauty: liveBeauty)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Waiting：拨号中 / 来电中

private struct CallWaitingView: View {
    @ObservedObject var store: CallStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 对方头像 / 名字
            RemoteAvatar(icon: store.current.remoteIcon,
                         nickname: store.current.remoteNickname,
                         headFrame: store.current.remoteHeadFrame)

            Text(store.current.remoteNickname.isEmpty ? store.current.remoteUserIdString : store.current.remoteNickname)
                .font(.title2).foregroundStyle(.white)

            Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.75))

            // 圆环倒计时（主叫 30s）：elapsed 走 CallStore.callElapsed（统一收敛，避免 view 内 Timer.publish 后台 backlog）
            if store.current.inOrOut == .out {
                CountdownRing(elapsed: store.callElapsed, total: Int(CallTuning.callOutTimeoutSeconds))
                    .frame(width: 80, height: 80)
                    .padding(.top, 8)
            }

            Spacer()

            buttons.padding(.bottom, 40)
        }
        .padding()
    }

    private var subtitle: String {
        store.current.inOrOut == .out ? L10n.callSubtitleCallingOut : L10n.callSubtitleIncoming
    }

    @ViewBuilder private var buttons: some View {
        if store.current.inOrOut == .out {
            CircleButton(systemName: "phone.down.fill", color: .red, label: L10n.callActionCancel) {
                Task { await store.cancel() }
            }
        } else {
            HStack(spacing: 60) {
                CircleButton(systemName: "phone.down.fill", color: .red, label: L10n.callActionReject) {
                    Task { await store.reject() }
                }
                CircleButton(systemName: "phone.fill", color: .green, label: L10n.callActionAccept) {
                    Task { await store.accept() }
                }
            }
        }
    }
}

// MARK: - FaceTime：通话中

private struct CallFaceTimeView: View {
    @ObservedObject var store: CallStore
    /// C-4 Wave4 C 组 gap-010：独立观察 agora.isRemoteVideoOff 变化（agora 是 CallStore 内 `let` 字段，
    /// CallStore 层不 forward，需 view 直接订阅 AgoraManager 才能响应远端 mute/unmute 视频）
    @ObservedObject var agora: AgoraManager
    /// D 里程碑修复（v5.4）：直播私 call 由 CallView 注入直播侧 camera/beauty 复用同一路采集，
    /// 避免双 CameraManager 实例抢占摄像头（reason=3 → 20s watcher → forceEnd endType=5），
    /// 且保留主播原美颜参数。独立 1v1 通话场景保持 nil → 走 fallback 自启动。
    var liveCamera: CameraManager?
    var liveBeauty: BeautyParameters?
    /// 用 holder + lazy 包装：直播私 call 路径下 `liveCamera != nil`，fallback 不会被实例化，
    /// 避免 SwiftUI `@StateObject = CameraManager()` 默认值在 view init 时**立即**调构造器（即使
    /// liveCamera 已提供），导致 AVCaptureSession + Metal renderer + 美颜资源（FURenderKit 100MB+）
    /// 全程多占一份 → 增加 OOM 风险（review P1-1）。
    @StateObject private var fallback = CallFaceTimeFallbackHolder()
    /// review 202607071542 R-3+R-4 修复：SwiftUI 在 ScenePhase=.background 时也会调 onDisappear
    /// （CLAUDE.md v5.3.3 已知坑）。scenePhase 守卫避免切后台误清理。
    @Environment(\.scenePhase) private var scenePhase
    /// C-4 Wave1 gap-001：chrome (topBar + bottomBar + liveCallBanner) 显隐（H5 switchShowAll）
    @State private var isChromeVisible: Bool = true
    /// C-4 Wave1 gap-018：顶部 X 按钮触发的挂断二次确认 confirmationDialog
    @State private var showHangupConfirm: Bool = false
    /// C-4 Wave4 gap-004/005 占位：底部 askForGift / more 按钮点击后 2s 自消的 Coming Soon toast
    @State private var showComingSoonToast: String?
    /// PIP 拖动累计偏移（相对初始 topTrailing 锚点；用户 drag onEnded 后 commit）
    @State private var pipDragOffset: CGSize = .zero
    /// PIP 拖动过程中的临时 translation（gesture 结束自动 reset 到 .zero）
    @GestureState private var pipDragTranslation: CGSize = .zero
    /// 主副视频切换：false = 远端全屏 + 本地 PIP（初始）；true = 本地全屏 + 远端 PIP
    /// tap PIP 那一方 → toggle。极简版：仅 frame/padding/offset/zIndex 参数变化，
    /// RemoteVideoView / CameraPreview 声明位置不变（view identity 稳定，避免 dismantle）。
    /// 参考 rule swiftui-camera-preview.md §2 —— frame 变化触发 updateUIView 而非 dismantleUIView。
    @State private var isLocalMain: Bool = false
    /// Phase C：主播公屏输入框（对齐 H5 sendMessage `showInput` 展开）
    @State private var showChatInput: Bool = false
    /// Phase D：礼物 picker sheet
    @State private var showGiftPicker: Bool = false
    /// Phase D：askForGift 15s 冷却剩余秒数（>0 时按钮 disabled + 显示倒计时；对齐 H5 disableCountdown）
    @State private var askGiftDisableCountdown: Int = 0
    /// Phase E：more 按钮打开的举报 sheet（复用 ReportUserSheet）
    @State private var showReportSheet: Bool = false

    private var camera: CameraManager { liveCamera ?? fallback.camera }
    private var beautyParams: BeautyParameters { liveBeauty ?? fallback.beauty }

    var body: some View {
        ZStack {
            // 远端视频（isLocalMain=false 时全屏；true 时 PIP）
            // - modifier chain 结构不变（frame/padding/offset 参数变化）→ view identity 稳定
            // - tap 分派：main 时 chrome toggle / PIP 时 swap（对齐用户 UX 直觉）
            RemoteVideoView(manager: store.agora)
                .modifier(VideoLayoutModifier(isMain: !isLocalMain,
                                              pipOffset: pipTotalOffset))
                // contentShape 已在 modifier 内 apply（锁定在 PIP 内容 frame），不要在外层再挂
                // Rectangle 覆盖 —— 否则外层全屏 frame 的 hit shape 会让 tap main 区域也命中 PIP。
                .onTapGesture(perform: handleRemoteTap)
                .zIndex(isLocalMain ? 1 : 0)

            // C-4 Wave4 C 组 gap-010 + gap-critic-003：远端摄像头 off fallback（用户端主动关摄时）
            // AgoraManager delegate `remoteVideoStateChangedOfUid` 判定 state==.stopped → isRemoteVideoOff=true
            // 覆盖远端画面 → 显示远端头像 + "Camera off" 让主播明确知道对方主动关摄（非异常）
            if agora.isRemoteVideoOff {
                remoteCameraOffFallback
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // C-4 Wave1 gap-020：进入通话 loading indicator（state=.connecting + remote 未 join 时显示）
            if store.state == .connecting, store.agora.remoteUid == 0 {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)
                    .accessibilityLabel(L10n.callSubtitleCallingOut)
            }

            // C-4 Wave1 gap-001：chrome 层挂 opacity 由 isChromeVisible 控制（点屏切显隐）
            // .allowsHitTesting(isChromeVisible) 隐时按钮不响应，root tap 直穿 → 恢复 chrome
            VStack(spacing: 0) {
                // D 里程碑：直播私 call 顶部提示条（对齐 H5 index.vue:53 `privateCallTips = isLivingCall && streamerCountdown > 0`）
                // 归 0 后 banner 完全消失（H5 v-if="privateCallTips"），主播端只在 5 分钟锁定期内看到收益倒计时提示
                if store.current.frontGameType == .live, store.liveCallCountdown > 0 {
                    liveCallBanner.padding(.top, 12).padding(.horizontal, 16)
                }
                topBar.padding(.top, 12).padding(.horizontal, 16)
                Spacer()
                bottomBar.padding(.bottom, 36)
            }
            .opacity(isChromeVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
            .allowsHitTesting(isChromeVisible)

            // 本地视频（isLocalMain=true 时全屏；false 时 PIP）—— 支持拖动（PIP 状态视觉响应）+ tap 切换
            // - VideoLayoutModifier 内 frame/padding/offset 参数动态化；view identity 稳定
            // - 锁定态 dim overlay 在 PIP 状态下才显示（main 全屏时不 dim）
            // - drag gesture 恒挂；main 状态下 offset 仍应用（视觉微移不明显），swap 到 PIP 时无缝继续
            CameraPreview(camera: camera, agora: store.agora)
                .overlay(cameraPreviewLockOverlay)
                .modifier(VideoLayoutModifier(isMain: isLocalMain,
                                              pipOffset: pipTotalOffset))
                // contentShape 由 modifier 内 apply —— tap 只在 PIP 内容区（110×160）命中，main 时命中全屏
                .onTapGesture(perform: handleLocalTap)
                .gesture(pipDragGesture)
                .zIndex(isLocalMain ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: isLocalMain)
                .animation(.easeInOut(duration: 0.2), value: store.isCallWaitLocked)
                .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.75), value: pipDragOffset)

            // 独立 X 关闭按钮层（不受 PIP 拖动影响；chrome 显隐联动）
            closeButton
                .padding(.top, 12).padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .opacity(isChromeVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
                .allowsHitTesting(isChromeVisible)

            // C-4 Wave4 A1 gap-008：直播私 call 双头像会合动画（H5 livingCallAnimation.vue 1s 旋转 + 2s 消失）
            if store.current.frontGameType == .live {
                LivingCallIntroAnimation(
                    localAvatarURL: SessionStore.shared.user?.icon,
                    remoteAvatarURL: store.current.remoteIcon,
                    token: store.livingCallIntroToken
                )
                .allowsHitTesting(false)
            }

            // C-4 Wave4 gap-002 P0：公屏消息 MessageScroller 骨架（左侧下方 300×270 反向滚动，对齐 H5 g-faceTime index.vue:30-33）
            // 消费 store.callRecentRemoteText（当前只有单条 4s 自消，未来 Wave 6 接 NIM 通话通道扩展为历史队列）
            CallMessageScroller(store: store)
                .frame(width: 270, height: 300)
                .padding(.leading, 12)
                .padding(.bottom, 128)  // 让位底部 bottomBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)

            // C-4 Wave4 Coming Soon toast（askForGift / more 占位按钮点击时显示 2s）
            if let toastText = showComingSoonToast {
                Text(toastText)
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: Capsule())
                    .transition(.opacity)
                    .accessibilityHint(Text(toastText))
            }
        }
        .task(id: showComingSoonToast) {
            guard showComingSoonToast != nil else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showComingSoonToast = nil }
        }
        // tap 切 chrome 显隐已挪到 RemoteVideoView 层 —— 避免与 chrome 内 Button 手势竞争。
        // 原挂 body 最外层的 `.contentShape.onTapGesture` 会抢占 CallBtn* 的 Button 手势 → 三按钮不响应
        // C-4 Wave1 gap-018：顶部 X 按钮触发挂断二次确认
        .confirmationDialog(
            L10n.callHangupConfirmTitle,
            isPresented: $showHangupConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.callAbnormalEndCall, role: .destructive) {
                CallHaptics.impact(.heavy)
                Task { await store.hangup() }
            }
            Button(L10n.callHangupConfirmCancel, role: .cancel) {}
        }
        .onAppear {
            // D 里程碑修复（v5.4）：仅在独立 1v1 通话场景启停相机；
            // 直播私 call 由 LiveRoomView 持有的 camera 连续运行，CallView 仅复用其推流。
            if liveCamera == nil {
                camera.renderer.updateParameters(beautyParams)
                CameraManager.requestAccess { granted in
                    if granted { camera.start() }
                }
            }
            // K 里程碑：attach `.call` token 让 K 页面调过的美颜参数广播到通话 renderer
            // 同一 CameraManager.renderer 多处 attach 时后写覆盖前写（Sharer 幂等）；
            // 直播私 call 场景下 LiveRoomView 已 attach `.live`，此处 attach `.call` 优先级更高（栈顶生效）
            BeautyPipelineSharer.shared.attach(camera.renderer as AnyObject & BeautyRenderer, token: .call)
            BeautyPipelineSharer.shared.reportSetupResult(camera.isBeautyFallback ? .failure(.genericSetupFailed) : .success(()))
            // K 里程碑 P0-3 fix（2026-07-03 review 202607030426）：首帧一致 —— 若 attach 时 Sharer
            // 尚未 ready（setup 首次访问从 .notStarted 变 .ready 时 attach 本身不会 apply），
            // 显式 apply 保证首帧 SDK 参数与 K store 一致，避免 SDK 默认全零 vs UI 显示值不一致。
            camera.renderer.apply(BeautyPipelineSharer.shared.store.settings)
        }
        .onDisappear {
            // review 202607071542 R-4 修复：SwiftUI 在 ScenePhase=.background 时也调 onDisappear（v5.3.3 已知坑）
            // 切后台 detach `.call` token 会让 Sharer 栈顶失效 → K 页面美颜参数丢失；
            // 参考 LiveRoomView.swift:357 同源守卫，仅真 dismiss（挂断 state → .ended/.idle）才清理。
            guard scenePhase != .background else { return }
            // K 里程碑：detach Sharer 订阅；若为直播私 call，LiveRoomView 那一格保留（下次 apply 走 `.live` 栈顶）
            BeautyPipelineSharer.shared.detach(camera.renderer as AnyObject & BeautyRenderer)
            // review 202607071542 R-3 修复：stop() → tearDown() —— stop 只暂停 session，observer/subscribers/onError 仍挂载，
            // 回前台的 willEnterForegroundNotification 会误重启 session（摄像头灯重亮）+ subscribers 字典残留。
            // tearDown 全清且幂等（参考 LiveRoomView.swift:368 同模式；CameraManager.swift:314 内 guard session.isRunning 无副作用）。
            if liveCamera == nil { camera.tearDown() }
        }
        // C-3 通话异常自检 alert（H5 g-faceTime/topBar.vue tenSecondsCB + secondsToZero）
        // 一次通话同 reason 只弹一次（CallStore.alertedAbnormalReasons 保护）；
        // End Call → hangup 触发 endLocally 挂断链路；Continue → dismissAbnormalReason（cancel role 自动触发）。
        .alert(
            reasonTitle(for: store.callAbnormalReason),
            isPresented: Binding(
                get: { store.callAbnormalReason != nil },
                set: { if !$0 { store.dismissAbnormalReason() } }
            ),
            presenting: store.callAbnormalReason
        ) { _ in
            Button(L10n.callAbnormalEndCall, role: .destructive) {
                Task { await store.hangup() }
            }
            Button(L10n.callAbnormalContinue, role: .cancel) {}
        } message: { reason in
            Text(reasonMessage(for: reason))
        }
        // Phase C: chat 输入框 sheet
        .sheet(isPresented: $showChatInput) { chatInputSheet }
        // Phase D: gift picker sheet
        .sheet(isPresented: $showGiftPicker) { giftPickerSheet }
        // Phase E: report sheet
        .sheet(isPresented: $showReportSheet) { reportSheet }
    }

    // MARK: - Phase C/D/E · 3 sheet content（@ViewBuilder 抽出减 body 类型推导复杂度）

    @ViewBuilder
    private var chatInputSheet: some View {
        CallChatInputSheet(store: store)
            .presentationDetents([.height(160)])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var giftPickerSheet: some View {
        CommonGiftPanel(config: .callAskFor(onAsk: handleAskForGift))
            .presentationDetents([.fraction(0.4)])
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var reportSheet: some View {
        ReportUserSheet(
            userId: store.current.remoteUserIdString,
            onSubmitSuccess: { showReportSheet = false }
        )
        .presentationDetents([.fraction(0.4)])
    }

    /// 对齐 H5 index.vue:203-215 askForGift 完整链路：关 sheet + 起 15s 冷却 + 调后端 API + 本地回显。
    private func handleAskForGift(_ gift: GiftListData) {
        showGiftPicker = false
        // 本地立即回显（H5 askGiftInfo 2s toast 语义 —— iOS 落到公屏 gift cell）
        let sender = CallChatMessage.Sender(
            nickname: AnchorInfoStore.shared.mine?.nickname ?? "",
            level: nil, isVip: false, isSpecial: false,
            chatBubble: nil, nicknameColor: .her
        )
        let img = gift.giftSmallImg.isEmpty ? gift.giftImg : gift.giftSmallImg
        store.appendChatMessage(.gift(sender: sender, imageURL: img, count: 1))
        // 起 15s 冷却
        askGiftDisableCountdown = 15
        Task { @MainActor in
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled || askGiftDisableCountdown == 0 { return }
                askGiftDisableCountdown = max(0, askGiftDisableCountdown - 1)
            }
        }
        // 调 API（fire-and-forget，Wave 6 backlog 加失败 toast）
        let peer = store.current.remoteYxAccid
        let giftId = gift.id
        Task {
            do {
                try await GiftService.askFor(beAskYxAccid: peer, giftId: giftId)
            } catch {
                AppLogger.call.error("[Call] askFor FAIL giftId=\(giftId, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func reasonTitle(for reason: CallAbnormalReason?) -> String {
        guard let reason else { return "" }
        switch reason {
        case .userOffline:     return L10n.callAbnormalUserOfflineTitle
        case .networkUnstable: return L10n.callAbnormalNetworkUnstableTitle
        case .incomeZero:      return L10n.callAbnormalIncomeZeroTitle
        }
    }

    private func reasonMessage(for reason: CallAbnormalReason) -> String {
        switch reason {
        case .userOffline:     return L10n.callAbnormalUserOfflineMessage
        case .networkUnstable: return L10n.callAbnormalNetworkUnstableMessage
        case .incomeZero:      return L10n.callAbnormalIncomeZeroMessage
        }
    }

    /// C-4 Wave4 C 组 gap-010 · 远端摄像头 off 覆盖层
    /// 视觉：深黑背景 + 中央远端头像 100pt + "Camera off" 文案
    private var remoteCameraOffFallback: some View {
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 14) {
                AvatarView(urlString: store.current.remoteIcon, size: 100, kind: .user)
                    .overlay(
                        Circle().stroke(.white.opacity(0.35), lineWidth: 2)
                    )
                Text(L10n.callRemoteCameraOff)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityLabel(L10n.callRemoteCameraOff)
            }
        }
    }

    private var topBar: some View {
        // 设计稿 /Users/joe/Downloads/通话UI/主播端.png 对齐：
        // 左侧半透明黑圆角信息卡（多行）+ 右侧 X 挂断按钮（PIP 视觉上盖住其下半）。
        //
        // 信息卡布局：
        //   Row 1 (identity)：Avatar(40) + 昵称 → 右侧 You/User 信号条
        //   Row 2 (badges)  ：SS 徽章 + 国旗 emoji + 国家码（可选）
        //   Row 3 (timer)   ：大 monospaced 00:00:00
        //   Row 4 (income)  ：call 收入胶囊 + gift 收入胶囊
        //   Row 5 (waitTag) ：粉色 "User recharging, please wait Ns." 内联提示（waitState 生效且非锁定态时）
        // X 关闭按钮已移到独立 topTrailing 层（closeButton）—— 避免与 PIP 视觉/交互干扰
        HStack(alignment: .top, spacing: 8) {
            infoCard.frame(maxWidth: 260, alignment: .leading)
            Spacer(minLength: 4)
        }
    }

    /// 独立右上角 X 关闭按钮（对齐设计稿 通话设计稿.png：显眼的深色圆 + 白 xmark）。
    /// - 位置固定 top:12/trailing:16，不受 PIP 拖动影响
    /// - 直播私 call 前 5 分钟锁定期隐藏（isInLiveLockout；对齐 H5 privateCallTips）
    /// - .plain style + label contentShape 避免手势被父层抢占（同 callImageActionButton）
    @ViewBuilder
    private var closeButton: some View {
        if !isInLiveLockout {
            Button {
                CallHaptics.impact(.medium)
                showHangupConfirm = true
            } label: {
                ZStack {
                    Circle().fill(Color.black.opacity(0.55))
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 36, height: 36)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
                .contentShape(Circle())
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.callHangupConfirmTitle)
            .accessibilityAddTraits(.isButton)
        }
    }

    /// v4：直播私 call 锁定期判定。前 5 分钟 `liveCallCountdown > 0` 时主播不能挂断（对齐 H5 privateCallTips）
    private var isInLiveLockout: Bool {
        store.current.frontGameType == .live && store.liveCallCountdown > 0
    }

    /// 左上信息卡：identity + timer + income + waitTag（对齐设计稿主播端.png）
    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1：Avatar + 昵称 + You/User 信号条
            HStack(alignment: .center, spacing: 10) {
                AvatarView(urlString: store.current.remoteIcon,
                           size: 40,
                           kind: .user,
                           headwearURL: store.current.remoteHeadFrame.isEmpty ? nil : store.current.remoteHeadFrame)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.current.remoteNickname.isEmpty ? store.current.remoteUserIdString : store.current.remoteNickname)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    anchorBadgesRow
                }
                Spacer(minLength: 4)
                signalColumn
            }
            // Row 2：大 timer
            Text(formatDuration(store.callElapsed))
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .accessibilityLabel(Text(formatDuration(store.callElapsed)))
            // Row 3：收入胶囊 × 2
            topBarIncomeChips
            // Row 4（可选）：waitState 内联粉色胶囊（H5 waitCallTip 语义 + 设计稿位置）
            if store.callWaitState > 0, !store.isCallWaitLocked {
                waitStateInlineTag
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// SS 徽章 + 国旗 emoji + 国家码（缺字段时自动降级）
    // TODO(H/I 里程碑)：SS 徽章目前是占位——后端 CreateCallResult/JoinCallResult 已有 `levelName`
    // 字段 (CallModels.swift:142/163)，未来按 levelName 分档切图，当前仅视觉对齐设计稿。
    @ViewBuilder
    private var anchorBadgesRow: some View {
        HStack(spacing: 4) {
            Image("CallAnchorBadgeSS")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            // 严格 ISO 2 字节 code 才展示徽章行（flagEmoji 对非法输入回退 "🌐"；用 count==2 守卫避免
            // "🌐 USA" 类退化视觉。H5 主播端契约后端总是 2 字节 ISO）
            let code = store.current.remoteCountryCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if code.count == 2 {
                Text(AnchorInfoStore.flagEmoji(from: code))
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text(code.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    /// 右侧信号列：You / User 两行 —— 消费真实网络质量（agora.localSignalLevel / remoteSignalLevel）。
    /// 数据来源：AgoraRtcEngineDelegate.rtcEngine networkQuality 每 ~2s 上报（AgoraNetworkQuality raw 0-6）。
    private var signalColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            signalRow(label: L10n.callSignalLabelYou, level: agora.localSignalLevel)
            signalRow(label: L10n.callSignalLabelUser, level: agora.remoteSignalLevel)
        }
        .accessibilityHidden(true)
    }

    /// 5 格自绘信号条：level 越小越好（1 excellent → 5 格 / 6 down → 0 格 / 0 unknown → 0 格）
    private func signalRow(label: String, level: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            signalBars(level: level)
        }
    }

    private func signalBars(level: Int) -> some View {
        let filled = filledBarCount(for: level)
        return HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < filled ? Color(red: 0.35, green: 0.90, blue: 0.40) : Color.white.opacity(0.28))
                    .frame(width: 2, height: CGFloat(4 + i * 2))
            }
        }
    }

    private func filledBarCount(for level: Int) -> Int {
        switch level {
        case 1: return 5   // excellent
        case 2: return 4   // good
        case 3: return 3   // poor
        case 4: return 2   // bad
        case 5: return 1   // vBad
        default: return 0  // 0 unknown / 6 down
        }
    }

    /// 粉色 "User recharging, please wait Ns." 内联胶囊（waitState=1/3 触发）
    private var waitStateInlineTag: some View {
        HStack(spacing: 4) {
            Text(waitStateInlineText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            Capsule().fill(
                LinearGradient(colors: [Color(red: 1.0, green: 0.35, blue: 0.68),
                                        Color(red: 0.98, green: 0.19, blue: 0.53)],
                               startPoint: .leading, endPoint: .trailing)
            )
        )
        .transition(.opacity.combined(with: .scale))
    }

    private var waitStateInlineText: String {
        // 优先展示 countdown（有实际秒数时）；否则回退 waitState 语义文案
        let countdown = store.callWaitCountdown
        if countdown > 0 {
            return String(format: L10n.callWaitStateRechargingFormat, countdown)
        }
        switch store.callWaitState {
        case 1: return L10n.Call.Hud.waitStartPay
        case 2: return L10n.Call.Hud.waitPaySuccess
        case 3: return L10n.Call.Hud.waitCallTimeEnd
        case 4: return L10n.Call.Hud.waitPayCancel
        default: return ""
        }
    }

    /// 收入 pill × 2 内联（对齐 H5 TopBarIncome × 2 + 设计稿主播端.png 两胶囊布局）。
    /// merged = callIncome + callWaitBonus（H5 giftIncomeTotal 语义）；>0 才显示避免视觉空占。
    @ViewBuilder
    private var topBarIncomeChips: some View {
        let mergedCallIncome = store.current.callIncome + store.callWaitBonus
        HStack(spacing: 8) {
            if mergedCallIncome > 0 {
                incomeCapsule(iconAsset: "CallPillIconPhone",
                              value: mergedCallIncome,
                              tint: Color(red: 0.16, green: 0.24, blue: 0.20))   // 深墨绿（call）
            }
            if store.current.callGiftIncome > 0 {
                incomeCapsule(iconAsset: "CallPillIconGift",
                              value: store.current.callGiftIncome,
                              tint: Color(red: 0.36, green: 0.24, blue: 0.19))   // 深棕（gift）
            }
        }
    }

    /// 收入胶囊：切图 icon 20pt + 数字 + 💎 + tint 半透明胶囊背景（对齐设计稿主播端.png）
    private func incomeCapsule(iconAsset: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(iconAsset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text("\(value)")
                .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
            Text("💎").font(.system(size: 12)).accessibilityHidden(true)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.85)))
    }

    private var bottomBar: some View {
        // 设计稿 通话设计稿.png 底部布局（非均匀分布）：chat 靠左边缘，gift+more 组靠右边缘
        // Phase C/D/E 完整接后端：
        // - chat → showChatInput sheet → CallStore.sendCallText（P2P 自定义消息 attachType=-1）
        // - gift → showGiftPicker → CommonGiftPanel.callAskFor → GiftService.askFor + 15s 冷却
        // - more → showReportSheet → ReportUserSheet（复用 H-0 已有组件，H5 c-feedbackPopup 对齐）
        HStack(spacing: 0) {
            callImageActionButton(asset: "CallBtnChat",
                                  label: L10n.callActionChatInput,
                                  size: 56) {
                showChatInput = true
            }
            Spacer(minLength: 24)
            HStack(spacing: 26) {
                // gift 键 64pt 稍大 —— 设计稿彩色礼物盒是全屏最亮切图，视觉重心
                callGiftButton
                callImageActionButton(asset: "CallBtnMore",
                                      label: L10n.callActionFeedback,
                                      size: 56) {
                    showReportSheet = true
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    /// 礼物按钮：15s 冷却期间 disabled + 显示倒计时角标
    @ViewBuilder
    private var callGiftButton: some View {
        ZStack(alignment: .topTrailing) {
            callImageActionButton(asset: "CallBtnGift",
                                  label: L10n.callActionAskForGift,
                                  size: 64) {
                guard askGiftDisableCountdown == 0 else { return }
                showGiftPicker = true
            }
            .opacity(askGiftDisableCountdown > 0 ? 0.55 : 1)
            if askGiftDisableCountdown > 0 {
                Text("\(askGiftDisableCountdown)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Circle().fill(Color.black.opacity(0.75)))
                    .offset(x: -2, y: 2)
                    .accessibilityHidden(true)
            }
        }
    }

    /// 通话底部切图按钮（无叠加背景，切图自带图形）+ label + 触觉反馈 + 大热区
    /// - `.buttonStyle(.plain)` 明确关闭默认 style —— 阻断父 `.onTapGesture` 抢占（chrome toggle）
    /// - label 内 `.contentShape(Rectangle())` 让整个 frame 都是热区（图片透明区也响应）
    ///   参 rule `.claude/rules/swiftui-button-plain-hitarea.md`
    private func callImageActionButton(asset: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button {
                CallHaptics.impact(.medium)
                action()
            } label: {
                Image(asset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var liveCallBanner: some View {
        // C-4 Wave1 gap-009：直播私 call 300s 收益横幅（H5 g-faceTime/index.vue privateCallTips）
        // countdown > 0 显示带 %d 的说明文案；归 0 后显示原静态文案
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.caption)
                .accessibilityHidden(true)
            Text(liveCallBannerText).font(.caption).bold()
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.pink.opacity(0.85), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private var liveCallBannerText: String {
        if store.liveCallCountdown > 0 {
            return String(format: L10n.callLiveBannerCountdownFormat, store.liveCallCountdown)
        }
        return L10n.callLiveBanner
    }

    private func formatDuration(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// tap 远端视频背景切 chrome 显隐（对齐 H5 switchShowAll）；
    /// confirmationDialog / alert 打开时守卫短路，避免误触。
    private func toggleChromeVisible() {
        guard !showHangupConfirm, store.callAbnormalReason == nil else { return }
        withAnimation { isChromeVisible.toggle() }
    }

    /// PIP 拖动手势：minimumDistance=5 避免误触；translation 期间用 @GestureState，
    /// 结束时 commit 到 @State pipDragOffset（累计偏移）。
    /// 对齐 rule swiftui-root-draggesture-mindist-zero.md：本手势挂在 PIP view 上（非全局祖先），
    /// 且 minimumDistance > 0，不会干扰其他 slider / gesture。
    private var pipDragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .updating($pipDragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                pipDragOffset = CGSize(
                    width: pipDragOffset.width + value.translation.width,
                    height: pipDragOffset.height + value.translation.height
                )
                CallHaptics.impact(.light)
            }
    }

    /// PIP 累计偏移（拖动中 + 已 commit 之和）——只在 view 是 PIP 时应用（VideoLayoutModifier 内判定）
    private var pipTotalOffset: CGSize {
        CGSize(width: pipDragOffset.width + pipDragTranslation.width,
               height: pipDragOffset.height + pipDragTranslation.height)
    }

    /// 本地相机预览的锁定态 dim overlay（仅 PIP + isCallWaitLocked 时生效；main 全屏时不 dim）
    @ViewBuilder
    private var cameraPreviewLockOverlay: some View {
        if !isLocalMain, store.isCallWaitLocked {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.5))
                Image(systemName: "lock.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .transition(.opacity)
        }
    }

    /// tap remote：main 时切 chrome / PIP 时切主副
    private func handleRemoteTap() {
        if isLocalMain {
            // remote 现在是 PIP —— tap 触发主副对换（切回 remote 全屏）
            swapMainView()
        } else {
            // remote 是全屏背景 —— tap 切 chrome 显隐
            toggleChromeVisible()
        }
    }

    /// tap local：main 时切 chrome / PIP 时切主副（与 handleRemoteTap 对称，用户 UX 一致）
    private func handleLocalTap() {
        if isLocalMain {
            toggleChromeVisible()
        } else {
            swapMainView()
        }
    }

    /// 主副视频对换（极简版：只 frame/padding/offset/zIndex 参数变化，UIViewRepresentable 不 dismantle）
    private func swapMainView() {
        CallHaptics.impact(.light)
        withAnimation(.easeInOut(duration: 0.25)) {
            isLocalMain.toggle()
        }
    }
}

// MARK: - 视频布局 modifier（主副视频共用，isMain 参数化 frame/padding/offset）

/// 通话视频 layout modifier：main 时全屏 + `.ignoresSafeArea()`；PIP 时 110×160 topRight + offset。
/// - modifier chain 结构不变，仅参数条件 → SwiftUI 走 `.updateUIView` 而非 dismantle（rule swiftui-camera-preview.md §2）
/// - main 时 pipOffset 不应用（.zero）；PIP 时应用（累计拖动偏移）
private struct VideoLayoutModifier: ViewModifier {
    let isMain: Bool
    let pipOffset: CGSize

    private let pipWidth: CGFloat = 110
    private let pipHeight: CGFloat = 160
    private let pipTrailing: CGFloat = 16
    private let pipTop: CGFloat = 60
    private let pipCornerRadius: CGFloat = 14
    private let pipBorderWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .frame(width: isMain ? nil : pipWidth,
                   height: isMain ? nil : pipHeight)
            .clipShape(RoundedRectangle(cornerRadius: isMain ? 0 : pipCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: pipCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(isMain ? 0 : 0.35), lineWidth: pipBorderWidth)
            )
            // hit shape 锁定在 PIP 内容尺寸（110×160）—— 用户 tap 只在小窗内命中；
            // main 状态 hit shape 也是内容 frame（全屏 = 相当于命中背景，与 remote main tap = chrome toggle 一致）。
            // 若把 contentShape 放在最外层 `.frame(maxWidth: .infinity)` 之后，会让 hit shape 扩大到全屏 →
            // 用户 tap main 区域也会命中 PIP view 触发 swap（bug）。
            .contentShape(RoundedRectangle(cornerRadius: isMain ? 0 : pipCornerRadius, style: .continuous))
            .padding(.trailing, isMain ? 0 : pipTrailing)
            .padding(.top, isMain ? 0 : pipTop)
            .offset(x: isMain ? 0 : pipOffset.width,
                    y: isMain ? 0 : pipOffset.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: isMain ? .center : .topTrailing)
            .ignoresSafeArea()
    }
}

// MARK: - 小组件

private struct RemoteAvatar: View {
    let icon: String
    let nickname: String
    /// 佩戴的头像框 URL（joinCall.headFrame）；SVGA 后缀当前不渲染，静态图正常显示。
    /// headwearRatio 1.35 对齐 H5 g-waitingCall.vue（头像 48 / 框 65 ≈ 1.354 外扩）。
    let headFrame: String

    var body: some View {
        AvatarView(urlString: icon,
                   size: 120,
                   kind: .user,
                   headwearURL: headFrame,
                   headwearRatio: 1.35)
    }
}

private struct CountdownRing: View {
    let elapsed: Int
    let total: Int

    var body: some View {
        let progress = total > 0 ? Double(elapsed) / Double(total) : 0
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: 1 - progress)
                .stroke(.pink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: elapsed)
            Text("\(max(total - elapsed, 0))")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

private struct CircleButton: View {
    let systemName: String
    let color: Color
    let label: String
    /// C 里程碑：默认 64pt（挂断主按钮）；sub-button（静音/切摄像头）传 54
    var size: CGFloat = 64
    /// C 里程碑：直播私 call 场景切摄像头 disabled（灰态 + 不响应点击）
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button {
                // C-4 Wave1 gap-critic-011：iOS 平台惯例 haptic（disabled 时不触发）
                if !disabled { CallHaptics.impact(.medium) }
                action()
            } label: {
                Image(systemName: systemName)
                    .font(.system(size: size >= 64 ? 26 : 22, weight: .bold))
                    .foregroundStyle(disabled ? Color.white.opacity(0.4) : .white)
                    .frame(width: size, height: size)
                    .background(disabled ? color.opacity(0.4) : color, in: Circle())
                    .accessibilityHidden(true)   // SF Symbol 仅装饰，语义在 Button.accessibilityLabel
            }
            .disabled(disabled)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            Text(label).font(.caption).foregroundStyle(.white.opacity(disabled ? 0.4 : 0.85))
                .accessibilityHidden(true)        // 视觉文本，避免 VoiceOver 重复朗读
        }
        .contentShape(Rectangle())  // swiftui-button-plain-hitarea.md：整个 VStack 都是热区
    }
}

// MARK: - 独立 1v1 通话路径的相机/美颜 lazy holder
//
// 直播私 call（liveCamera != nil）路径下，下列字段**永不**被访问 → CameraManager / BeautyParameters
// 永不构造；省下 AVCaptureSession + Metal context + FURenderKit 资源占用。
@MainActor
private final class CallFaceTimeFallbackHolder: ObservableObject {
    lazy var camera: CameraManager = CameraManager()
    lazy var beauty: BeautyParameters = BeautyParameters()
}

// MARK: - C-4 Wave1 gap-critic-011：haptic feedback 统一封装
//
// iOS 平台惯例：通话按钮 press impact / toast 或 alert warning / error。
// iOS 16 target 不能用 iOS 17 `.sensoryFeedback` modifier，走 UIImpactFeedbackGenerator（iOS 10+）。
// 挂点：CircleButton press (.medium) / hangup confirm .destructive (.heavy) /
//       CallView .onChange 消费 callAbnormalReason/weakNetworkToastToken 触发 warning。
enum CallHaptics {
    /// 按钮按下的通用触觉，强度按语义分档（.medium=普通/.heavy=挂断类破坏性动作）
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    /// 弱网 toast / 异常 alert 类中性警示
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    /// 强破坏性错误（未来预留：网络断开 forceEnd 等）
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - HUD：sysMsg 5 publishers 可视化

/// `.task(id:)` 模式：id 变化时 SwiftUI 自动取消旧 task → 新 task 重新计时，
/// 避免 `onChange` + `Task.sleep` 老任务串扰新内容（与 BlocklistView.transientErrorToast 一致）。
private struct CallHudOverlay: View {
    @ObservedObject var store: CallStore
    @State private var visibleBonus: Int?

    var body: some View {
        VStack(spacing: 0) {
            // 收入 pill 已挪到 topBar 内联；waitState pill 也已挪到 topBar infoCard 内联粉色 tag。
            // remoteTextBubble 中央气泡（2026-07-09 用户反馈）已下线 —— 与 CallMessageScroller
            // 公屏消息列表（消费 store.callChatMessages 队列）视觉重复。
            Spacer()

            if let bonus = visibleBonus {
                bonusBubble(bonus)
                    .padding(.top, 12)
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer()
        }
        .task(id: store.callWaitBonus) {
            let bonus = store.callWaitBonus
            guard bonus > 0 else {
                visibleBonus = nil
                return
            }
            await flashTransient(seconds: 3,
                                 set: { visibleBonus = bonus },
                                 reset: { visibleBonus = nil })
        }
    }

    /// 触发瞬时显示 N 秒后自动隐藏。`.task(id:)` 取消时不复位（让下一个 task 接管，避免闪烁覆盖）。
    private func flashTransient(seconds: TimeInterval,
                                set: () -> Void,
                                reset: () -> Void) async {
        withAnimation(.easeInOut(duration: 0.25)) { set() }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.25)) { reset() }
    }

    @ViewBuilder
    private var incomeChips: some View {
        // C-4 Wave5 gap-022：首个 pill 合并 callIncome + callWaitBonus（对齐 H5 topBar giftIncomeTotal）
        // H5 giftIncomeTotal = callIncome + callWaitBonusTotal；iOS callWaitBonus 累加不重置直到 endLocally
        // 语义与 H5 callWaitBonusTotal 等价（同一通话内累计充值奖励钻石）。
        let mergedCallIncome = store.current.callIncome + store.callWaitBonus
        VStack(alignment: .trailing, spacing: 6) {
            if mergedCallIncome > 0 {
                pill(String(format: L10n.Call.Hud.incomeFormat, mergedCallIncome),
                     font: .system(size: 13, weight: .semibold), bg: .black, bgOpacity: 0.45,
                     hPad: 10, vPad: 4)
            }
            if store.current.callGiftIncome > 0 {
                pill(String(format: L10n.Call.Hud.giftIncomeFormat, store.current.callGiftIncome),
                     font: .system(size: 13, weight: .semibold), bg: .black, bgOpacity: 0.45,
                     hPad: 10, vPad: 4)
            }
        }
    }

    /// 胶囊样式统一入口（bonus 与旧 wait state pill 共用；remoteTextBubble 已下线）。
    private func pill(_ text: String,
                      font: Font,
                      fg: Color = .white,
                      bg: Color,
                      bgOpacity: Double = 1,
                      hPad: CGFloat = 12,
                      vPad: CGFloat = 6) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(fg)
            .monospacedDigit()
            .padding(.horizontal, hPad).padding(.vertical, vPad)
            .background(bg.opacity(bgOpacity), in: Capsule())
    }

    private func bonusBubble(_ amount: Int) -> some View {
        pill(String(format: L10n.Call.Hud.waitBonusFormat, amount),
             font: .system(size: 14, weight: .bold),
             fg: .black, bg: .yellow, bgOpacity: 0.9)
    }

    // TODO(2026-07-09 dead)：HUD 底部 waitState pill 已下线（内联到 topBar），保留 helper 避免立即删动到别处。若未来里程碑无复用可清理。
    private func waitStateText(_ type: Int) -> String {
        switch type {
        case 1: return L10n.Call.Hud.waitStartPay
        case 2: return L10n.Call.Hud.waitPaySuccess
        case 3: return L10n.Call.Hud.waitCallTimeEnd
        case 4: return L10n.Call.Hud.waitPayCancel
        default: return ""
        }
    }
}

// MARK: - C 里程碑：弱网 toast

/// 通话中弱网提示 overlay。CallStore 连续 30 次质量 ≥5 时 emit `weakNetworkToastToken`（UUID），
/// 本 view 通过 `.task(id:)` 消费 → 顶部胶囊显示 2s 自动消失（对齐 CallHudOverlay flashTransient 模式）。
/// 2s 冷却窗口在 CallStore.triggerWeakNetworkToast 内实现，view 层只做展示。
private struct CallNetworkToast: View {
    @ObservedObject var store: CallStore
    @State private var visible: Bool = false

    var body: some View {
        VStack {
            if visible {
                Text(L10n.callNetworkQualityWeak)
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.top, 56)
            }
            Spacer()
        }
        .task(id: store.weakNetworkToastToken) {
            guard store.weakNetworkToastToken != nil else { return }
            withAnimation(.easeInOut(duration: 0.25)) { visible = true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { visible = false }
        }
    }
}

// MARK: - 拨打失败结束原因 toast

/// CallStore.lastError 非空时展示 1.5s 顶部胶囊（对齐 CallNetworkToast 模式）。
/// 用途：主叫拨打失败场景（对方拒绝 / 无应答 / 正忙 / createCall / joinRtc / RTM publish 失败）
/// 让主播明确知道通话为何结束，而非画面直接消失。
/// - 触发：`.task(id: store.lastError)` 消费 lastError 变化；非空即触发
/// - 时长：1.5s（配合 CallStore.scheduleEndedToIdle 失败态延迟 1.8s，让 toast 展示完整再 dismiss）
private struct CallEndReasonToast: View {
    @ObservedObject var store: CallStore
    @State private var visible: Bool = false
    @State private var displayText: String = ""

    var body: some View {
        VStack {
            if visible {
                Text(displayText)
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.black.opacity(0.75), in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.top, 100)
            }
            Spacer()
        }
        .task(id: store.lastError) {
            guard !store.lastError.isEmpty else {
                withAnimation(.easeInOut(duration: 0.2)) { visible = false }
                return
            }
            displayText = store.lastError
            withAnimation(.easeInOut(duration: 0.25)) { visible = true }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { visible = false }
        }
    }
}

// MARK: - DM-20260616-003 黑屏空房间检测倒计时弹窗

/// 通话异常连续 3 次心跳 → 弹 10s 不可取消倒计时 → 走满自动挂断。
/// 对齐 H5 `emptyRoomCountdownPop.vue`：圆形背景数字 + 提示文案 + 屏蔽底层交互。
/// 显示条件由父视图 `store.emptyRoomCountdownRemaining != nil` 控制；detector 内部驱动 -1/秒。
private struct CallEmptyRoomCountdownOverlay: View {
    let remaining: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(.white.opacity(0.12))
                    Text("\(remaining)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
                .frame(width: 64, height: 64)
                Text(L10n.callEmptyRoomHangupTip)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30).padding(.vertical, 30)
            .frame(maxWidth: 300)
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(L10n.callEmptyRoomHangupTip) \(remaining)s"))
            .accessibilityAddTraits(.updatesFrequently)
        }
        // 屏蔽底层交互（对齐 H5 close-on-click-overlay=false）
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

// MARK: - C-5 gap-011 充值锁定顶部提示（对齐 H5 waitRechargeTips.vue 142pt 顶部蒙层）

/// 充值锁定态顶部提示：双头像并列 + 中间锁图 + bonus 胶囊 + 倒计时。
/// 展示条件由父视图 `store.isCallWaitLocked` 控制（callWaitState == 1 或 3）。
/// 倒计时 60→5 由 CallStore.callWaitTimerTask 递减；到期兜底 5s 后自动 hangup。
private struct CallWaitRechargeTips: View {
    @ObservedObject var store: CallStore

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // 深黑半透明蒙层
                Rectangle().fill(.black.opacity(0.7))

                HStack(spacing: 16) {
                    // 远端头像
                    AvatarView(urlString: store.current.remoteIcon, size: 48, kind: .user)
                        .overlay(
                            Circle().stroke(.white.opacity(0.35), lineWidth: 1)
                        )
                    // 中间锁图 + 倒计时
                    VStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text(String(format: L10n.callWaitRechargeCountdownFormat, store.callWaitCountdown))
                            .font(.caption).monospacedDigit().bold()
                            .foregroundStyle(.white)
                    }
                    // 本端头像占位（H5 双头像视觉）
                    Circle().fill(.white.opacity(0.15))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                        )
                }
                .padding(.horizontal, 24)

                // Bonus 胶囊右下角
                if store.callWaitBonus > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(String(format: L10n.callWaitRechargeBonusFormat, store.callWaitBonus))
                                .font(.caption).bold()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(
                                    LinearGradient(colors: [.pink, .orange],
                                                   startPoint: .leading, endPoint: .trailing),
                                    in: Capsule()
                                )
                                .padding(.trailing, 16).padding(.bottom, 8)
                        }
                    }
                }
            }
            .frame(height: 142)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

// MARK: - C-5 gap-012 充值成功 Congrats 弹窗（对齐 H5 topBar.vue:23-32 CGiftDialog）

private struct CongratsBonusSheet: View {
    let bonus: Int
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            // 黄钻图（SF 占位；J 里程碑替换为品牌资产）
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(
                    LinearGradient(colors: [.yellow, .orange],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .accessibilityHidden(true)
            Text(L10n.callCongratsTitle)
                .font(.title2).bold()
            Text(String(format: L10n.callCongratsMessageFormat, bonus))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                CallHaptics.impact(.light)
                onDismiss()
            } label: {
                Text(L10n.callCongratsOK)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(
                        LinearGradient(colors: [.pink, .orange],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
    }
}

// MARK: - 公屏消息 MessageScroller（对齐 H5 messageScroller.vue + 通话设计稿.png 5 变体）

/// 通话内公屏消息滚动区域。数据源 `CallStore.callChatMessages`（历史队列，上限 50）。
///
/// **5 视觉变体**（sender 字段决定分支）：
/// 1. `default text` — 无背景，昵称品牌绿 + 内容白色
/// 2. `Lv text` — 浅紫半透明背景 + Lv.N 星级徽章 + 昵称绿 + 内容白色
/// 3. `SS special` — 深紫渐变背景 + SS 徽章 + 亮粉昵称 + 内容白色
/// 4. `VIP fancy` — Lv徽章 + 金色 VIP 徽章 + 昵称绿 + 内容白色
/// 5. `gift` — 无背景，昵称绿 + 礼物图 40pt + `x N` 数字
///
/// 翻译行（可选）：`content.translation != nil` → 消息下方追加 A 头像 icon + 灰色翻译文字。
private struct CallMessageScroller: View {
    @ObservedObject var store: CallStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.callChatMessages) { msg in
                        messageCell(msg)
                            .id(msg.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .onChange(of: store.callChatMessages.count) { _ in
                if let last = store.callChatMessages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Cell 分派

    @ViewBuilder
    private func messageCell(_ msg: CallChatMessage) -> some View {
        switch msg.payload {
        case let .text(content, translation):
            textCell(sender: msg.sender, content: content, translation: translation)
        case let .gift(imageURL, count):
            giftCell(sender: msg.sender, imageURL: imageURL, count: count)
        case let .bonus(amount):
            bonusCell(amount: amount)
        }
    }

    // MARK: - text cell（含 5 变体分支）

    @ViewBuilder
    private func textCell(sender: CallChatMessage.Sender,
                          content: String,
                          translation: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 4) {
                if let level = sender.level {
                    PublicChatLevelBadge(level: level)
                }
                if sender.isVip {
                    PublicChatVipBadge()
                }
                if sender.isSpecial {
                    Image("CallAnchorBadgeSS")
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                nicknameContentText(nickname: sender.nickname.isEmpty ? L10n.callSignalLabelUser : sender.nickname,
                                    nicknameColor: resolveNicknameColor(sender.nicknameColor, isSpecial: sender.isSpecial),
                                    content: content)
            }
            if let translation, !translation.isEmpty {
                translationRow(translation: translation,
                               onDarkBackground: sender.isSpecial)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(textCellBackground(sender: sender))
        .frame(maxWidth: 270, alignment: .leading)
    }

    /// 昵称 + `:  ` + 内容（Text 插值嵌套，禁 `+` 拼接对齐 rule swiftui-body-type-check-timeout.md）
    private func nicknameContentText(nickname: String,
                                     nicknameColor: Color,
                                     content: String) -> some View {
        Text("\(Text(nickname).foregroundColor(nicknameColor))\(Text(":  \(content)").foregroundColor(.white))")
            .font(.system(size: 13, weight: .medium))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
    }

    private func resolveNicknameColor(_ kind: CallChatMessage.Sender.NicknameColor,
                                      isSpecial: Bool) -> Color {
        if isSpecial { return Color(red: 1.0, green: 0.10, blue: 0.65) }
        switch kind {
        case .default: return Color(red: 0.42, green: 0.87, blue: 0.55)
        case .her:     return Color(red: 0.93, green: 0.48, blue: 0.31)
        case .special: return Color(red: 1.0, green: 0.10, blue: 0.65)
        }
    }

    /// 消息背景：default 无 / Lv 浅紫 / SS 深紫渐变 / VIP 金框
    @ViewBuilder
    private func textCellBackground(sender: CallChatMessage.Sender) -> some View {
        if sender.isSpecial {
            // SS 深紫渐变
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(red: 0.36, green: 0.10, blue: 0.44),
                                            Color(red: 0.58, green: 0.15, blue: 0.55)],
                                   startPoint: .leading, endPoint: .trailing)
                )
        } else if sender.isVip {
            // VIP 金色描边 + 浅紫底
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.36, green: 0.28, blue: 0.48).opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(red: 1.0, green: 0.80, blue: 0.30), lineWidth: 1)
                )
        } else if sender.level != nil {
            // Lv 浅紫半透明
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.42, green: 0.34, blue: 0.55).opacity(0.40))
        } else {
            Color.clear
        }
    }

    // MARK: - 翻译行（A 头像 icon + 灰色文字）

    private func translationRow(translation: String, onDarkBackground: Bool) -> some View {
        HStack(spacing: 5) {
            AutoTranslateBadge()
            Text(translation)
                .font(.system(size: 12))
                .foregroundColor(onDarkBackground
                                 ? .white.opacity(0.85)
                                 : .white.opacity(0.55))
                .lineLimit(2)
        }
    }

    // MARK: - gift cell

    private func giftCell(sender: CallChatMessage.Sender,
                          imageURL: String,
                          count: Int) -> some View {
        HStack(alignment: .center, spacing: 6) {
            let nickname = sender.nickname.isEmpty ? L10n.callSignalLabelUser : sender.nickname
            let nameColor = resolveNicknameColor(sender.nicknameColor, isSpecial: sender.isSpecial)
            Text("\(Text(nickname).foregroundColor(nameColor))\(Text(":  ").foregroundColor(.white))")
                .font(.system(size: 13, weight: .medium))
            // v22（2026-07-10）：改用 CachedAsyncImage（NSCache + URLCache 双层持久缓存），
            // 修复 AsyncImage 无强缓存 → 滚动重拉失败导致的礼物图不显示
            CachedAsyncImage(url: URL(string: imageURL), contentMode: .fill) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08))
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("x \(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(red: 1.0, green: 0.80, blue: 0.30))
                .monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: 270, alignment: .leading)
    }

    // MARK: - bonus cell（充值奖励，粉橙渐变胶囊；当前未启用，Phase A 已完成 wiring 备用）

    private func bonusCell(amount: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "gift.fill").font(.system(size: 10))
            Text("+\(amount) 💎").font(.caption).bold()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            LinearGradient(colors: [.pink, .orange],
                           startPoint: .leading, endPoint: .trailing),
            in: Capsule()
        )
    }
}

// MARK: - 公屏小组件（复用直播 LevelBadge/VipBadge + 本地 A 自动翻译 icon）

/// 自动翻译 icon —— 小灰圆 + "A"（对齐设计稿 Row 3/5/6 翻译前置图标）
private struct AutoTranslateBadge: View {
    var body: some View {
        Text("A")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white.opacity(0.75))
            .frame(width: 14, height: 14)
            .background(
                Circle().stroke(Color.white.opacity(0.55), lineWidth: 0.8)
            )
            .accessibilityHidden(true)
    }
}

/// 远程图片缓存展示（Wave 6 前用简版 AsyncImage；后续接项目 ImageCache 时替换）
private struct CachedRemoteImage: View {
    let urlString: String
    var size: CGFloat = 40

    var body: some View {
        if let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    placeholder
                }
            }
            .frame(width: size, height: size)
        } else {
            placeholder.frame(width: size, height: size)
        }
    }

    private var placeholder: some View {
        Image(systemName: "gift.fill")
            .font(.system(size: size * 0.4))
            .foregroundColor(.white.opacity(0.55))
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.08))
    }
}

// MARK: - C-4 Wave4 A1 gap-008 · 直播私 call 双头像会合动画

/// 直播私 call 首次接通时播放的仪式动画（对齐 H5 `g-faceTime/livingCallAnimation.vue`）。
/// **视觉**：本端 + 远端头像分别从屏幕左右两侧 (offset ±150) 90° 旋转 + spring 弹到中央（距离 0）→
///         hold 1s → 淡出。整体持续 ~2s，之后自动隐藏。
/// **触发**：CallStore.livingCallIntroToken UUID 变化（state 首次转 .connected + frontGameType==.live）。
private struct LivingCallIntroAnimation: View {
    let localAvatarURL: String?
    let remoteAvatarURL: String?
    let token: UUID?

    /// progress 0 → 1（左右两侧偏移 + 旋转角度归零）
    @State private var progress: CGFloat = 0
    @State private var visible: Bool = false

    var body: some View {
        HStack(spacing: 24) {
            avatarView(remoteAvatarURL)
                .offset(x: (1 - progress) * -150)
                .rotationEffect(.degrees(Double((1 - progress) * -90)))
            avatarView(localAvatarURL)
                .offset(x: (1 - progress) * 150)
                .rotationEffect(.degrees(Double((1 - progress) * 90)))
        }
        .opacity(visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .task(id: token) {
            guard token != nil else {
                progress = 0
                visible = false
                return
            }
            progress = 0
            withAnimation(.easeIn(duration: 0.2)) { visible = true }
            // spring 弹到中央 ~1s（.spring response 1.0）
            withAnimation(.spring(response: 1.0, dampingFraction: 0.72)) {
                progress = 1
            }
            // hold 1s（spring 1s + 停留 1s ≈ H5 语义 2s 后消失）
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { visible = false }
        }
    }

    private func avatarView(_ url: String?) -> some View {
        AvatarView(urlString: url, size: 80, kind: .user)
            .overlay(
                Circle().stroke(.white.opacity(0.6), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }
}

// MARK: - Phase C · 主播公屏文字输入 sheet（对齐 H5 g-faceTime/index.vue:405-427 showInput）

/// 通话中主播输入文字消息的底部 sheet（.presentationDetents([.height(160)])）。
/// 键盘弹起时 SwiftUI 自动挤压 sheet 内容；`onSubmit` + Send 按钮双入口触发发送。
private struct CallChatInputSheet: View {
    @ObservedObject var store: CallStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                inputField
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        .onAppear { focused = true }
    }

    private var inputField: some View {
        TextField(L10n.callChatInputPlaceholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .font(.system(size: 15))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundColor(.white)
            .tint(Color(red: 1.0, green: 0.10, blue: 0.65))
            .focused($focused)
            .onSubmit(sendAndClose)
    }

    private var sendButton: some View {
        Button(action: sendAndClose) {
            Text(L10n.callChatInputSend)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(sendButtonBg)
        }
        .disabled(!canSend)
        .buttonStyle(.plain)
    }

    /// view-based background（对齐 rule swiftui-background-in-shape-signature §正例 A）
    @ViewBuilder
    private var sendButtonBg: some View {
        if canSend {
            Capsule().fill(
                LinearGradient(colors: [Color(red: 0.90, green: 0.20, blue: 0.60),
                                        Color(red: 1.0, green: 0.10, blue: 0.65)],
                               startPoint: .leading, endPoint: .trailing)
            )
        } else {
            Capsule().fill(Color.gray.opacity(0.35))
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendAndClose() {
        guard canSend else { return }
        store.sendCallText(text)
        text = ""
        dismiss()
    }
}
