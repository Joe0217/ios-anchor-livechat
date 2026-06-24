import Foundation

/// 派对房麦位（对齐安卓 `PartyRoomSeat`，spec §1.1 麦位数据结构）。
///
/// 字段语义：
/// - `seatType`：1=视频位 / 2=语聊位
/// - `microphoneEnabled`：**用户自身**麦克风开关
/// - `seatMicrophoneEnabled`：**管理员**禁麦态（独立于自身开关）
/// - `cameraEnabled`：仅视频位有效
/// - `lockFlag`：管理员锁麦（占位用户不显示）
/// - `isHostSeat`：接待位标志（MVP 不消费，留 F）
///
/// 全字段可选：后端返回缺字段时不崩溃；上层用 `?? 默认值` 兜底。
struct PartyRoomSeat: Codable, Equatable, Identifiable {
    let seatIndex: Int?
    let seatType: Int?               // 1=video 2=voice，用 Int 而非 enum 避免后端新增值崩溃
    let userId: String?
    let isOccupied: Bool?
    let cameraEnabled: Int?          // 0/1
    let microphoneEnabled: Int?      // 0/1
    let seatMicrophoneEnabled: Int?  // 0/1（管理员禁麦态）
    let lockFlag: Int?
    let isHostSeat: Int?
    let nickname: String?
    let avatar: String?
    let level: Int?
    let giftValueCount: Int?

    /// SwiftUI ForEach 用，seatIndex 在房间内唯一；nil 时退化为 UUID 占位
    var id: String { seatIndex.map(String.init) ?? UUID().uuidString }

    /// 是否被有效占用（占位字段 + userId 双判，规避后端字段缺一致性问题）
    var occupied: Bool {
        if isOccupied == true { return true }
        return !(userId?.isEmpty ?? true)
    }

    /// 强类型 seatType（未知值映射 nil 不参与对账分支）
    var typed: PartyRoomSeatType? {
        guard let s = seatType else { return nil }
        return PartyRoomSeatType(rawValue: s)
    }
}
