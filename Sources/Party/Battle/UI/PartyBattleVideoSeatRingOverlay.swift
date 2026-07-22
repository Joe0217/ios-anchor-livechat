import SwiftUI

/// PK 期**视频位**（大麦位）红蓝色边 overlay（对齐 H5 main-wrap.vue :63-74 `pkVideoSlotTeamClass`）
///
/// **与 [PartyBattleSeatRingOverlay](PartyBattleSeatRingOverlay.swift) 的区别**：
/// - 音频位（小麦位）：按 `seat.userId` 命中 `battleStore.redMembers/blueMembers` 判定色边
/// - 视频位（大麦位）：**按位置 index 判定** —— 首位（index=0）红 / 末位（index=total-1）蓝 / 中间无色
///
/// H5 逻辑（main-wrap.vue :63-74）：
/// ```js
/// function pkVideoSlotTeamClass(index) {
///   if (!isSelecting && !isRunning) return ''
///   if (total <= 0) return ''
///   if (index === 0) return 'pk-team-red'
///   if (total >= 2 && index === total - 1) return 'pk-team-blue'
///   return ''
/// }
/// ```
///
/// 用法（在 bigSeats ForEach 里加 index 判定）：
/// ```swift
/// ForEach(Array(bigSeats.enumerated()), id: \.element.stableId) { idx, seat in
///     PartyRoomBigSeatCell(...)
///         .partyBattleVideoSeatRing(index: idx, total: bigSeats.count)
///         .onTapGesture { handleSeatTap(seat) }
/// }
/// ```
struct PartyBattleVideoSeatRingOverlay: ViewModifier {
    let index: Int
    let total: Int
    @ObservedObject var battleStore: PartyBattleStore

    func body(content: Content) -> some View {
        content.overlay(ringOverlay, alignment: .center)
    }

    @ViewBuilder
    private var ringOverlay: some View {
        if let color = ringColor {
            RoundedRectangle(cornerRadius: 12)
                .stroke(color, lineWidth: 3)
                .padding(-1)
                .allowsHitTesting(false)
        }
    }

    /// H5 main-wrap.vue :63-74 · 首位红 / 末位蓝 / 中间无
    private var ringColor: Color? {
        guard battleStore.isSelecting || battleStore.isRunning else { return nil }
        guard total > 0 else { return nil }
        if index == 0 {
            return Color(red: 1.0, green: 0.15, blue: 0.7)   // #FF26B1
        }
        if total >= 2 && index == total - 1 {
            return Color(red: 0.05, green: 0.43, blue: 1.0)  // #0C6EFE
        }
        return nil
    }
}

extension View {
    /// PK 期视频位（大麦位）红蓝色边 overlay · 按位置 index 判定（首位红/末位蓝）
    ///
    /// - parameter index: 当前视频位在 bigSeats 数组的索引
    /// - parameter total: 视频位总数（bigSeats.count）
    /// - parameter battleStore: PartyBattleStore（默认 .shared）
    func partyBattleVideoSeatRing(
        index: Int,
        total: Int,
        battleStore: PartyBattleStore = .shared
    ) -> some View {
        modifier(PartyBattleVideoSeatRingOverlay(index: index, total: total, battleStore: battleStore))
    }
}
