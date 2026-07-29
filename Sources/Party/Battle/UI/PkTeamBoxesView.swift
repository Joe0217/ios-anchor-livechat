import SwiftUI

/// PK 团队盒（对齐 H5 pk-team-boxes.vue 314 行）
///
/// 视觉结构：
/// - 红队盒（左）：5 麦位 3+2 grid（seatIndex 4-8）· 深色队色底 + 红边
/// - 中央 VS icon
/// - 蓝队盒（右）：5 麦位 3+2 grid（seatIndex 9-13）· 深色队色底 + 蓝边
/// - 空槽：带加号的队色圆点占位（tap 可上麦）
///
/// **数据来源**（对齐 H5）：`PartyBattleSeatLayout.buildTeamSlots(team:seatList:)` 派生 5 个 slot
/// - 从 `partyStore.seatList` 按 seatIndex 4-8 / 9-13 取实时 seat
/// - 未占用位 → placeholder slot（保留 seatIndex 供 tap）
///
/// **挂载条件**：仅 `battleStore.isSelecting || battleStore.isRunning` 时挂载（由父级决定）
///
/// **点击**：所有 slot（占用/空）都 emit `onSeatTap(seatIndex)`，由父级走 joinOrOutMic
struct PkTeamBoxesView: View {
    let redSlots: [PartyRoomSeat]
    let blueSlots: [PartyRoomSeat]
    let onSeatTap: (Int) -> Void

    private let redColor = Color(red: 1.0, green: 0.15, blue: 0.7)   // #FF26B1
    private let blueColor = Color(red: 0.05, green: 0.43, blue: 1.0)  // #0C6EFE

    private enum TeamSide {
        case red
        case blue
    }

    var body: some View {
        HStack(spacing: 0) {
            teamBox(slots: redSlots, color: redColor, side: .red)
                .frame(maxWidth: .infinity)
            vsIcon
                .frame(width: 42)
                .zIndex(1)
            teamBox(slots: blueSlots, color: blueColor, side: .blue)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Team box

    @ViewBuilder
    private func teamBox(slots: [PartyRoomSeat], color: Color, side: TeamSide) -> some View {
        // 3+2 布局：上行 3 位（slots[0..2]），下行 2 位（slots[3..4]）
        VStack(spacing: 4) {
            row(Array(slots.prefix(3)), color: color, side: side)
            row(Array(slots.suffix(from: min(3, slots.count))), color: color, side: side)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(teamBoxBackground(color: color))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(color.opacity(0.72), lineWidth: 1)
                }
        )
    }

    @ViewBuilder
    private func row(_ slots: [PartyRoomSeat], color: Color, side: TeamSide) -> some View {
        HStack(spacing: 0) {
            ForEach(slots.indices, id: \.self) { i in
                seatCell(slots[i], color: color, side: side)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func seatCell(_ seat: PartyRoomSeat, color: Color, side: TeamSide) -> some View {
        VStack(spacing: 2) {
            avatarView(seat: seat, color: color, side: side)
            nameText(seat: seat)
            gemsText(seat: seat)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if let idx = seat.seatIndex { onSeatTap(idx) }
        }
    }

    @ViewBuilder
    private func avatarView(seat: PartyRoomSeat, color: Color, side: TeamSide) -> some View {
        ZStack {
            if seat.userId?.isEmpty == false {
                // 占用：CachedAsyncImage 头像（对齐 H5 v-image cdn-measure="m"）+ 队伍色边圈
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 38, height: 38)
                    .overlay(
                        CachedAsyncImage(
                            url: URL(string: seat.avatar ?? ""),
                            contentMode: .fill,
                            persistent: false,
                            cdn: (.avatarSmall, .fill)
                        ) {
                            Image(systemName: "person.fill").foregroundColor(.white.opacity(0.5))
                        }
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                    )
                    .overlay(Circle().stroke(color, lineWidth: 2))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: (seat.microphoneEnabled ?? 0) == 1 ? "mic.fill" : "mic.slash.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Color.black.opacity(0.62), in: Circle())
                            .offset(x: 2, y: 2)
                    }
            } else {
                // 切图提供的沙发 + 加号组合，和设计稿中的 PK 空位保持同一层次。
                ZStack {
                    Image(side == .red ? "partyPkRedSofa" : "partyPkBlueSofa")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 38, height: 38)
                    Image(side == .red ? "partyPkRedSeatAdd" : "partyPkBlueSeatAdd")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
            }
        }
    }

    @ViewBuilder
    private func nameText(seat: PartyRoomSeat) -> some View {
        if let name = seat.nickname, !name.isEmpty {
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        } else {
            Text(L10n.Party.Battle.none)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private func gemsText(seat: PartyRoomSeat) -> some View {
        if seat.userId?.isEmpty == false {
            HStack(spacing: 1) {
                Image("partyPkGem")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 8, height: 8)
                Text(PartyNumberFormat.compact(PartyBattleSeatDisplay.giftValueCountInt(for: seat)))
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(red: 1.0, green: 0.90, blue: 0.0))
                    .lineLimit(1)
            }
        } else {
            Color.clear.frame(height: 10)
        }
    }

    // MARK: - VS icon

    @ViewBuilder
    private var vsIcon: some View {
        Image("partyPkCenterLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 50, height: 50)
            .shadow(color: .yellow.opacity(0.6), radius: 8)
    }

    private func teamBoxBackground(color: Color) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.34), Color.black.opacity(0.56), Color.black.opacity(0.34)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

}
