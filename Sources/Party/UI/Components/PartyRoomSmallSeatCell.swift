import SwiftUI

/// Party 房间小麦位 cell（设计稿下方 5×2 排列的 10 个语聊位）。
///
/// 视觉：
/// - 空位：粉紫圆环 + 中心椅子/麦克风图标 + 底部数字
/// - 占用：圆形头像（带徽章装饰）+ 昵称 + Gems 数字
/// - v15：说话中 → 头像外圈 pulse ring（对齐 H5 PlayVolume 序列帧的 SwiftUI 等效）
struct PartyRoomSmallSeatCell: View {
    let seat: PartyRoomSeat
    /// v15：是否正在说话（PartyStore.isSpeaking 派生）；空位时恒 false
    var isSpeaking: Bool = false

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
            // Fallback：Component 7 asset 未导入时空位也用 partySeatRing 兜底
            Image(seat.occupied ? "partySeatRing" : (UIImage(named: "partySeatEmpty") != nil ? "partySeatEmpty" : "partySeatRing"))
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.partyRoomSmallSeatAvatar + 8,
                       height: Theme.Metric.partyRoomSmallSeatAvatar + 8)
                .accessibilityHidden(true)

            avatarContent

            // v16：占用态头像装饰框（对齐 H5 `seat-roster-item.vue` head-frame 组件）
            // 空位不叠（视觉焦点让给 partySeatEmpty 空位切图）
            if seat.occupied, let raw = seat.headFrame, !raw.isEmpty {
                HeadFrameView(urlString: raw,
                              size: Theme.Metric.partyRoomSmallSeatAvatar + 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // v15：说话中 pulse ring（与头像同心，尺寸略大于 partySeatRing 装饰环）
            PartySmallSeatSpeakingRing(
                isSpeaking: isSpeaking && seat.occupied,
                diameter: Theme.Metric.partyRoomSmallSeatAvatar + 10
            )

            // v15：锁麦位视觉标识（对齐 H5 空位 lockFlag=1 显示 lock icon 阻止上麦）
            // 只在空位显示，占用位不显示（占用时 lockFlag 无实际业务约束）
            if !seat.occupied, (seat.lockFlag ?? 0) == 1 {
                Image(systemName: "lock.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .accessibilityHidden(true)
            }

            // v13：badgeCorner (partyBadgeBubble 右上角泡泡) 去掉（用户 2026-07-13 requirement）
            // v10：mic 图标移到 footer 名字后面（去掉 bottom-left corner overlay）
        }
        .frame(width: Theme.Metric.partyRoomSmallSeatAvatar + 12,
               height: Theme.Metric.partyRoomSmallSeatAvatar + 12)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if seat.occupied {
            // v10：占用态头像走公共组件 AvatarView（对齐 prefer-shared-component-over-adhoc rule）
            // AvatarView 自带默认兜底图 + CDN + 缓存，不再手写 CachedAsyncImage
            AvatarView(urlString: seat.avatar,
                       size: Theme.Metric.partyRoomSmallSeatAvatar,
                       kind: .user)
        } else {
            // 空位保持透明，仅外层 partySeatRing 圆环可见（让房间底图透出）
            Color.clear
                .frame(width: Theme.Metric.partyRoomSmallSeatAvatar,
                       height: Theme.Metric.partyRoomSmallSeatAvatar)
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
                    Text(PartyNumberFormat.compact(seat.giftValueCountInt))
                        .font(Theme.Typography.partyRoomGemsNumber)
                        .foregroundColor(Theme.Palette.partyRoomGemsText)
                }
            }
        } else if let idx = seat.seatIndex {
            // v15：锁麦位不显示数字（视觉焦点让给 lock 图标）
            if (seat.lockFlag ?? 0) != 1 {
                Text("\(idx)")
                    .font(Theme.Typography.partyRoomEmptyIndex)
                    .foregroundColor(Theme.Palette.partyRoomEmptyIndex)
            }
        }
    }
}
