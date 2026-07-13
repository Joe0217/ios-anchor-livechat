import SwiftUI

/// Party 房间小麦位 cell（设计稿下方 5×2 排列的 10 个语聊位）。
///
/// 视觉：
/// - 空位：粉紫圆环 + 中心椅子/麦克风图标 + 底部数字
/// - 占用：圆形头像（带徽章装饰）+ 昵称 + Gems 数字
struct PartyRoomSmallSeatCell: View {
    let seat: PartyRoomSeat

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
                .frame(width: Theme.Metric.partyRoomSmallSeatAvatar,
                       height: Theme.Metric.partyRoomSmallSeatAvatar)
                .clipShape(Circle())

            if seat.occupied {
                badgeCorner
            }

            if seat.occupied, isMicMuted {
                micMutedCorner
            }
        }
        .frame(width: Theme.Metric.partyRoomSmallSeatAvatar + 12,
               height: Theme.Metric.partyRoomSmallSeatAvatar + 12)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if seat.occupied, let urlStr = seat.avatar {
            CachedAsyncImage(url: URL(string: urlStr),
                             contentMode: .fill,
                             cdn: (.avatarSmall, .fill)) {
                Circle().fill(Theme.Palette.partyRoomSeatFill)
            }
        } else {
            // 空位保持透明，仅外层 partySeatRing 圆环可见（让房间底图透出）
            // 移除 chair.lounge.fill（iOS 17+ 符号在 iOS 16 静默为空，且视觉误读为「占位灰头像」）
            Color.clear
        }
    }

    /// 右上角小徽章装饰（占用状态显示 - 复用 Component 8 泡泡）
    private var badgeCorner: some View {
        VStack {
            HStack {
                Spacer()
                Image("partyBadgeBubble")
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .frame(width: Theme.Metric.partyRoomSmallSeatAvatar + 12,
               height: Theme.Metric.partyRoomSmallSeatAvatar + 12)
    }

    /// 左下角静音角标
    private var micMutedCorner: some View {
        VStack {
            Spacer()
            HStack {
                Image("partyIconMicMuted")
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                Spacer()
            }
        }
        .frame(width: Theme.Metric.partyRoomSmallSeatAvatar + 12,
               height: Theme.Metric.partyRoomSmallSeatAvatar + 12)
    }

    private var isMicMuted: Bool {
        (seat.microphoneEnabled ?? 0) != 1 || (seat.seatMicrophoneEnabled ?? 0) != 1
    }

    // MARK: - Footer

    @ViewBuilder
    private var occupiedFooter: some View {
        if seat.occupied {
            VStack(spacing: 2) {
                Text(seat.nickname ?? L10n.Party.defaultUser)
                    .font(Theme.Typography.partyRoomSmallSeatName)
                    .foregroundColor(Theme.Palette.partyRoomSeatNameText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 2) {
                    Image("partyGems")
                        .resizable().scaledToFit()
                        .frame(width: 10, height: 10)
                    Text(PartyNumberFormat.compact(seat.giftValueCount ?? 0))
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
