import SwiftUI

/// 派对房单个麦位的渲染卡片（视频位 + 语聊位双形态）。
///
/// MVP 边界（spec §1.4.7）：
/// - **自己**视频位：渲染 CameraPreview 本端预览（CameraManager v5.8 订阅模型，agora=nil 只本端不重复推帧）
/// - **他人**视频位：仅头像 + 摄像头状态 icon（远端视频流渲染推 F 期）
/// - 语聊位（自己/他人）：圆形头像 + 昵称 + 麦克风状态 icon
struct PartySeatItemView: View {
    let seat: PartyRoomSeat
    let isSelf: Bool
    /// store 需要传入而非用 .shared，方便单测/Preview 注入
    @ObservedObject var store: PartyStore

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.18))
                    .frame(width: 56, height: 56)

                if seat.occupied {
                    occupiedContent
                } else {
                    Image(systemName: seat.seatType == 1 ? "video" : "mic")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }

                // 麦位标签角标
                Text("\(seat.seatIndex ?? 0)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .offset(x: -22, y: -22)

                // 麦克风状态（仅在被占用时显示）
                if seat.occupied {
                    micIndicator.offset(x: 22, y: 22)
                }

                // 视频位 + 自己 + 摄像头开 → 本端预览
                if isSelf, seat.seatType == 1, store.isLocalCameraActive, let cm = store.camera {
                    CameraPreview(camera: cm, agora: nil)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                }
            }

            Text(displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundColor(seat.occupied ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
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

    private var micIndicator: some View {
        let micOn = (seat.microphoneEnabled ?? 0) == 1 && (seat.seatMicrophoneEnabled ?? 0) == 1
        let sysName = micOn ? "mic.fill" : "mic.slash.fill"
        let color: Color = micOn ? .green : .red
        return Image(systemName: sysName)
            .font(.system(size: 11))
            .foregroundColor(.white)
            .padding(4)
            .background(Circle().fill(color))
    }

    private var displayName: String {
        if !seat.occupied { return "空麦位" }
        if let n = seat.nickname, !n.isEmpty { return n }
        if let u = seat.userId, !u.isEmpty { return "ID\(u.suffix(4))" }
        return "麦上用户"
    }
}
