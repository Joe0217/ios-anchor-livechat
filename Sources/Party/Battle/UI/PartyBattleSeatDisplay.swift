import Foundation

/// 麦位 PK 期显示辅助（对齐 H5 audio-wrap.vue :93-97 seatScore 语义）
///
/// H5 逻辑（partyBattle store 隐式感知）：
/// ```
/// const seatScore = computed(() => {
///   if (battleStore.isSelecting) return 0   // SELECTING 期强制 0，不显示历史累计
///   return props.roomSeatItem?.giftValueCount || 0
/// })
/// ```
///
/// iOS 侧：麦位 cell 内部原本直接读 `seat.giftValueCountInt`，需过一层 `PartyBattleSeatDisplay`
/// 让 SELECTING 期归零。RUNNING/非 PK 期沿用本地 giftValueCount（H5 明说 **不用后端 personalGems/personalScore**，
/// 因为它是"该用户【本场 PK 的累计贡献】离麦重新上麦不会重置"）。
enum PartyBattleSeatDisplay {

    /// PK-aware 麦位钻石数（Int，用于 PartyNumberFormat.compact 展示）
    @MainActor
    static func giftValueCountInt(for seat: PartyRoomSeat) -> Int {
        if PartyBattleStore.shared.isSelecting {
            return 0  // H5 audio-wrap.vue :94-95 · SELECTING 期强制 0
        }
        return seat.giftValueCountInt
    }
}
