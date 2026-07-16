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
    /// v12：可选 aspect ratio（宽/高）
    /// - `nil`：外层用 `.frame(...)` 显式定尺寸（1 视频位模板走此路径）
    /// - `9.0/16.0`（默认）：3 视频位模板 125×220 竖屏
    /// - `6.0/5.0`：6 视频位模板对齐 H5 `aspect-[6/5]`
    let aspectRatio: CGFloat?
    /// v15：是否正在说话（PartyStore.isSpeaking 派生）
    let isSpeaking: Bool

    init(
        seat: PartyRoomSeat,
        isSelf: Bool,
        isLocalCameraActive: Bool,
        camera: CameraManager?,
        engine: PartyRTCEngine,
        aspectRatio: CGFloat? = 9.0 / 16.0,
        isSpeaking: Bool = false
    ) {
        self.seat = seat
        self.isSelf = isSelf
        self.isLocalCameraActive = isLocalCameraActive
        self.camera = camera
        self.engine = engine
        self.aspectRatio = aspectRatio
        self.isSpeaking = isSpeaking
    }

    var body: some View {
        if let ratio = aspectRatio {
            stackContent
                .aspectRatio(ratio, contentMode: .fit)
                .clipped()
        } else {
            stackContent
                .clipped()
        }
    }

    private var stackContent: some View {
        ZStack {
            background
            videoLayer
            emptyLayer
            headFrameOverlay
            // v17：MC 位视觉（对齐 H5 main-wrap.vue `.mc-bg` + `icon_mic_mc_result` + `icon_mic_zs_left/right`）
            mcOverlay
            overlayNameAndGems
            // v15：说话中呼吸边框（覆盖在视频/头像上层，clipped 里保证不越界）
            PartyBigSeatSpeakingBorder(
                isSpeaking: isSpeaking && seat.occupied,
                cornerRadius: 0
            )
            // v10：overlayMicIndicator 移除，mic 图标已迁到 nameChip 名字后面（用户 2026-07-13 requirement）
        }
    }

    /// v17：MC 位视觉判定 —— `seat.isHostSeat == 1`（对齐 H5 `roomSeatListCom[index]?.isHostSeat === 1`）
    private var isMcSeat: Bool { (seat.isHostSeat ?? 0) == 1 }

    /// v17：MC 装饰双侧翅膀显示条件 —— 空位 or (占用 + 麦关)（对齐 H5 main-wrap.vue L264 v-if）
    /// 摄像头开的占用 MC 位显示视频不叠翅膀（避免遮挡视频画面）
    private var showMcWings: Bool {
        if !seat.occupied { return true }
        if (seat.microphoneEnabled ?? 1) == 0 { return true }
        return false
    }

    /// v17：MC 位综合装饰层（4-stop 彩边 + 顶部徽章 + 双侧翅膀 + cameraOff 头像框）
    @ViewBuilder
    private var mcOverlay: some View {
        if isMcSeat {
            // 4-stop 彩边（H5 border-image linear-gradient 150deg）
            Rectangle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(hex: 0xFFFCFA),
                            Color(hex: 0xFF9438, opacity: 0.5),
                            Color(hex: 0xFF0090, opacity: 0),
                            Color(hex: 0xFE00DE, opacity: 0.5),
                            Color(hex: 0xFF84F0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .allowsHitTesting(false)

            // 顶部徽章 icon_mic_mc_result（H5 empty: top--16 h-12 w-24；占用+cameraOff: 中心；简化为顶部居中 -6pt）
            CachedAsyncImage(
                url: URL(string: "https://img.hnhily.link/mstatic/party/icon_mic_mc_result.webp"),
                contentMode: .fit,
                persistent: true
            ) { Color.clear }
            .frame(width: 44, height: 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .offset(y: -6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            // 双侧装饰翅膀（H5 L264-267：空位 op-45，占用 op-100）
            if showMcWings {
                mcWings
                    .opacity(seat.occupied ? 1.0 : 0.45)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // 头像框 border_mc（cameraOff 时叠 —— H5 L283：只在头像可见时显示）
            if seat.occupied, !isVideoActiveOnThisSeat {
                CachedAsyncImage(
                    url: URL(string: "https://img.hnhily.link/mstatic/party/border_mc.webp"),
                    contentMode: .fit,
                    persistent: true
                ) { Color.clear }
                .frame(width: 76, height: 76)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// v17：MC 双侧翅膀 —— H5 L265-266：左 h75 w80 inset-is--11 bottom--2；右 h60 w57 inset-ie-0 bottom--2
    private var mcWings: some View {
        ZStack {
            // 左翅（bottom-leading，向左偏 -11pt）
            CachedAsyncImage(
                url: URL(string: "https://img.hnhily.link/mstatic/party/icon_mic_zs_left.webp"),
                contentMode: .fit,
                persistent: true
            ) { Color.clear }
            .frame(width: 60, height: 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .offset(x: -8, y: 2)

            // 右翅（bottom-trailing）
            CachedAsyncImage(
                url: URL(string: "https://img.hnhily.link/mstatic/party/icon_mic_zs_right.webp"),
                contentMode: .fit,
                persistent: true
            ) { Color.clear }
            .frame(width: 44, height: 46)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: 0, y: 2)
        }
    }

    /// v16：麦位头像装饰框（对齐 H5 `seat-roster-item.vue` `<head-frame :user-data="roomSeatItem">`）
    /// 只在有人 + 摄像头关（占用视频层空缺时）叠 —— 视频开时头像框被视频占据无需装饰
    /// 视频位 seat.seatType==1 且 cameraEnabled==1 时不显示；语聊/视频关摄像头时显示
    @ViewBuilder
    private var headFrameOverlay: some View {
        if seat.occupied,
           let raw = seat.headFrame, !raw.isEmpty,
           !isVideoActiveOnThisSeat {
            // 视频位关摄像头 + 语聊位 → 中心头像位置贴装饰框
            // 尺寸参考 emptyRing/cameraOffPlaceholder 的 72pt，装饰框略大 +8 让 ring 环绕头像
            HeadFrameView(urlString: raw, size: 80)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 判断本 seat 是否正在展示实时视频（本端 CameraPreview 或 远端 PartyRemoteVideoView）
    /// 视频活跃时装饰框会被视频占据 → 不叠（对齐 H5 视频位有摄像头时不显示 head-frame）
    private var isVideoActiveOnThisSeat: Bool {
        guard seat.seatType == 1 else { return false }
        if isSelf { return isLocalCameraActive }
        return (seat.cameraEnabled ?? 0) == 1
    }

    // MARK: - Layers

    @ViewBuilder
    private var background: some View {
        if isMcSeat {
            // v17：MC 底色 `.mc-bg`（H5 linear-gradient 17deg #1F003D 0%, #440127 51.53%, #000000 100%）
            // 17deg 近似垂直，用 top→bottom LinearGradient 近似
            Rectangle().fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x1F003D), location: 0.0),
                        .init(color: Color(hex: 0x440127), location: 0.5153),
                        .init(color: Color(hex: 0x000000), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        } else if seat.occupied {
            // 占用：深底承接视频
            Rectangle().fill(Theme.Palette.partyRoomSeatFill)
        } else {
            // 空位：**white 15% 透明**（设计稿 Component 7 视频位空位底色）
            Rectangle().fill(Color.white.opacity(0.15))
        }
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
        // v7.4：ring 居中于 ZStack，与 headFrameOverlay 同 y 中心（用户 2026-07-14 requirement）
        // 与 emptyLayer 同款布局，保持空位/占用关摄像头/头像占用三态位置一致
        ZStack {
            Image("partySeatRing")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
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
            // v7.4：Ring 居中于 ZStack（与 headFrameOverlay 同 y 中心），idx 独立底部布局
            // 原 VStack + Spacer 均分因底部 idx text 挤下让 ring 中心偏上，与占用态头像位置不齐
            ZStack {
                emptyRing
                // v15：锁麦位在 emptyRing 中心叠 lock icon
                if (seat.lockFlag ?? 0) == 1 {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .accessibilityHidden(true)
                }
                // idx 底部独立布局（不影响 ring 中心位置）
                if let idx = seat.seatIndex, (seat.lockFlag ?? 0) != 1 {
                    VStack {
                        Spacer()
                        Text("\(idx)")
                            .font(Theme.Typography.partyRoomEmptyIndex)
                            .foregroundColor(Theme.Palette.partyRoomEmptyIndex)
                            .padding(.bottom, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // v16.8：昵称后身份标识（对齐 H5 audio-wrap.vue:172 / video-seat-cell.vue:59）
            // roomRoleType=1 → 房主 mic icon / roomRoleType=2 → 房管 icon / 3 或 nil → 不显示
            PartyRoleBadge(roomRoleType: seat.roomRoleType, size: 12)
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
        PartyNumberFormat.compact(seat.giftValueCountInt)
    }

    // v10：overlayMicIndicator 已删除，mic 图标改到 nameChip 内名字后面
}

/// 派对房数字紧凑格式（888 / 8.88M / 88.88K）。
///
/// 后端 giftValueCount 是 Int（钻石累计），前端按 K/M 分档显示。
enum PartyNumberFormat {
    /// 对齐 H5 header-wrap.vue `fmtNum`：
    /// - <1_000 → 原样（v11：从 <10_000 收紧）
    /// - <1_000_000 → nK（整数不带小数；否则 1 位小数）
    /// - >=1_000_000 → nM（整数不带小数；否则 1 位小数）
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(m))M"
                : String(format: "%.1fM", m)
        }
        if n >= 1_000 {
            let k = Double(n) / 1_000
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(k))K"
                : String(format: "%.1fK", k)
        }
        return "\(n)"
    }
}
