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
    /// 非直播态（独立 1v1）保持 nil，CallFaceTimeView 走 fallbackCamera/fallbackBeauty 路径。
    var liveCamera: CameraManager? = nil
    var liveBeauty: BeautyParameters? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            bodyContent
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
    @State private var elapsed: Int = 0
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 对方头像 / 名字
            RemoteAvatar(icon: store.current.remoteIcon, nickname: store.current.remoteNickname)

            Text(store.current.remoteNickname.isEmpty ? store.current.remoteUserIdString : store.current.remoteNickname)
                .font(.title2).foregroundStyle(.white)

            Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.75))

            // 圆环倒计时（主叫 30s）
            if store.current.inOrOut == .out {
                CountdownRing(elapsed: elapsed, total: Int(CallTuning.callOutTimeoutSeconds))
                    .frame(width: 80, height: 80)
                    .padding(.top, 8)
            }

            Spacer()

            buttons.padding(.bottom, 40)
        }
        .padding()
        .onReceive(tickTimer) { _ in
            if store.state == .calling { elapsed += 1 }
        }
        .onChange(of: store.state) { newValue in
            if newValue != .calling { elapsed = 0 }
        }
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
    @StateObject private var fallbackCamera = CameraManager()
    @StateObject private var fallbackBeauty = BeautyParameters()
    @State private var elapsed: Int = 0
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var camera: CameraManager { liveCamera ?? fallbackCamera }
    private var beautyParams: BeautyParameters { liveBeauty ?? fallbackBeauty }

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
        }
        .onDisappear {
            if liveCamera == nil { camera.stop() }
        }
        .onReceive(tickTimer) { _ in
            if store.state == .connected { elapsed += 1 }
        }
    }

    private var topBar: some View {
        HStack {
            Text(store.current.remoteNickname.isEmpty ? store.current.remoteUserIdString : store.current.remoteNickname)
                .font(.headline).foregroundStyle(.white)
            Spacer()
            Text(formatDuration(elapsed))
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
            Text(L10n.callLiveBanner).font(.caption).bold()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.pink.opacity(0.85), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func formatDuration(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - 小组件

private struct RemoteAvatar: View {
    let icon: String
    let nickname: String

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.12)).frame(width: 120, height: 120)
            if let url = URL(string: icon), !icon.isEmpty {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.7))
                }
                .frame(width: 120, height: 120)
                .clipShape(Circle())
            } else {
                Text(initials(from: nickname))
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func initials(from name: String) -> String {
        guard let c = name.first else { return "?" }
        return String(c).uppercased()
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
            }
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.85))
        }
    }
}
