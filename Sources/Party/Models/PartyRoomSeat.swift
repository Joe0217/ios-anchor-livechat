import Foundation

/// 麦位 anchorTaskRewardExt 嵌套字段（主播任务奖励配置）。MVP 不消费，仅保留解码兼容。
struct PartyAnchorTaskRewardExt: Codable, Equatable {
    let vfxUrl: String?
    let icon: String?
    let itemId: String?
    let bgImgId: String?
}

/// 派对房麦位（v3 真值版，按 dev `seat/list` 返回 schema 重构于 2026-06-24）。
///
/// 字段语义对照 dev 实测：
/// - `seatType`：1=视频位 / 2=语聊位
/// - `isOccupied`：**Int 0/1**（后端用 0/1 不是 Bool）
/// - `microphoneEnabled / cameraEnabled`：**用户自身**麦克风/摄像头开关
/// - `seatMicrophoneEnabled / seatCameraEnabled`：**管理员**禁麦/禁摄像头态（独立于自身开关）
/// - `roomRoleType`：坐麦人角色（1=房主 2=房管 3=观众）
/// - `yxAccid`：云信 accid，**送礼用**（gift/sendGift 入参 yxAccidList 用这个字段，非 userId）
/// - `anchorTaskRewardExt`：主播任务奖励（vfxUrl/icon/itemId/bgImgId 含特效配置），MVP 不消费
///
/// 全字段 Optional 容错。
struct PartyRoomSeat: Codable, Equatable, Identifiable {
    let id: String?                       // 麦位记录主键（数据库 ID，非业务）
    let roomId: String?                   // 冗余房间 ID
    let seatIndex: Int?
    let userId: String?
    let avatar: String?
    let nickname: String?
    let seatType: Int?                    // 1=video 2=voice
    let isOccupied: Int?                  // 0=空 1=有人（后端用 Int 不是 Bool）
    let cameraEnabled: Int?               // 用户自身摄像头
    let microphoneEnabled: Int?           // 用户自身麦克风
    let roomRoleType: Int?                // 1=owner 2=admin 3=audience
    let giftValueCount: Int?
    let headFrame: String?
    let yxAccid: String?                  // 云信 accid（送礼用）
    let userType: Int?
    let seatCameraEnabled: Int?           // 管理员禁摄像头态
    let seatMicrophoneEnabled: Int?       // 管理员禁麦态
    let lockFlag: Int?
    let roomTempId: String?               // 模板 ID 冗余
    let isHostSeat: Int?
    let isPlatformAdmin: Int?
    let showBubble: Bool?
    let anchorTaskRewardExt: PartyAnchorTaskRewardExt?

    /// 是否被有效占用（双判：占位字段 + userId 任一）
    var occupied: Bool {
        if (isOccupied ?? 0) == 1 { return true }
        return !(userId?.isEmpty ?? true)
    }

    /// 强类型 seatType（未知值 nil 不参与对账分支）
    var typed: PartyRoomSeatType? {
        guard let s = seatType else { return nil }
        return PartyRoomSeatType(rawValue: s)
    }

    /// 强类型角色
    var typedRole: PartyRoomRoleType? {
        guard let r = roomRoleType else { return nil }
        return PartyRoomRoleType(rawValue: r)
    }

    /// SwiftUI ForEach 用稳定 Identity（review 202606252033 P1-5）。
    /// `id` 是数据库主键 String? 可能 nil；多个 nil 会让 ForEach Identity 坍缩 → PartyRemoteVideoView 误调 dismantle → 远端视频黑屏。
    /// 改用业务键 seatIndex（麦位 1-13 唯一），nil 退化到 -1（极端情况，不影响生产）。
    var stableId: Int { seatIndex ?? -1 }
}
