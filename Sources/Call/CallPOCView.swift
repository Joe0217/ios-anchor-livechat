import SwiftUI
import AgoraRtcKit

/// 美颜 + 1v1 通话 POC：相机 → 美颜 → 本地预览 + 声网通信模式推流 + 远端画面。
/// 用 getAgoraRtmToken 的全量 token 加入 rtc(通信)频道；频道名双方约定一致即可联调
/// （真实通话的频道由后端 createCall 分配，这里手填用于自测）。
struct CallPOCView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var params = BeautyParameters()
    @StateObject private var agora = AgoraManager()
    @State private var authorized = false
    @State private var denied = false
    @State private var channel = "test_call"
    @State private var connecting = false
    @State private var errorMsg = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if authorized {
                CameraPreview(camera: camera, agora: agora).ignoresSafeArea()
            } else if denied {
                permissionHint
            }

            VStack(spacing: 12) {
                topBar
                Spacer()
                controlPanel
            }
            .padding()
        }
        .onAppear {
            camera.renderer.updateParameters(params)
            CameraManager.requestAccess { granted in
                authorized = granted
                denied = !granted
                if granted { camera.start() }
            }
        }
        .onDisappear {
            camera.stop()
            agora.leave()
        }
        .onReceive(params.objectWillChange) { _ in
            DispatchQueue.main.async { camera.renderer.updateParameters(params) }
        }
    }

    // MARK: - 顶部：状态 + 远端画面

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                beautyBanner
                Text(agora.message.isEmpty ? agora.state.rawValue : "\(agora.state.rawValue) · \(agora.message)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.6))
                if agora.remoteUid != 0 {
                    RemoteVideoView(manager: agora)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("等待对端").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 96, height: 160)
        }
    }

    private var beautyBanner: some View {
        let isPassthrough = camera.renderer is PassthroughRenderer
        return Text(isPassthrough ? "直通预览 · 相芯未接入" : "相芯美颜已接入")
            .font(.footnote).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var permissionHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("需要摄像头权限").foregroundStyle(.white)
            Text("请在 设置 > 隐私 > 相机 中开启").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: - 底部控制面板

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("频道").foregroundStyle(.white)
                TextField("", text: $channel,
                          prompt: Text("频道名（双方一致）").foregroundColor(.white.opacity(0.5)))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(agora.isActive || connecting)
            }

            if !errorMsg.isEmpty {
                Text(errorMsg).font(.footnote).foregroundStyle(.red)
            }

            Button {
                agora.isActive ? agora.leave() : startCall()
            } label: {
                HStack(spacing: 8) {
                    if connecting { ProgressView().tint(.white) }
                    Text(agora.isActive ? "挂断" : (connecting ? "接通中…" : "加入通话"))
                        .font(.headline).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(agora.isActive ? Color.red : Color.pink,
                            in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(connecting)

            Toggle("美颜开关", isOn: $params.enabled).tint(.pink).foregroundStyle(.white)
            slider("磨皮", value: $params.blur)
            slider("美白", value: $params.whiten)
            slider("大眼", value: $params.eyeEnlarge)
            slider("瘦脸", value: $params.faceThin)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    /// 接通：getAgoraRtmToken 拿全量 token → rtc 通信模式加入频道
    private func startCall() {
        let ch = channel.trimmingCharacters(in: .whitespaces)
        guard !ch.isEmpty else { errorMsg = "请输入频道名"; return }
        connecting = true
        errorMsg = ""
        Task { @MainActor in
            do {
                let tokenRes = try await LiveService.getAgoraRtmToken()
                guard let tk = tokenRes.rtcToken, !tk.isEmpty else {
                    errorMsg = "获取 token 失败"
                    connecting = false
                    return
                }
                // token 绑定登录用户的 uid，join 必须用同一个 uid
                let uid = UInt(SessionStore.shared.user?.userId ?? 0)
                agora.join(channelId: ch, token: tk, uid: uid, profile: .communication)
            } catch let e as APIError {
                errorMsg = "接通失败：\(e.message)（\(e.code)）"
            } catch {
                errorMsg = "接通失败：\(error.localizedDescription)"
            }
            connecting = false
        }
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1).tint(.pink)
                .disabled(!params.enabled)
        }
    }
}
