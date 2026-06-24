import Foundation

/// 派对房送礼事件（2049 RECEIVE_PARTY_ROOM_GIFT_COMPRESSED 解压后 payload 占位）。
/// MVP 仅识别 + 公屏一行文案 + Store 推送；动画归 H 期 `GiftAnimationQueue` 消费。
///
/// payload schema 待 M3 抓真实帧确认（spec §1.5 #9），字段全部可选。
struct PartyGiftEvent: Equatable {
    let giftId: Int
    let giftName: String?
    let num: Int
    let senderUserId: String?
    let senderNickname: String?
    let receiverUserIds: [String]    // 安卓支持批量送礼到多麦位
    let timestamp: Int64             // 服务端下发时间戳，用于 1007/2049 去重（iOS 不识别 1007，留字段未来扩展）
}

/// 视频位邀请待响应（1040 INVITE_VIDEO_SEAT 解析后）。
/// MVP 仅消费"被邀请方响应"链路（接受 → onSeat + 服务端转发 1041；拒绝 → 1042）；
/// "房主主动发起邀请"接口 `inviteOnSeat` 推 F 期。
struct PartyVideoSeatInvite: Equatable {
    let inviteId: String
    let seatIndex: Int
    let fromUserId: String?
    let fromNickname: String?
    let roomId: String?      // 用于离开房间时 dismiss 残留邀请
    let timestamp: Int64
}

/// 视频位邀请响应反馈枚举（1041-1048 派生）。
/// MVP 仅 toast 通知用户，无业务影响。
enum PartyVideoSeatInviteResult: Equatable {
    case accepted      // 1041 被邀请者接受
    case rejected      // 1042 被邀请者拒绝
    case timeout       // 1043 邀请超时未响应
    case leave         // 1044 被邀请者已离开
    case occupied      // 1045 视频位已被占用
    case alreadyOn     // 1046 该用户已在任意麦位
    case broadcast     // 1047 邀请被接受公屏广播
    case joinFailed    // 1048 接受后上位失败
}

/// 送礼接口 `gift/sendGift` 返回（占位结构，字段实测后补）。
struct PartySendGiftResult: Codable, Equatable {
    let success: Bool?
    let giftId: Int?
    let num: Int?
    let totalValue: Int?
}
