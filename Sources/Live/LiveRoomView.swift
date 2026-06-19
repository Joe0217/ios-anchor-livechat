import SwiftUI

/// 直播间（对应 H5 liveRoom）：用 beginLiveRoom 返回的真实频道/token 推流 + 真实心跳 + 真实下播。
/// 公屏 / 在线人数 / 礼物等依赖云信聊天室的部分仍为占位（云信为后续阶段）。
struct LiveRoomView: View {
    let roomInfo: LiveRoomInfo
    let title: String
    @ObservedObject var beauty: BeautyParameters

    @StateObject private var camera = CameraManager()
    @StateObject private var agora = AgoraManager()
    @StateObject private var nim = NIMChatroomManager()
    @Environment(\.dismiss) private var dismiss

    @State private var authorized = false
    @State private var showBeauty = false
    @State private var elapsed = 0

    /// 1s 节拍：累计直播时长，并每 6s 调一次 liveHeartBeatV2 维持直播态
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if authorized {
                CameraPreview(camera: camera, agora: agora).ignoresSafeArea()
            }
            VStack(spacing: 12) {
                topBar
                publicScreen
                Spacer()
                bottomBar
            }
            .padding()
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showBeauty) { beautyPanel }
        .onAppear {
            camera.renderer.updateParameters(beauty)
            CameraManager.requestAccess { ok in
                authorized = ok
                if ok { camera.start() }
            }
            // 用 beginLiveRoom 返回的真实凭证加入声网（主播推流）
            agora.join(channelId: roomInfo.agoraChannelId ?? "",
                       token: roomInfo.rtcToken ?? "",
                       uid: UInt(roomInfo.userId ?? 0))
            // 加入云信聊天室（公屏/在线人数）
            if let yx = roomInfo.yxRoomId, let user = SessionStore.shared.user {
                nim.enter(roomId: "\(yx)",
                          nickname: user.nickname ?? "主播",
                          account: user.yxAccid ?? "",
                          token: user.imToken ?? "")
            }
        }
        .onDisappear {
            agora.leave()
            nim.leave()
            camera.stop()
        }
        .onReceive(beauty.objectWillChange) { _ in
            DispatchQueue.main.async { camera.renderer.updateParameters(beauty) }
        }
        .onReceive(ticker) { _ in
            guard agora.state == .joined else { return }
            elapsed += 1
            // 每 6s 真实心跳（对应 H5 liveHeartBeatV2），不维持后端会判掉线下播
            if elapsed % 6 == 0, let roomId = roomInfo.id {
                Task { try? await LiveService.heartbeat(roomId: roomId) }
            }
        }
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
            // 在线人数（云信聊天室）
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.caption2)
                Text("\(nim.onlineCount)").font(.caption)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
        }
    }

    // MARK: - 公屏消息（占位）

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
            Spacer()
            Button { endLive() } label: {
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

    /// 对应 H5 handleLiveEnd：离开声网 + 调 endLiveRoom 真下播 + 返回
    private func endLive() {
        Task { try? await LiveService.endLiveRoom() }
        agora.leave()
        camera.stop()
        dismiss()
    }
}
