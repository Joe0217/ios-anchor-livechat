import SwiftUI

/// Party 房间三大麦位 cell（设计稿顶部大视频位 3 格铺满宽度）。
///
/// 视觉 3 态：
/// - 空位：粉紫圆环 + 中心椅子/相机图标 + 底部编号数字
/// - 占用 + 摄像头开：远端视频渲染（或本端 CameraPreview）+ 顶部名字胶囊 + 徽章 + Gems 值
/// - 占用 + 摄像头关：深灰底 + 相机 off 图标 + 顶部名字胶囊 + 徽章 + Gems 值
///
/// 参数注入 pattern（对齐 P1-8：不订阅 store 任一 @Published）。
struct PartyRoomBigSeatCell: View {
    let seat: PartyRoomSeat
    let isSelf: Bool
    let isLocalCameraActive: Bool
    let camera: CameraManager?
    let engine: PartyRTCEngine

    var body: some View {
        ZStack {
            background
            videoLayer
            emptyLayer
            overlayNameAndGems
            overlayMicIndicator
        }
        // 设计稿测量：大位单元宽 125pt × 高 220pt ≈ 9:16 竖屏比例
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipped()
    }

    // MARK: - Layers

    private var background: some View {
        // 占用：深底承接视频；空位：**white 15% 透明**（设计稿 Component 7 视频位空位底色）
        Rectangle().fill(
            seat.occupied
                ? Theme.Palette.partyRoomSeatFill
                : Color.white.opacity(0.15)
        )
    }

    @ViewBuilder
    private var videoLayer: some View {
        if seat.occupied, seat.seatType == 1 {
            if isSelf, isLocalCameraActive, let cm = camera {
                CameraPreview(camera: cm, agora: nil)
                    .clipped()
            } else if !isSelf, let idx = seat.seatIndex, (seat.cameraEnabled ?? 0) == 1 {
                PartyRemoteVideoView(seatIndex: idx, engine: engine)
                    .clipped()
            } else {
                cameraOffPlaceholder
            }
        }
    }

    private var cameraOffPlaceholder: some View {
        // v5：图标改用 Component 7.png（partySeatRing 深粉简约环，用户 2026-07-11 correction）
        // 与空位 partyVideoSeatEmpty(上视频位.png) 视觉区分；位置与 emptyLayer 中 emptyRing 完全对齐
        VStack(spacing: 4) {
            Spacer()
            Image("partySeatRing")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
            Spacer()
            // emptyLayer 底部 Text(seatIndex) + padding.bottom(12) 综合 ≈ 32pt；
            // 此处放透明占位保持 icon 中心 y-坐标与空位 emptyRing 一致
            Color.clear.frame(height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空位/摄像头关 共用的环切图：优先 partyVideoSeatEmpty（上视频位.png）
    /// fallback 到 partySeatEmpty（Component 7(2)）→ partySeatRing 兜底
    private var emptyRingAssetName: String {
        if UIImage(named: "partyVideoSeatEmpty") != nil { return "partyVideoSeatEmpty" }
        if UIImage(named: "partySeatEmpty") != nil { return "partySeatEmpty" }
        return "partySeatRing"
    }

    @ViewBuilder
    private var emptyLayer: some View {
        if !seat.occupied {
            VStack(spacing: 4) {
                Spacer()
                emptyRing
                Spacer()
                if let idx = seat.seatIndex {
                    Text("\(idx)")
                        .font(Theme.Typography.partyRoomEmptyIndex)
                        .foregroundColor(Theme.Palette.partyRoomEmptyIndex)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private var emptyRing: some View {
        // v3：视频位专用空位图标 partyVideoSeatEmpty（上视频位.png，用户 2026-07-11 correction）
        // fallback 链共享自 emptyRingAssetName（partyVideoSeatEmpty → partySeatEmpty → partySeatRing）
        Image(emptyRingAssetName)
            .resizable()
            .scaledToFit()
            .frame(width: 72, height: 72)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlayNameAndGems: some View {
        if seat.occupied {
            VStack {
                HStack {
                    nameChip
                    Spacer()
                }
                Spacer()
                HStack {
                    gemsChip
                    Spacer()
                }
            }
            .padding(6)
        }
    }

    private var nameChip: some View {
        HStack(spacing: 4) {
            Text(seat.nickname ?? L10n.Party.defaultUser)
                .font(Theme.Typography.partyRoomSeatName)
                .foregroundColor(Theme.Palette.partyRoomSeatNameText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 80, alignment: .leading)
            Image("partyBadgeBubble")
                .resizable().scaledToFit()
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Metric.partyRoomSeatNameHPadding)
        .padding(.vertical, Theme.Metric.partyRoomSeatNameVPadding)
        .background(
            Capsule().fill(Theme.Palette.partyRoomSeatNameFill)
        )
    }

    private var gemsChip: some View {
        HStack(spacing: 3) {
            Image("partyGems")
                .resizable().scaledToFit()
                .frame(width: Theme.Metric.partyRoomGemsIconSize,
                       height: Theme.Metric.partyRoomGemsIconSize)
            Text(formattedGems)
                .font(Theme.Typography.partyRoomGemsNumber)
                .foregroundColor(Theme.Palette.partyRoomGemsText)
        }
        .padding(.horizontal, Theme.Metric.partyRoomGemsHPadding)
        .padding(.vertical, Theme.Metric.partyRoomGemsVPadding)
        .background(
            Capsule().fill(Theme.Palette.partyRoomGemsFill)
        )
    }

    private var formattedGems: String {
        PartyNumberFormat.compact(seat.giftValueCount ?? 0)
    }

    @ViewBuilder
    private var overlayMicIndicator: some View {
        if seat.occupied {
            let micOff = (seat.microphoneEnabled ?? 0) != 1 || (seat.seatMicrophoneEnabled ?? 0) != 1
            if micOff {
                VStack {
                    HStack {
                        Spacer()
                        Image("partyIconMicMuted")
                            .resizable().scaledToFit()
                            .frame(width: 22, height: 22)
                            .padding(6)
                    }
                    Spacer()
                }
            }
        }
    }
}

/// 派对房数字紧凑格式（888 / 8.88M / 88.88K）。
///
/// 后端 giftValueCount 是 Int（钻石累计），前端按 K/M 分档显示。
enum PartyNumberFormat {
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return String(format: "%.2fM", m)
        }
        if n >= 10_000 {
            let k = Double(n) / 1_000
            return String(format: "%.2fK", k)
        }
        return "\(n)"
    }
}
