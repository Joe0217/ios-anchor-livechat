import SwiftUI

/// PK 期麦位红蓝色边 ring overlay（对齐 H5 audio-wrap.vue :207-225 `pk-team-red/blue::after`）
///
/// 用法（挂在麦位 cell 外围，不侵入 cell 内部）：
/// ```
/// PartyRoomSmallSeatCell(seat: seat)
///     .partyBattleSeatRing(seat: seat)
/// ```
///
/// 视觉规则（对齐 H5）：
/// - 触发条件：`isSelecting || isRunning` 且 seat.userId 命中 redMembers/blueMembers
/// - Red team ring：粉红 `#FF26B1`（Color(red: 1.0, green: 0.15, blue: 0.7)）· 2px stroke · inset -2pt
/// - Blue team ring：深蓝 `#0C6EFE`（Color(red: 0.05, green: 0.43, blue: 1.0)）· 2px stroke · inset -2pt
/// - 非 PK 期 or seat 不在参战方 → 透明不显示
///
/// SwiftUI 实现：走 `.overlay { Circle().stroke(...) }` 挂麦位 view，
/// 依 `@ObservedObject battleStore` 自动跟随 store 更新重绘
struct PartyBattleSeatRingOverlay: ViewModifier {
    let seat: PartyRoomSeat
    @ObservedObject var battleStore: PartyBattleStore

    func body(content: Content) -> some View {
        content.overlay(ringOverlay, alignment: .center)
    }

    @ViewBuilder
    private var ringOverlay: some View {
        if let color = ringColor {
            Circle()
                .stroke(color, lineWidth: 2)
                .padding(-2)
                .allowsHitTesting(false)
        }
    }

    /// H5 audio-wrap.vue :81-85 · uid Number() 兜底比较
    private var ringColor: Color? {
        guard battleStore.isSelecting || battleStore.isRunning else { return nil }
        guard let uidStr = seat.userId, !uidStr.isEmpty,
              let uid = Int64(uidStr) else { return nil }
        if battleStore.redMembers.contains(where: { $0.uid == uid }) {
            return Color(red: 1.0, green: 0.15, blue: 0.7)   // #FF26B1
        }
        if battleStore.blueMembers.contains(where: { $0.uid == uid }) {
            return Color(red: 0.05, green: 0.43, blue: 1.0)  // #0C6EFE
        }
        return nil
    }
}

extension View {
    /// PK 期麦位红蓝色边 overlay
    ///
    /// - parameter seat: 麦位数据
    /// - parameter battleStore: PartyBattleStore（默认 .shared）
    func partyBattleSeatRing(
        seat: PartyRoomSeat,
        battleStore: PartyBattleStore = .shared
    ) -> some View {
        modifier(PartyBattleSeatRingOverlay(seat: seat, battleStore: battleStore))
    }
}
