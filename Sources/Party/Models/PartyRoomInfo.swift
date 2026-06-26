import Foundation

/// 派对房列表内嵌的在线用户预览（observer/麦上混合，list 接口最多前 N 条）。
struct PartyOnlineUser: Codable, Equatable {
    let userId: String?
    let avatar: String?
    let nickname: String?
}

/// 派对房房间信息（v3 真值版，按 dev `room/list` 返回 schema 重构于 2026-06-24）。
///
/// 三 ID 解耦（spec §1.1）：
/// - `id`：业务 roomId
/// - `agoraChannelId`：声网频道
/// - `yxRoomId`：云信 NIM 聊天室
///
/// 注意：
/// - **`roomTempId` 是 String**（dev 真实返回 `"1"`）；调用 seat 接口时直接转发字符串
/// - **`onlineCount` 衍生自 `onlineUserList.count`**，后端 list 接口不直接返"在线人数"，`heatValue` 是热度分非人数
/// - `seatList / rtcToken` 仅 `room/enter` 接口才返；list 接口缺失
/// - 全字段 Optional 容错，后端新增字段不会让现有解码崩
struct PartyRoomInfo: Codable, Equatable {
    let id: String?
    let ownerId: String?
    /// 自己在本房的角色（仅 `room/enter` 接口返；list 不返）：1=房主 2=房管 3=普通
    /// 来源：`EnterRoomResponse.roomRoleType`（安卓确认 §2.1）
    let roomRoleType: Int?
    /// 平台管理员标志（仅 `room/enter` 返）；与角色独立，权限最高
    let isPlatformAdmin: Bool?
    // 注：`roomAdminCount` 后端实际返 String（dev 实测 "0"，与安卓确认文档 Long 标注不符）；
    // MVP 不消费此字段，直接省略避免类型解码失败。F 期如需要房管管理 UI 再添加 String? 字段
    let roomName: String?
    let roomAvatar: String?
    let greetingMessage: String?
    let roomLanguage: String?
    let heatValue: Int?              // 房间热度分（非在线人数）
    let roomStatus: Int?             // 1=开放 / 2=关闭（具体语义实测确认）
    let lockFlag: Int?               // 0=未锁 1=有密码
    let yxRoomId: String?
    let agoraChannelId: String?
    let rtcToken: String?            // 仅 room/enter 返
    let onlineUserList: [PartyOnlineUser]?
    let score: String?
    let createTime: String?
    let needPassword: Bool?
    let snapshotId: String?
    let roomTempId: String?          // ⚠️ String 不是 Int（dev 返 "1"）
    let roomTempType: Int?
    let rangIndex: Int?
    let showChest: Bool?
    let gemsTotal: Int?
    let pkStatus: Int?
    let pkId: String?
    /// 麦位列表（dev 实测 `room/enter` 接口返字段名是 `roomSeatList`，与 spec 反推的 seatList 不符）；
    /// `room/list` 不返麦位列表。
    let roomSeatList: [PartyRoomSeat]?

    /// 衍生：观众在线人数（用 `onlineUserList.count`；list 接口无独立人数字段）
    var onlineCount: Int { onlineUserList?.count ?? 0 }

    /// 衍生：roomTempId Int 形式（后端 DTO 是 Long，但 HTTP 响应给字符串；调上下麦/respondInvite 时需 Int）。
    /// fallback 1（dev 主流模板 ID）；若 String 不可解析为 Int 同样退化到 1。
    var roomTempIdInt: Int { Int(roomTempId ?? "") ?? 1 }

    /// SwiftUI ForEach 用稳定 Identity（review 202606252033 P1-5）。
    /// `id` 是 String? 可能 nil；多个 nil 同 Identity 会让 ForEach diff 错乱。
    /// 多重 fallback：id → agoraChannelId → yxRoomId → ownerId → roomName → "unknown"；
    /// 加前缀防同串值在不同字段域互相串扰（例：id="x" vs ownerId="x" 视作不同 identity）。
    var stableListId: String {
        if let v = id, !v.isEmpty { return "id_\(v)" }
        if let v = agoraChannelId, !v.isEmpty { return "ch_\(v)" }
        if let v = yxRoomId, !v.isEmpty { return "yx_\(v)" }
        if let v = ownerId, !v.isEmpty { return "ow_\(v)" }
        if let v = roomName, !v.isEmpty { return "nm_\(v)" }
        return "unknown"
    }

    /// 衍生：自己角色（信服务端字段，不再用 `ownerId==myUserId` 推断 —— 安卓确认 §4.2 反例：
    /// 房管/平台管理员都不是房主但有管理权限，纯 ownerId 比较会漏判）。
    /// 顺序：
    /// 1) `isPlatformAdmin==true` → 视为最高权限（admin 等价）
    /// 2) `roomRoleType` 服务端字段（1/2/3 → owner/admin/audience）
    /// 3) fallback：`ownerId==myUserId` → owner（仅在 list 接口无 roomRoleType 字段时用）
    /// `myUserId` 参数保留为 fallback 路径用
    func selfRoleType(myUserId: String?) -> PartyRoomRoleType {
        if isPlatformAdmin == true { return .admin }
        if let raw = roomRoleType, let role = PartyRoomRoleType(rawValue: raw) {
            return role
        }
        // fallback（仅 list 接口无 roomRoleType 时用）
        guard let me = myUserId, !me.isEmpty,
              let owner = ownerId, !owner.isEmpty else {
            return .audience
        }
        return owner == me ? .owner : .audience
    }
}
