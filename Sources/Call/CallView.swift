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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch store.state {
            case .calling:
                CallWaitingView(store: store)
            case .connecting, .connected:
                CallFaceTimeView(store: store)
            case .idle, .prepared, .ended, .failed:
                EmptyView()
            }
        }
        .preferredColorScheme(.dark)
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
        store.current.inOrOut == .out ? "呼叫中…" : "邀请你视频通话"
    }

    @ViewBuilder private var buttons: some View {
        if store.current.inOrOut == .out {
            CircleButton(systemName: "phone.down.fill", color: .red, label: "取消") {
                Task { await store.cancel() }
            }
        } else {
            HStack(spacing: 60) {
                CircleButton(systemName: "phone.down.fill", color: .red, label: "拒接") {
                    Task { await store.reject() }
                }
                CircleButton(systemName: "phone.fill", color: .green, label: "接听") {
                    Task { await store.accept() }
                }
            }
        }
    }
}

// MARK: - FaceTime：通话中

private struct CallFaceTimeView: View {
    @ObservedObject var store: CallStore
    @StateObject private var camera = CameraManager()
    @StateObject private var beautyParams = BeautyParameters()
    @State private var elapsed: Int = 0
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // 远端全屏（声网 setupRemoteVideo 会渲染到 store.agora.remoteView）
            RemoteVideoView(manager: store.agora).ignoresSafeArea()

            VStack {
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
            camera.renderer.updateParameters(beautyParams)
            CameraManager.requestAccess { granted in
                if granted { camera.start() }
            }
        }
        .onDisappear { camera.stop() }
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
            CircleButton(systemName: "phone.down.fill", color: .red, label: "挂断") {
                Task { await store.hangup() }
            }
            Spacer()
        }
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
