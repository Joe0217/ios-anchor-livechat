import SwiftUI

/// H5 `pk-selecting-video-triple.vue`：选队阶段固定显示红位 / Live 中位 / 蓝位。
///
/// 左右两格复用稳定的 `PartyRoomBigSeatCell` 与 RTC UIView 池，避免状态切换时丢远端首帧；
/// 中间格始终保留其视频容器，摄像头关闭时以 Live 占位覆盖，和 H5 的 keep-alive DOM 一致。
struct PkSelectingVideoTripleView: View {
    let bigSeats: [PartyRoomSeat]
    @ObservedObject var battleStore: PartyBattleStore
    let isSelf: (PartyRoomSeat) -> Bool
    let isLocalCameraActive: Bool
    let camera: CameraManager?
    let engine: PartyRTCEngine
    let onSeatTap: (PartyRoomSeat) -> Void

    private let red = Color(red: 1.0, green: 0.15, blue: 0.7)
    private let blue = Color(red: 0.05, green: 0.43, blue: 1.0)

    private var leftSeat: PartyRoomSeat? { bigSeats.first }
    private var middleSeat: PartyRoomSeat? { bigSeats.count >= 3 ? bigSeats[1] : nil }
    private var rightSeat: PartyRoomSeat? { bigSeats.count >= 2 ? bigSeats.last : nil }

    private var rowHeight: CGFloat {
        UIScreen.main.bounds.width < 380 ? 116 : 140
    }

    private var horizontalInset: CGFloat {
        UIScreen.main.bounds.width < 380 ? 16 : 12
    }

    /// 与 H5 `liveStreamCount` 一致：只计占用且摄像头已开的所有视频位。
    private var activeLiveCount: Int {
        bigSeats.filter { $0.occupied && ($0.cameraEnabled ?? 0) == 1 }.count
    }

    private var middleShowsVideo: Bool {
        guard let seat = middleSeat, seat.occupied else { return false }
        return isSelf(seat) ? isLocalCameraActive : (seat.cameraEnabled ?? 0) == 1
    }

    var body: some View {
        HStack(spacing: 4) {
            if let leftSeat {
                teamTile(leftSeat, color: red)
            }

            centerSlot

            if let rightSeat, bigSeats.count >= 2 {
                teamTile(rightSeat, color: blue)
            }
        }
        .padding(.horizontal, horizontalInset)
        .frame(height: rowHeight)
    }

    private func teamTile(_ seat: PartyRoomSeat, color: Color) -> some View {
        PartyRoomBigSeatCell(
            seat: seat,
            isSelf: isSelf(seat),
            isLocalCameraActive: isLocalCameraActive,
            camera: camera,
            engine: engine,
            aspectRatio: nil,
            showsGiftValue: false
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSeatTap(seat) }
    }

    private var centerSlot: some View {
        ZStack {
            if let seat = middleSeat, seat.occupied {
                middleVideoKeepAlive(seat)
                    .opacity(middleShowsVideo ? 1 : 0)
                    .allowsHitTesting(false)
            }

            if middleShowsVideo, let seat = middleSeat {
                middleVideoHeader(seat)
                    .allowsHitTesting(false)
            } else {
                liveCard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 远端视图在摄像头关闭时也保留在层级中，避免 SELECTING -> RUNNING 后需要重新上麦才能恢复画面。
    @ViewBuilder
    private func middleVideoKeepAlive(_ seat: PartyRoomSeat) -> some View {
        if isSelf(seat), let camera {
            CameraPreview(camera: camera, agora: nil, scalingMode: .aspectFill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if let seatIndex = seat.seatIndex {
            PartyRemoteVideoView(seatIndex: seatIndex, engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Color.clear
        }
    }

    private func middleVideoHeader(_ seat: PartyRoomSeat) -> some View {
        VStack {
            HStack(spacing: 4) {
                Text(seat.nickname ?? L10n.Party.defaultUser)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 58, alignment: .leading)
                    .padding(.horizontal, 4)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.black.opacity(0.4)))
                Spacer(minLength: 0)
                if seat.isMicrophoneMuted {
                    CDNAssetImage("partyIconMicMuted")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }

    private var liveCard: some View {
        VStack(spacing: 4) {
            CDNAssetImage("partyVideoSeatEmpty")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
            Text(L10n.Party.Battle.live)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
            Text("\(activeLiveCount)")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
        )
    }
}
