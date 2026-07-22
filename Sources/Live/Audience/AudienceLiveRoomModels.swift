import Foundation

/// 首页客态直播间导航载荷。通过 `NavigationStack(path:)` 入栈，使主 TabBar 能统一感知子页状态。
enum AudienceLiveRoomRoute: Hashable {
    case room(LiveStreamAnchor)
}

/// 客态进房后的完整房间快照。H5 先用广场卡片预加载视频，再以
/// `getRoomAndJoinRoom` 的返回值覆盖；iOS 同样只信后一次返回的频道和聊天室标识。
struct AudienceLiveRoomInfo: Equatable {
    enum Availability: Equatable {
        case live
        case calling
        case ended
    }

    let availability: Availability
    let liveRecordId: Int
    let anchorUserId: Int
    let anchorNickname: String
    let anchorAvatarURL: String?
    let anchorYxAccid: String?
    /// 当前直播房主播国家。国家档付费跑马灯须按房主国家过滤，而非按登录用户国家过滤。
    let anchorCountryCode: String?
    let agoraChannelId: String
    let yxRoomId: Int
    let rtcToken: String
    let hotScore: Int
    /// H5 `getRoomAndJoinRoom` 可能直接携带 7(PK中)/8(惩罚)；进房后仍以 getPkInfo 补全双方信息。
    let initialPKStatus: Int?

    var anchorUserIdString: String { String(anchorUserId) }

    init?(anchor: LiveStreamAnchor,
          response: [String: Any],
          rtcToken: String?) {
        // H5 同时兼容顶层和 `agoraLiveSimpleVO`：后端两种形态在不同接口版本中并存。
        var fields = response
        if let simple = response["agoraLiveSimpleVO"] as? [String: Any] {
            for (key, value) in simple where fields[key] == nil {
                fields[key] = value
            }
        }

        let liveRoomState = Self.int(fields["liveRoomState"])
        let userStatus = Self.int(fields["userStatus"])
        let availability: Availability
        if liveRoomState == 1 {
            availability = .ended
        } else if userStatus == 10_000 {
            availability = .calling
        } else {
            availability = .live
        }

        let anchorId = Self.int(fields["userId"]) ?? Int(anchor.userId)
        guard let anchorId else { return nil }

        let liveRecordId = Self.int(fields["id"] ?? fields["agoraLiveRoomId"]) ?? 0
        let nickname = Self.string(fields["nickname"] ?? fields["nickName"]) ?? anchor.nickname
        let avatar = Self.string(fields["icon"] ?? fields["avatar"]) ?? anchor.icon
        let yxRoomId = Self.int(fields["yxRoomId"])
        let channelId = Self.string(fields["agoraChannelId"])
        let token = rtcToken ?? Self.string(fields["rtcToken"])

        // 已关播/通话中不需要 media 参数；直播态必须完整，否则不能进入一个不可恢复的黑屏房。
        if availability == .live,
           (liveRecordId <= 0 || yxRoomId == nil || channelId?.isEmpty != false || token?.isEmpty != false) {
            return nil
        }

        self.availability = availability
        self.liveRecordId = liveRecordId
        self.anchorUserId = anchorId
        self.anchorNickname = nickname.isEmpty ? anchor.nickname : nickname
        self.anchorAvatarURL = avatar
        self.anchorYxAccid = Self.string(fields["yxAccid"])
        self.anchorCountryCode = Self.string(fields["countryId"] ?? fields["countryCode"] ?? fields["country"])
        self.agoraChannelId = channelId ?? ""
        self.yxRoomId = yxRoomId ?? 0
        self.rtcToken = token ?? ""
        self.hotScore = Self.int(fields["hotScore"]) ?? 0
        self.initialPKStatus = Self.int(fields["pkStatus"])
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = int(value) { return String(value) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            return type == "c" || type == "B" ? nil : value.intValue
        }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

enum AudienceLiveRoomState: Equatable {
    case idle
    case joining
    case live(AudienceLiveRoomInfo)
    case calling(AudienceLiveRoomInfo)
    case ended
    case failed(String)
}
