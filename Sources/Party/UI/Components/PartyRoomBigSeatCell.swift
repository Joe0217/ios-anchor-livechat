import SwiftUI

/// Party 房间三大麦位 cell（设计稿顶部大视频位 3 格铺满宽度）。
///
/// 视觉 3 态：
/// - 空位：粉紫圆环 + 中心椅子/相机图标 + 底部编号数字
/// - 占用 + 摄像头开：远端视频渲染（或本端 CameraPreview）+ 顶部名字胶囊 + 徽章 + Gems 值
/// - 占用 + 摄像头关：深灰底 + 头像，关闭视频图标叠在头像上方 + 顶部名字胶囊 + 徽章 + Gems 值
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

    /// PK-aware gems 显示（SELECTING 期强制 0，对齐 H5 audio-wrap.vue :93-97）
    /// cell 直接订阅 battleStore 触发 SELECTING → RUNNING 时 gems 数字自动重绘
    @ObservedObject private var battleStore = PartyBattleStore.shared

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
            if !isLockedEmptySeat, seat.isMicrophoneMuted {
                microphoneMutedBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
            }
            // v15：说话中呼吸边框（覆盖在视频/头像上层，clipped 里保证不越界）
            PartyBigSeatSpeakingBorder(
                isSpeaking: isSpeaking && seat.occupied,
                cornerRadius: 0
            )
            // F 里程碑（2026-07-17）emoji SVGA overlay（对齐 H5 expression-receiver.vue 挂麦位卡片内）
            // - 空位 seat.userId 为 nil/empty → PartyEmojiSVGAOverlay 内部自动隐藏，无副作用
            // - 覆盖顶层不拦截 tap（allowsHitTesting 已 false）· 单段播完停留末帧
            PartyEmojiSVGAOverlay(seatUserId: seat.userId)
            // Party 2049 静态礼物收礼效果（H5 gift-animator-receiver，50pt / 1.5s）。
            PartyGiftReceiverEffect(userId: seat.userId, size: 50)
            // 主播周任务奖励：1023 到达后在本人当前麦位播放宝石效果，再展示奖励窗。
            PartyWeeklyTaskRewardSeatEffect(isSelf: isSelf, size: 58)
            // v10：overlayMicIndicator 移除，mic 图标已迁到 nameChip 名字后面（用户 2026-07-13 requirement）
        }
    }

    /// v17：MC 装饰双侧翅膀显示条件 —— 空位 or (占用 + 麦关)（对齐 H5 main-wrap.vue L264 v-if）
    /// 摄像头开的占用 MC 位显示视频不叠翅膀（避免遮挡视频画面）
    private var showMcWings: Bool {
        if !seat.occupied { return true }
        if seat.isMicrophoneMuted { return true }
        return false
    }

    /// v17：MC 位综合装饰层（4-stop 彩边 + 顶部徽章 + 双侧翅膀 + cameraOff 头像框）
    @ViewBuilder
    private var mcOverlay: some View {
        if seat.isMCSeat, !isLockedEmptySeat {
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

            // 本地徽章保证弱网或远端视觉资源未命中时，MC 身份仍明确可见。
            PartyMCSeatBadge()
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
           !isVideoActiveOnThisSeat,
           !isCameraOffVideoSeat {
            // 语聊位头像可显示装饰框；视频位关闭摄像头时改用纯头像 + 大号关闭视频覆盖标识。
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

    private var isCameraOffVideoSeat: Bool {
        seat.occupied && seat.seatType == 1 && !isVideoActiveOnThisSeat
    }

    // MARK: - Layers

    @ViewBuilder
    private var background: some View {
        if seat.isMCSeat, !isLockedEmptySeat {
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
                CameraPreview(camera: cm, agora: nil, scalingMode: .aspectFill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if !isSelf, let idx = seat.seatIndex, (seat.cameraEnabled ?? 0) == 1 {
                PartyRemoteVideoView(seatIndex: idx, engine: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                cameraOffPlaceholder
            }
        }
    }

    private var cameraOffPlaceholder: some View {
        // 视频关闭不是空位：保留用户头像；关闭视频图标作为头像右上角的顶层状态标识。
        // 外环和头像同心；此状态明确不显示头像框。
        ZStack {
            Image("partySeatRing")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)

            AvatarView(urlString: seat.avatar, size: 64, kind: .user, disablesTap: true)
                .clipShape(Circle())
                // 大号状态图标直接覆盖头像右上区域，而非悬在头像外侧。
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.black.opacity(0.72)))
                        .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .offset(x: 8, y: -8)
                        .accessibilityHidden(true)
                }
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
                // idx 底部独立布局（不影响 ring 中心位置）；锁位也保留编号。
                if let idx = seat.seatIndex {
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
        // 锁位不显示空位切图中的沙发，只保留圆环与中心锁图标。
        Image(isLockedEmptySeat ? "partySeatRing" : emptyRingAssetName)
            .resizable()
            .scaledToFit()
            .frame(width: 72, height: 72)
    }

    /// 锁位视觉优先级最高：空位被锁时只显示锁与编号。
    private var isLockedEmptySeat: Bool {
        !seat.occupied && (seat.lockFlag ?? 0) == 1
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

    /// 禁麦状态需要覆盖视频位与音频位，避免只有小麦位能看见该状态。
    private var microphoneMutedBadge: some View {
        Image("partyIconMicMuted")
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .padding(4)
            .background(Circle().fill(Color.black.opacity(0.35)))
            .accessibilityLabel(Text(L10n.Party.seatMuted))
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
        // PK 期 SELECTING 强制归零（对齐 H5 audio-wrap.vue :93-97 seatScore）
        PartyNumberFormat.compact(PartyBattleSeatDisplay.giftValueCountInt(for: seat))
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
