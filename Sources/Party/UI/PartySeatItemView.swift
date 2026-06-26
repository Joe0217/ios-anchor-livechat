import SwiftUI

/// 派对房单个麦位的渲染卡片（视频位 + 语聊位双形态）。
///
/// MVP 边界（spec v4 §1）：
/// - **自己**视频位：渲染 CameraPreview 本端预览（CameraManager v5.8 订阅模型，agora=nil 只本端不重复推帧）
/// - **他人**视频位**已占用 + 摄像头开**：PartyRemoteVideoView 渲染远端流（按 seatIndex UIView 池稳定）
/// - **他人**视频位**已占用 + 摄像头关**：远端 view 仍存在但 UI 头像 placeholder 覆盖（对齐 H5 `video-seat-cell.vue:61-63`，不调 muteRemoteVideoStream）
/// - 语聊位（自己/他人）：圆形头像 + 昵称 + 麦克风状态 icon
///
/// **P1-8（review 202606252033）**：本视图**不再 @ObservedObject store**，所需字段全部参数注入。
/// 9-12 个 cell 不再因 store 任一 @Published 字段（lastError/lastGiftEvent/imAlive 等）变化触发 re-render。
/// 唯一依然 capture 的是 PartyRTCEngine（PartyRemoteVideoView 的 representable 入参），它本身不是 ObservableObject。
struct PartySeatItemView: View {
    let seat: PartyRoomSeat
    let isSelf: Bool
    /// 本端摄像头是否激活（替代 store.isLocalCameraActive）
    let isLocalCameraActive: Bool
    /// 本端 CameraManager 实例（替代 store.camera）
    let camera: CameraManager?
    /// 远端 RTC（替代 store.rtc）—— PartyRTCEngine 非 ObservableObject，传引用不引入观测
    let engine: PartyRTCEngine

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.18))
                    .frame(width: 56, height: 56)

                // 视频位 + 他人 + 已占用：远端视频流（最底层，被头像/icon 覆盖时仍 setupRemoteVideo 不断流）
                if !isSelf, seat.seatType == 1, seat.occupied, let seatIndex = seat.seatIndex {
                    PartyRemoteVideoView(seatIndex: seatIndex, engine: engine)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                }

                // 头像 / 占位 icon
                if seat.occupied {
                    // 他人视频位 + 摄像头开 → 不覆盖远端画面（保持视频可见）
                    let shouldHideAvatar = (!isSelf && seat.seatType == 1 && (seat.cameraEnabled ?? 0) == 1)
                    if !shouldHideAvatar {
                        occupiedContent
                    }
                } else {
                    Image(systemName: seat.seatType == 1 ? "video" : "mic")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }

                // 视频位 + 自己 + 摄像头开 → 本端预览
                if isSelf, seat.seatType == 1, isLocalCameraActive, let cm = camera {
                    CameraPreview(camera: cm, agora: nil)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                }
            }
            // P1-7：用 .overlay(alignment:) 替代 .offset(x:y:)，alignment .topLeading / .bottomTrailing
            // SwiftUI 自动按 RTL 镜像（leading/trailing 语义），ar/tr 用户看到的角标位置与 H5/安卓对称一致
            .frame(width: 56, height: 56)
            .overlay(alignment: .topLeading) {
                seatNumberLabel
            }
            .overlay(alignment: .bottomTrailing) {
                if seat.occupied {
                    micIndicator
                }
            }

            Text(displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundColor(seat.occupied ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 麦位编号角标（顶 leading，RTL 自动镜像到顶 trailing 视觉位）
    private var seatNumberLabel: some View {
        Text("\(seat.seatIndex ?? 0)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(2)  // badge 距 Circle 边 2pt 内切（视觉比原 .offset(-22) 切边稍内移 ~4pt 但 RTL 自动镜像）
    }

    // MARK: - 子视图

    @ViewBuilder
    private var occupiedContent: some View {
        if let icon = seat.avatar, !icon.isEmpty, let url = URL(string: icon) {
            CachedAsyncImage(url: url, persistent: false) {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundColor(.gray.opacity(0.4))
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 56, height: 56)
                .foregroundColor(.gray.opacity(0.5))
        }
    }

    /// 麦克风状态指示（底 trailing，RTL 自动镜像到底 leading 视觉位）
    private var micIndicator: some View {
        let micOn = (seat.microphoneEnabled ?? 0) == 1 && (seat.seatMicrophoneEnabled ?? 0) == 1
        let sysName = micOn ? "mic.fill" : "mic.slash.fill"
        let color: Color = micOn ? .green : .red
        return Image(systemName: sysName)
            .font(.system(size: 11))
            .foregroundColor(.white)
            .padding(4)
            .background(Circle().fill(color))
            .padding(2)  // 距 Circle 边 2pt
    }

    private var displayName: String {
        if !seat.occupied { return L10n.Party.seatEmpty }
        if let n = seat.nickname, !n.isEmpty { return n }
        if let u = seat.userId, !u.isEmpty { return "ID\(u.suffix(4))" }
        return L10n.Party.seatOccupied
    }
}
