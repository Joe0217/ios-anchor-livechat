import SwiftUI

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
        }
        .onDisappear {
            // 进入直播间时也会触发：直播间用自己的相机，这里停掉预览相机让出摄像头
            camera.stop()
        }
        .onReceive(params.objectWillChange) { _ in
            DispatchQueue.main.async { camera.renderer.updateParameters(params) }
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
                errorMsg = String(format: L10n.livePrepareErrorPrefix, e.message, e.code)
                isStarting = false
            } catch {
                errorMsg = String(format: L10n.livePrepareErrorGeneric, error.localizedDescription)
                isStarting = false
            }
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
