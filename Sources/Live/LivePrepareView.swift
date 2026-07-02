import SwiftUI
import UserNotifications

/// 开播准备页（对应 H5 liveSetting）：设置标题 + 美颜预览，点击开始直播调用真实 beginLiveRoom 后进入直播间。
struct LivePrepareView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var params = BeautyParameters()
    @State private var title = ""
    @State private var authorized = false
    @State private var errorMsg = ""
    @State private var isStarting = false
    @State private var roomInfo: LiveRoomInfo?
    @State private var goLive = false

    private var displayTitle: String { title.isEmpty ? L10n.livePrepareDefaultTitle : title }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if authorized {
                CameraPreview(camera: camera).ignoresSafeArea()  // 预览不推流
            }
            VStack {
                Spacer()
                settingsPanel
            }
            .padding()
        }
        .navigationTitle(L10n.livePrepareNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $goLive) {
            if let roomInfo {
                LiveRoomView(roomInfo: roomInfo, title: displayTitle, beauty: params)
            }
        }
        .onAppear {
            camera.renderer.updateParameters(params)
            CameraManager.requestAccess { ok in
                authorized = ok
                if ok { camera.start() }
            }
            // BackgroundMonitor "切后台超限强制下播" 用本地通知在 1:40 提醒用户回 App。
            // 权限前置到开播前静默请求（notDetermined 时才弹系统 dialog）；
            // 拒绝也不影响后续开播（willEnterForeground 结算主路径不依赖通知）。
            requestNotificationAuthorizationIfNeeded()
        }
        .onDisappear {
            // 进入直播间时也会触发：直播间用自己的相机，这里停掉预览相机让出摄像头
            camera.stop()
        }
        // slider 拖动 30-60Hz 通过 objectWillChange publish；throttle 到 60ms
        // 与 LiveRoomView.BeautyPanel 同款处理，避免 body 整树重算 + renderer 更新任务堆积
        .onReceive(
            params.objectWillChange
                .throttle(for: 0.06, scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            camera.renderer.updateParameters(params)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.livePreparePanelTitle).font(.headline).foregroundStyle(.white)

            TextField("", text: $title,
                      prompt: Text(L10n.livePrepareTitlePlaceholder).foregroundColor(.white.opacity(0.5)))
                .foregroundStyle(.white)
                .padding(10)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Toggle(L10n.livePrepareBeautyToggle, isOn: $params.enabled).tint(.pink).foregroundStyle(.white)
            slider(L10n.livePrepareSliderBlur, value: $params.blur)
            slider(L10n.livePrepareSliderWhiten, value: $params.whiten)

            if !errorMsg.isEmpty {
                Text(errorMsg).font(.footnote).foregroundStyle(.red)
            }

            Button {
                startLive()
            } label: {
                HStack(spacing: 8) {
                    if isStarting { ProgressView().tint(.white) }
                    Text(isStarting ? L10n.livePrepareStarting : L10n.livePrepareStart)
                        .font(.headline).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Color.pink, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isStarting)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    /// 对应 H5 handleStartLive：getMyLiveRoom（拿封面/配置）→ beginLiveRoom（真建房）
    private func startLive() {
        // A 收尾：userType 守卫。userType==2 已审核主播才允许开播；
        // ==9 代理账号 / nil 或其他值 视为未审核完成（H5 同样限制非主播账号入口）。
        guard let user = SessionStore.shared.user else {
            errorMsg = L10n.livePrepareGuardUnverified
            return
        }
        if user.userType != 2 {
            errorMsg = (user.userType == 9) ? L10n.livePrepareGuardAgent : L10n.livePrepareGuardUnverified
            return
        }
        isStarting = true
        errorMsg = ""
        Task { @MainActor in
            do {
                // getMyLiveRoom + beginLiveRoom 合并，拿完整频道/token
                let info = try await LiveService.startLive(liveDescribe: displayTitle)
                guard let ch = info.agoraChannelId, !ch.isEmpty,
                      let tk = info.rtcToken, !tk.isEmpty else {
                    errorMsg = L10n.livePrepareErrorNoChannel
                    isStarting = false
                    return
                }
                roomInfo = info
                isStarting = false
                goLive = true
            } catch let e as APIError {
                // 1004 挤下线 / 1005 token 失效已由 APIClient → SessionStore observer 链路
                // 统一登出 + 弹错误；这里短路 return，避免与 SessionStore.errorMessage 双重显示，
                // 也避免随后用户重试触发 user==nil 守卫，把 errorMsg 覆盖为「未审核」误导。
                if e.code == "1004" || e.code == "1005" {
                    isStarting = false
                    return
                }
                errorMsg = String(format: L10n.livePrepareErrorPrefix, e.message, e.code)
                isStarting = false
            } catch {
                errorMsg = String(format: L10n.livePrepareErrorGeneric, error.localizedDescription)
                isStarting = false
            }
        }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
            Slider(value: value, in: 0...1).tint(.pink).disabled(!params.enabled)
        }
    }
}
