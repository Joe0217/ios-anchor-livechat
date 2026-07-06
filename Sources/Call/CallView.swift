import SwiftUI

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
        }
        .preferredColorScheme(.dark)
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
            CallFaceTimeView(store: store, liveCamera: liveCamera, liveBeauty: liveBeauty)
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

    private var camera: CameraManager { liveCamera ?? fallback.camera }
    private var beautyParams: BeautyParameters { liveBeauty ?? fallback.beauty }

    var body: some View {
        ZStack {
            // 远端全屏（声网 setupRemoteVideo 会渲染到 store.agora.remoteView）
            RemoteVideoView(manager: store.agora).ignoresSafeArea()

            VStack(spacing: 0) {
                // D 里程碑：直播私 call 顶部提示条（仅 frontGameType=.live 时显示）
                if store.current.frontGameType == .live {
                    liveCallBanner.padding(.top, 12).padding(.horizontal, 16)
                }
                topBar.padding(.top, 12).padding(.horizontal, 16)
                Spacer()
                bottomBar.padding(.bottom, 36)
            }

            // 本地 PIP（带美颜的相机预览）
            CameraPreview(camera: camera, agora: store.agora)
                .frame(width: 110, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.35), lineWidth: 1)
                )
                .padding(.trailing, 16).padding(.top, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
            // K 里程碑：detach Sharer 订阅；若为直播私 call，LiveRoomView 那一格保留（下次 apply 走 `.live` 栈顶）
            BeautyPipelineSharer.shared.detach(camera.renderer as AnyObject & BeautyRenderer)
            if liveCamera == nil { camera.stop() }
        }
    }

    private var topBar: some View {
        HStack {
            Text(store.current.remoteNickname.isEmpty ? store.current.remoteUserIdString : store.current.remoteNickname)
                .font(.headline).foregroundStyle(.white)
            Spacer()
            Text(formatDuration(store.callElapsed))
                .font(.subheadline).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
        }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            CircleButton(systemName: "phone.down.fill", color: .red, label: hangupLabel) {
                Task { await store.hangup() }
            }
            Spacer()
        }
    }

    private var hangupLabel: String {
        store.current.frontGameType == .live ? L10n.callActionHangupBackToLive : L10n.callActionHangup
    }

    private var liveCallBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.caption)
                .accessibilityHidden(true)
            Text(L10n.callLiveBanner).font(.caption).bold()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.pink.opacity(0.85), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
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
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(color, in: Circle())
                    .accessibilityHidden(true)   // SF Symbol 仅装饰，语义在 Button.accessibilityLabel
            }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)        // 视觉文本，避免 VoiceOver 重复朗读
        }
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

// MARK: - HUD：sysMsg 5 publishers 可视化

/// `.task(id:)` 模式：id 变化时 SwiftUI 自动取消旧 task → 新 task 重新计时，
/// 避免 `onChange` + `Task.sleep` 老任务串扰新内容（与 BlocklistView.transientErrorToast 一致）。
private struct CallHudOverlay: View {
    @ObservedObject var store: CallStore
    @State private var visibleRemoteText: String?
    @State private var visibleBonus: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); incomeChips }
                .padding(.top, 100).padding(.trailing, 16)

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

            if store.callWaitState > 0 {
                pill(waitStateText(store.callWaitState),
                     font: .caption, bg: .blue, bgOpacity: 0.7)
                    .padding(.bottom, 130)
                    .transition(.opacity)
            }
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
        VStack(alignment: .trailing, spacing: 6) {
            if store.current.callIncome > 0 {
                pill(String(format: L10n.Call.Hud.incomeFormat, store.current.callIncome),
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
