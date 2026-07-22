import SwiftUI

/// Party 房间小麦位 cell（设计稿下方 5×2 排列的 10 个语聊位）。
///
/// 视觉：
/// - 空位：粉紫圆环 + 中心椅子/麦克风图标 + 底部数字
/// - 占用：圆形头像（带徽章装饰）+ 昵称 + Gems 数字
/// - v15：说话中 → 头像外圈 pulse ring（对齐 H5 PlayVolume 序列帧的 SwiftUI 等效）
struct PartyRoomSmallSeatCell: View {
    /// v17：cell 尺寸变体（对齐 H5 audio-wrap.vue `size="sm" | "default"`）
    /// - `.default`：标准头像 46pt（默认，用于 5/10/15/20 麦模板）
    /// - `.sm`：小头像 35pt（30 麦模板 + 小屏 <380 缩小）
    enum SizeVariant { case `default`, sm }

    let seat: PartyRoomSeat
    /// 是否为当前主播；周任务奖励效果只在本人的当前麦位播放。
    var isSelf: Bool = false
    /// v15：是否正在说话（PartyStore.isSpeaking 派生）；空位时恒 false
    var isSpeaking: Bool = false
    /// v17：尺寸变体（对齐 H5 30 麦 sm + @media(<380) 缩小）
    var sizeVariant: SizeVariant = .default

    /// PK-aware gems 显示（SELECTING 期强制 0，对齐 H5 audio-wrap.vue :93-97）
    /// cell 直接订阅 battleStore 触发 SELECTING → RUNNING 时 gems 数字自动重绘
    @ObservedObject private var battleStore = PartyBattleStore.shared

    /// v17：avatar 尺寸按 variant 派生 —— sm=35pt / default=46pt（对齐 H5 :deep(.audio-avatar-inner) 35.52px）
    private var avatarSize: CGFloat {
        sizeVariant == .sm ? 35 : Theme.Metric.partyRoomSmallSeatAvatar
    }

    var body: some View {
        VStack(spacing: Theme.Metric.partyRoomSmallSeatVGap) {
            avatarStack
            occupiedFooter
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 头像

    private var avatarStack: some View {
        ZStack {
            // v2：空位用 Component 7 切图（`partySeatEmpty`）；占用状态继续用 partySeatRing 装饰环
            // 锁位不显示空位切图内的沙发，仅保留圆环和锁图标。
            Image(seat.occupied || isLockedEmptySeat
                  ? "partySeatRing"
                  : (UIImage(named: "partySeatEmpty") != nil ? "partySeatEmpty" : "partySeatRing"))
                .resizable()
                .scaledToFit()
                .frame(width: avatarSize + 8,
                       height: avatarSize + 8)
                .accessibilityHidden(true)

            avatarContent

            // v16：占用态头像装饰框（对齐 H5 `seat-roster-item.vue` head-frame 组件）
            // 空位不叠（视觉焦点让给 partySeatEmpty 空位切图）
            if seat.occupied, let raw = seat.headFrame, !raw.isEmpty {
                HeadFrameView(urlString: raw,
                              size: avatarSize + 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // v15：说话中 pulse ring（与头像同心，尺寸略大于 partySeatRing 装饰环）
            PartySmallSeatSpeakingRing(
                isSpeaking: isSpeaking && seat.occupied,
                diameter: avatarSize + 10
            )

            // v15：锁麦位视觉标识（对齐 H5 空位 lockFlag=1 显示 lock icon 阻止上麦）
            // 只在空位显示，占用位不显示（占用时 lockFlag 无实际业务约束）
            if isLockedEmptySeat {
                Image(systemName: "lock.fill")
                    .font(.system(size: sizeVariant == .sm ? 15 : 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .accessibilityHidden(true)
            }

            // F 里程碑（2026-07-17）emoji SVGA overlay（对齐 H5 expression-receiver.vue 挂麦位内）
            // - 空位 seat.userId 为 nil/empty → PartyEmojiSVGAOverlay 内部自动隐藏
            // - 覆盖头像上方 · 尺寸 = 头像装饰环大小 · 播完停留末帧
            PartyEmojiSVGAOverlay(seatUserId: seat.userId)
                .frame(width: avatarSize + 12, height: avatarSize + 12)

            // Party 2049 静态礼物收礼效果（H5 gift-animator-receiver）。
            PartyGiftReceiverEffect(userId: seat.userId, size: 50)
            PartyWeeklyTaskRewardSeatEffect(isSelf: isSelf, size: avatarSize + 18)

            // v13：badgeCorner (partyBadgeBubble 右上角泡泡) 去掉（用户 2026-07-13 requirement）
            // v10：mic 图标移到 footer 名字后面（去掉 bottom-left corner overlay）
        }
        .frame(width: avatarSize + 12,
               height: avatarSize + 12)
        // v17：禁麦/自身关麦时右下角显示禁麦图标（对齐 H5 `audio-wrap.vue:167`
        // `(!microphoneEnabled && userId) || !seatMicrophoneEnabled` 语义）。
        // 默认 ??1（假定开麦），避免后端漏字段时误显。
        .overlay(alignment: .bottomTrailing) {
            if !isLockedEmptySeat, seat.isMicrophoneMuted {
                Image("partyIconMicMuted")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(Text(L10n.Party.seatMuted))
            }
        }
        .overlay(alignment: .topLeading) {
            if !isLockedEmptySeat, seat.isMCSeat {
                PartyMCSeatBadge(compact: true)
                    .offset(x: -3, y: -3)
            }
        }
    }

    private var isLockedEmptySeat: Bool {
        !seat.occupied && (seat.lockFlag ?? 0) == 1
    }

    @ViewBuilder
    private var avatarContent: some View {
        if seat.occupied {
            // v10：占用态头像走公共组件 AvatarView（对齐 prefer-shared-component-over-adhoc rule）
            // AvatarView 自带默认兜底图 + CDN + 缓存，不再手写 CachedAsyncImage
            AvatarView(urlString: seat.avatar,
                       size: avatarSize,
                       kind: .user)
        } else {
            // 空位保持透明，仅外层 partySeatRing 圆环可见（让房间底图透出）
            Color.clear
                .frame(width: avatarSize,
                       height: avatarSize)
        }
    }

    // v13：badgeCorner 移除（右上角泡泡装饰去掉，用户 2026-07-13）
    // v11：micMutedCorner 移除；mic 图标彻底去掉（用户 2026-07-13）

    // MARK: - Footer

    @ViewBuilder
    private var occupiedFooter: some View {
        if seat.occupied {
            VStack(spacing: 2) {
                // v16.8：昵称 + 身份标识（对齐 H5 audio-wrap.vue:172）
                // roomRoleType=1 → 房主 mic icon / roomRoleType=2 → 房管 icon
                HStack(spacing: 3) {
                    Text(seat.nickname ?? L10n.Party.defaultUser)
                        .font(Theme.Typography.partyRoomSmallSeatName)
                        .foregroundColor(Theme.Palette.partyRoomSeatNameText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    PartyRoleBadge(roomRoleType: seat.roomRoleType, size: 12)
                }
                HStack(spacing: 2) {
                    Image("partyGems")
                        .resizable().scaledToFit()
                        .frame(width: 10, height: 10)
                    // PK 期 SELECTING 强制归零（对齐 H5 audio-wrap.vue :93-97 seatScore）
                    Text(PartyNumberFormat.compact(PartyBattleSeatDisplay.giftValueCountInt(for: seat)))
                        .font(Theme.Typography.partyRoomGemsNumber)
                        .foregroundColor(Theme.Palette.partyRoomGemsText)
                }
            }
        } else if let idx = seat.seatIndex {
            Text("\(idx)")
                .font(Theme.Typography.partyRoomEmptyIndex)
                .foregroundColor(Theme.Palette.partyRoomEmptyIndex)
        }
    }
}
