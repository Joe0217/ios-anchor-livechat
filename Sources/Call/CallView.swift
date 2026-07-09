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

    private var camera: CameraManager { liveCamera ?? fallback.camera }
    private var beautyParams: BeautyParameters { liveBeauty ?? fallback.beauty }

    var body: some View {
        ZStack {
            // 远端全屏（声网 setupRemoteVideo 会渲染到 store.agora.remoteView）
            RemoteVideoView(manager: store.agora).ignoresSafeArea()

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
                // [5min-DEBUG-DISABLED] 直播私 call 顶部横幅（5min 倒计时相关）暂时禁用做对照实验
                // if store.current.frontGameType == .live {
                //     liveCallBanner.padding(.top, 12).padding(.horizontal, 16)
                // }
                topBar.padding(.top, 12).padding(.horizontal, 16)
                Spacer()
                bottomBar.padding(.bottom, 36)
            }
            .opacity(isChromeVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
            .allowsHitTesting(isChromeVisible)

            // 本地 PIP（带美颜的相机预览）
            // C-4 Wave4 A3 gap-017 简化：锁定态给 PIP 加 lock overlay + dim（不做真实主副对换，
            // 位置交换会触发 UIViewRepresentable dismantleUIView → MTKView 断流 + AgoraCanvas 黑帧
            // (v5.3.3 已知坑)。真主副对换留独立 spec 用 UIView 池架构改造）
            CameraPreview(camera: camera, agora: store.agora)
                .frame(width: 110, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.35), lineWidth: 1)
                )
                .overlay(
                    // 锁定态视觉标示：深色 dim + 中心锁图标
                    Group {
                        if store.isCallWaitLocked {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(.black.opacity(0.5))
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .transition(.opacity)
                        }
                    }
                )
                .padding(.trailing, 16).padding(.top, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .animation(.easeInOut(duration: 0.2), value: store.isCallWaitLocked)

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
        // C-4 Wave1 gap-001 + gap-critic-001：点 root 切 chrome 显隐；confirmationDialog / alert 打开时守卫短路
        .contentShape(Rectangle())
        .onTapGesture {
            guard !showHangupConfirm, store.callAbnormalReason == nil else { return }
            withAnimation { isChromeVisible.toggle() }
        }
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
        HStack(alignment: .top, spacing: 8) {
            infoCard
                .frame(maxWidth: 260, alignment: .leading)
            Spacer(minLength: 4)
            // [5min-DEBUG-DISABLED] 5 分钟锁定期规则暂时禁用做对照实验，X 挂断按钮无条件显示
            Button {
                CallHaptics.impact(.medium)
                showHangupConfirm = true
            } label: {
                Image("CallHangupCircle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(L10n.callHangupConfirmTitle)
            .accessibilityAddTraits(.isButton)
        }
    }

    // [5min-DEBUG-DISABLED] 锁定期判定暂时禁用（保留以便恢复）
    // private var isInLiveLockout: Bool {
    //     store.current.frontGameType == .live && store.liveCallCountdown > 0
    // }

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

    /// 右侧信号列：You / User 两行；装饰性 UI，非真实网络质量
    private var signalColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            signalRow(label: L10n.callSignalLabelYou)
            signalRow(label: L10n.callSignalLabelUser)
        }
        .accessibilityHidden(true)
    }

    private func signalRow(label: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Image("CallSignalBars")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 12)
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
        // UI 对齐设计稿 /Users/joe/Downloads/通话UI/主播端.png 底部 3 键：
        // 直接使用切图 CallBtnChat / CallBtnGift / CallBtnMore（含背景/形状/图标一体），不再叠加自绘圆背景
        // - 聊天输入：Wave 6 依赖 NIM 通话通道；礼物：gap-004 依赖 askFor API；反馈：D-feedback 依赖 feedback sheet
        // 设计稿 通话设计稿.png 底部布局（非均匀分布）：chat 靠左边缘，gift+more 组靠右边缘
        // （原设计稿是 chat/heart/gift/more 4 键 —— 心形按用户明示去除后剩 3 键，位置不平均）
        HStack(spacing: 0) {
            callImageActionButton(asset: "CallBtnChat",
                                  label: L10n.callActionChatInput,
                                  size: 56) {
                showComingSoonToast = L10n.callActionChatInput + " · " + L10n.callActionComingSoon
            }
            Spacer(minLength: 24)
            HStack(spacing: 26) {
                // gift 键 64pt 稍大 —— 设计稿彩色礼物盒是全屏最亮切图，视觉重心
                callImageActionButton(asset: "CallBtnGift",
                                      label: L10n.callActionAskForGift,
                                      size: 64) {
                    showComingSoonToast = L10n.callActionAskForGift + " · " + L10n.callActionComingSoon
                }
                callImageActionButton(asset: "CallBtnMore",
                                      label: L10n.callActionFeedback,
                                      size: 56) {
                    showComingSoonToast = L10n.callActionFeedback + " · " + L10n.callActionComingSoon
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    /// 通话底部切图按钮（无叠加背景，切图自带图形）+ label + 触觉反馈 + 大热区
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
                    .accessibilityHidden(true)
            }
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
    @State private var visibleRemoteText: String?
    @State private var visibleBonus: Int?

    var body: some View {
        VStack(spacing: 0) {
            // C-4 Wave4 gap-022 综合：收入 pill 从 HUD 挪到 topBar 内联（H5 topBar TopBarIncome × 2 布局对齐）
            // 原 HStack incomeChips 已在 CallFaceTimeView.topBar 展示，此处不再渲染

            Spacer()

            if let text = visibleRemoteText {
                remoteTextBubble(text)
                    .padding(.horizontal, 32)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let bonus = visibleBonus {
                bonusBubble(bonus)
                    .padding(.top, 12)
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            // 设计稿主播端.png 对齐（2026-07-09）：waitStateText 内联到 topBar infoCard 底部粉色 tag，
            // HUD 底部原蓝色 pill 已下线避免视觉重复。锁定态仍由 CallWaitRechargeTips 大蒙层展示。
        }
        .task(id: store.callRecentRemoteText) {
            guard let text = store.callRecentRemoteText, !text.isEmpty else {
                visibleRemoteText = nil
                return
            }
            await flashTransient(seconds: 4,
                                 set: { visibleRemoteText = text },
                                 reset: { visibleRemoteText = nil })
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

    /// 胶囊样式统一入口：chip / bonus / wait state 三处共用。
    /// `remoteTextBubble` 因 cornerRadius 16 + multiline 与胶囊形态不同，保留独立。
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

    private func remoteTextBubble(_ text: String) -> some View {
        Text(String(format: L10n.Call.Hud.remoteTextFormat, text))
            .font(.subheadline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 300)
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

// MARK: - C-4 Wave4 gap-002 P0：公屏消息 MessageScroller（对齐 H5 messageScroller.vue 300x270 底部反向滚动）

/// 通话内公屏消息滚动区域。**当前 skeleton 版本**：
/// - 消费现有 `store.callRecentRemoteText`（单条 4s 自消）为单气泡展示
/// - `store.callWaitBonus` 变化 → 追加 bonus 气泡（充值奖励）
/// - `store.current.callIncome`/`callGiftIncome` 变化不入 scroller（HUD 顶部已显示累加）
///
/// **未来 Wave 6（依赖 H NIM 通话通道就绪）**：
/// - CallStore 加 `@Published var callChatMessages: [CallChatMessage]` 历史队列
/// - sysMsg 4 gift / sysMsg -1 text 转发到队列（含 giftImg / translation / chatBubble）
/// - 反向滚动 auto-scroll to bottom 新消息
/// - 三档 cell（gift / text default / customBubble borderImage）
private struct CallMessageScroller: View {
    @ObservedObject var store: CallStore
    /// 内部维护的近期消息缓冲（观察 store publishers 追加，上限 20 条防增长）。
    /// Wave 6 前用此简版；接 H NIM 通话通道后改为消费 store.callChatMessages。
    @State private var recentMessages: [CallScrollerMessage] = []

    var body: some View {
        // 反向滚动：底部为最新，向上溢出被 clipped（ScrollView 反向布局用 rotationEffect 或 flex-col-reverse 等价）
        // SwiftUI 简版实现：VStack 底对齐 + defaultScrollAnchor(.bottom) iOS 17+；iOS 16 fallback 用 ScrollViewReader auto-scroll
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recentMessages) { msg in
                        messageCell(msg)
                            .id(msg.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .onChange(of: recentMessages.count) { _ in
                if let last = recentMessages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .onChange(of: store.callRecentRemoteText) { newValue in
            if let text = newValue, !text.isEmpty {
                push(.init(kind: .text, content: text))
            }
        }
        .onChange(of: store.callWaitBonus) { newValue in
            if newValue > 0 {
                push(.init(kind: .bonus, content: "\(newValue) 💎"))
            }
        }
    }

    private func push(_ msg: CallScrollerMessage) {
        recentMessages.append(msg)
        // 上限 20 条防持续增长（>20 条 pop 头部）
        if recentMessages.count > 20 {
            recentMessages.removeFirst(recentMessages.count - 20)
        }
    }

    @ViewBuilder
    private func messageCell(_ msg: CallScrollerMessage) -> some View {
        switch msg.kind {
        case .text:
            // 设计稿 通话设计稿.png 公屏样式：昵称彩色（品牌绿）+ ":  " + 消息文本白色，
            // 半透明深色圆角背景。用 Text 插值嵌套 Text（Text.foregroundColor 返回 Text，iOS 15+）；
            // 禁 Text + 拼接（对齐 .claude/rules/swiftui-body-type-check-timeout.md）。
            // Wave 6 数据源到位后补：SS 用户深紫背景 / Lv 徽章 / VIP 徽章 / A 头像 + 翻译行。
            let nickname = store.current.remoteNickname.isEmpty
                ? L10n.callSignalLabelUser
                : store.current.remoteNickname
            let nameColor = Color(red: 0.42, green: 0.87, blue: 0.55)
            Text("\(Text(nickname).foregroundColor(nameColor))\(Text(":  \(msg.content)").foregroundColor(.white))")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: 260, alignment: .leading)
        case .bonus:
            HStack(spacing: 4) {
                Image(systemName: "gift.fill").font(.system(size: 10))
                Text(msg.content).font(.caption).bold()
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
}

/// 公屏消息滚动区域内部消息模型（简版；Wave 6 会替换为 CallStore.callChatMessages `CallChatMessage`）
private struct CallScrollerMessage: Identifiable, Equatable {
    let id: UUID = UUID()
    let kind: Kind
    let content: String

    enum Kind: Equatable {
        case text    // 远端文字消息
        case bonus   // 充值 bonus 追加
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
