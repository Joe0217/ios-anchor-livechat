import Foundation

/// 派对房房间信息（对齐安卓 `PartyRoomInfo`）。
///
/// 三 ID 解耦（spec §1.1）：
/// - `id`：业务 roomId（贯穿几乎所有房内接口）
/// - `agoraChannelId`：声网频道
/// - `yxRoomId`：云信 NIM 聊天室
///
/// `rtcToken` 字段是否由 `room/enter` 直接下发待 M4 实测确认（spec §1.5 #4）；
/// 缺失时降级调 `LiveService.getAgoraRtmToken` 兜底。
struct PartyRoomInfo: Codable, Equatable {
    let id: String?
    let agoraChannelId: String?
    let yxRoomId: String?
    let rtcToken: String?
    let roomName: String?
    let roomAvatar: String?
    let ownerUserId: String?
    let roomTempId: Int?
    let bgImgId: Int?
    let greetingMessage: String?
    let roomLanguage: String?
    let onlineCount: Int?
    let lockRoomFlag: Int?      // 0=未锁 1=锁
    let seatList: [PartyRoomSeat]?

    /// 由 ownerUserId 与当前登录 userId 衍生自己角色（MVP 仅 owner/audience 二态）。
    /// admin 角色推 F 期（需后端单独字段 isAdmin 或 adminList）。
    func selfRoleType(myUserId: String?) -> PartyRoomRoleType {
        guard let me = myUserId, !me.isEmpty,
              let owner = ownerUserId, !owner.isEmpty else {
            return .audience
        }
        return owner == me ? .owner : .audience
    }
}

/// 创建/列表/进房接口的通用包装：当后端把 `[PartyRoomInfo]` 包在 envelope.result.list 而非直接是数组时用。
/// MVP 默认直接当作数组解码；如需 list 字段嵌套，调用方按需自定义。
