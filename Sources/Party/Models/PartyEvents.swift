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
    /// v3+（2026-07-16）：发送人头像 URL，对齐 H5 party.js:1100 `data.sendUser.avatar`。
    /// nil = 后端 payload 缺失（旧版兼容 / 单测省略）
    let senderAvatar: String?
    let receiverUserIds: [String]    // 安卓支持批量送礼到多麦位
    let timestamp: Int64             // 服务端下发时间戳，用于 1007/2049 去重（iOS 不识别 1007，留字段未来扩展）

    init(giftId: Int,
         giftName: String?,
         num: Int,
         senderUserId: String?,
         senderNickname: String?,
         senderAvatar: String? = nil,
         receiverUserIds: [String],
         timestamp: Int64) {
        self.giftId = giftId
        self.giftName = giftName
        self.num = num
        self.senderUserId = senderUserId
        self.senderNickname = senderNickname
        self.senderAvatar = senderAvatar
        self.receiverUserIds = receiverUserIds
        self.timestamp = timestamp
    }
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

/// 送礼接口 `gift/sendGift` 返回。
///
/// **H-5 扩展 userDiamond（送礼后新余额）**：H5 用户端字段名是 `userDiamond`（stores/modules/gift.js:1620）；
/// 主播端后端字段名未真机验证 → 走 CodingKeys 多别名 fallback（对齐 `agent-recon-field-names-unverified` rule）。
struct PartySendGiftResult: Equatable, Decodable {
    let success: Bool?
    let giftId: Int?
    let num: Int?
    let totalValue: Int?
    /// 送礼后新余额（对齐 H5 res.userDiamond）；后端字段名多候选兜底
    let userDiamond: Int64?

    private enum CodingKeys: String, CodingKey {
        case success, giftId, num, totalValue
        // 多别名 fallback：H5 用 userDiamond；安卓 归档未点名 → 保守兜底 4 候选
        case userDiamond, userDiamonds, newDiamond, remainDiamond
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try? c.decode(Bool.self, forKey: .success)
        giftId = try? c.decode(Int.self, forKey: .giftId)
        num = try? c.decode(Int.self, forKey: .num)
        totalValue = try? c.decode(Int.self, forKey: .totalValue)
        userDiamond = (try? c.decode(Int64.self, forKey: .userDiamond))
                   ?? (try? c.decode(Int64.self, forKey: .userDiamonds))
                   ?? (try? c.decode(Int64.self, forKey: .newDiamond))
                   ?? (try? c.decode(Int64.self, forKey: .remainDiamond))
    }

    init(success: Bool?, giftId: Int?, num: Int?, totalValue: Int?, userDiamond: Int64?) {
        self.success = success
        self.giftId = giftId
        self.num = num
        self.totalValue = totalValue
        self.userDiamond = userDiamond
    }
}

// MARK: - 纯解析（脱 NIMSDK 单测覆盖）

extension PartyGiftEvent {
    /// 从 2049 解压后的 payload 构造 PartyGiftEvent（pure / 无 SDK 依赖 / C 档单测用）。
    /// 安卓确认 §3.3 schema：`giftId` / `giftNum`（非 num）/ `sendUser`（嵌套）/ `receiveUserList`（数组）/ 无 timestamp。
    /// 字段缺失策略（与原内联 didReceiveGift 等价，零业务行为变更）：
    /// - `giftId` 缺/类型错 → 默认 0
    /// - `giftNum` 缺 → 默认 1
    /// - `sendUser` 缺 → senderUserId/senderNickname nil
    /// - `receiveUserList` 缺/项缺 userId → 静默丢弃（compactMap）
    /// `timestampMs` 由调用方注入（NIM 路径用 `raw.timestamp * 1000`，单测可注入固定值）。
    static func from(payload: [String: Any], timestampMs: Int64) -> PartyGiftEvent {
        let sendUserObj = payload["sendUser"] as? [String: Any]
        let receiveList = payload["receiveUserList"] as? [[String: Any]] ?? []
        let receiverIds = receiveList.compactMap { PartyValueNormalizer.stringify($0["userId"]) }
        // v3+：avatar 字段名 fallback（对齐 H5 `data.sendUser.avatar`；兼容后端 `icon` 别名）
        let senderAvatar = (sendUserObj?["avatar"] as? String)
                        ?? (sendUserObj?["icon"] as? String)
                        ?? (sendUserObj?["userAvatar"] as? String)
        return PartyGiftEvent(
            giftId: PartyValueNormalizer.intify(payload["giftId"]) ?? 0,
            giftName: nil,
            num: PartyValueNormalizer.intify(payload["giftNum"]) ?? 1,
            senderUserId: sendUserObj.flatMap { PartyValueNormalizer.stringify($0["userId"]) },
            senderNickname: sendUserObj?["nickname"] as? String,
            senderAvatar: senderAvatar,
            receiverUserIds: receiverIds,
            timestamp: timestampMs
        )
    }
}

extension PartyVideoSeatInvite {
    /// 从 1040 payload 构造 PartyVideoSeatInvite（pure / 无 SDK 依赖 / C 档单测用）。
    /// 安卓确认 §3.8 schema：
    /// `inviteId` (String) / `seatIndex` (Number) / `ownerUserId` / `ownerNick` / `roomId` (Number) /
    /// `yxRoomId` / `ttl` (秒) / `roomTempId` (Number)。
    /// 守卫：`!inviteId.isEmpty && seatIndex > 0` 否则返回 nil（不入弹窗队列）。
    /// `fallbackRoomId` 用于 payload roomId 缺时退化为当前 chat.roomId。
    static func from(payload: [String: Any],
                     fallbackRoomId: String,
                     timestampMs: Int64) -> PartyVideoSeatInvite? {
        let inviteId = PartyValueNormalizer.stringify(payload["inviteId"]) ?? ""
        guard let seatIndex = PartyValueNormalizer.intify(payload["seatIndex"]),
              seatIndex > 0,
              !inviteId.isEmpty else {
            return nil
        }
        return PartyVideoSeatInvite(
            inviteId: inviteId,
            seatIndex: seatIndex,
            fromUserId: PartyValueNormalizer.stringify(payload["ownerUserId"]),
            fromNickname: payload["ownerNick"] as? String,
            roomId: PartyValueNormalizer.stringify(payload["roomId"]) ?? fallbackRoomId,
            timestamp: timestampMs
        )
    }
}
