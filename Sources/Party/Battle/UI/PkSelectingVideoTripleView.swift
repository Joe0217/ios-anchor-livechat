import SwiftUI

/// SELECTING 期视频位 replace（spec §6.2）
///
/// F-1a stub 版：三格布局占位（红/中立/蓝），参战麦位红蓝色边（依 store 内 uid 集合）
struct PkSelectingVideoTripleView: View {
    let bigSeats: [PartyRoomSeat]
    @ObservedObject var battleStore: PartyBattleStore

    private var redUids: Set<Int64> { Set(battleStore.redMembers.map { $0.uid }) }
    private var blueUids: Set<Int64> { Set(battleStore.blueMembers.map { $0.uid }) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { idx in
                slotCell(index: idx)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func slotCell(index: Int) -> some View {
        // stub：仅示意布局；正式 UI 走 CameraPreview / AgoraRemoteView + 阵营色边
        let team = teamForSlot(index)
        let borderColor: Color = team == 1 ? .red : team == 2 ? .blue : .gray
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(borderColor, lineWidth: 3)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.3)))
            .aspectRatio(1, contentMode: .fit)
    }

    private func teamForSlot(_ idx: Int) -> Int {
        guard idx < bigSeats.count,
              let userIdStr = bigSeats[idx].userId,
              let uid = Int64(userIdStr) else { return 3 }
        if redUids.contains(uid) { return 1 }
        if blueUids.contains(uid) { return 2 }
        return 3
    }
}
