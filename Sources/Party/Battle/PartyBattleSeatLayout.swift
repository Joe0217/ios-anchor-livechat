import Foundation

/// PartyBattle 麦位阵营↔麦位索引映射（spec §6.3）
///
/// SELECTING/RUNNING 期视频位 replace 逻辑用：
/// - 红队 slot 0-4 → seatIndex 4-8
/// - 蓝队 slot 0-4 → seatIndex 9-13
/// - 中立位 seatIndex 0-3（房主 MC 位 + 观众排队区）
enum PartyBattleSeatLayout {
    /// 红队 slot idx (0..4) → 全房 seatIndex
    static func redSlotSeatIndex(_ slotIdx: Int) -> Int { 4 + slotIdx }

    /// 蓝队 slot idx (0..4) → 全房 seatIndex
    static func blueSlotSeatIndex(_ slotIdx: Int) -> Int { 9 + slotIdx }

    /// seatIndex → 阵营（1=红 2=蓝 3=中立/未知）
    static func teamOfSeatIndex(_ seatIndex: Int) -> Int {
        switch seatIndex {
        case 4...8: return 1
        case 9...13: return 2
        default: return 3
        }
    }

    /// 对齐 H5 main-wrap.vue :88-112 `buildTeamSlots`
    ///
    /// 从 partyStore.seatList 按 baseSeat + i 派生 5 个 slot（红队 4-8 / 蓝队 9-13）：
    /// - 麦位空/未占用 → placeholder slot（保留 seatIndex，点击可走 joinOrOutMic 申请）
    /// - 麦位占用 → 直接返回 seat（可选 attach member 数据到派生结构）
    ///
    /// H5 强调"槽位从 roomSeatList 取实时 seat"—— 保证 PK 前后人员相对麦位不变（不被后端报名顺序重排）
    static func buildTeamSlots(
        team: Team,
        seatList: [PartyRoomSeat]
    ) -> [PartyRoomSeat] {
        let baseSeat = team == .red ? 4 : 9
        return (0..<5).map { i in
            let seatIndex = baseSeat + i
            if let seat = seatList.first(where: { $0.seatIndex == seatIndex }) {
                return seat
            }
            // Placeholder slot（无 userId，UI 层判断为空位显示 pk placeholder）
            return placeholderSeat(seatIndex: seatIndex)
        }
    }

    enum Team {
        case red, blue
        var forcedTeamString: String { self == .red ? "red" : "blue" }
    }

    /// 空占位 seat —— PartyRoomSeat 字段全 let 需通过 Codable round-trip 构造 minimal 实例
    private static func placeholderSeat(seatIndex: Int) -> PartyRoomSeat {
        let dict: [String: Any] = [
            "seatIndex": seatIndex,
            "isOccupied": 0,
            "lockFlag": 0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let seat = try? JSONDecoder().decode(PartyRoomSeat.self, from: data)
        else {
            // 极端 fallback（不应发生）
            let empty: [String: Any] = ["seatIndex": seatIndex]
            let d = try! JSONSerialization.data(withJSONObject: empty)
            return try! JSONDecoder().decode(PartyRoomSeat.self, from: d)
        }
        return seat
    }
}
