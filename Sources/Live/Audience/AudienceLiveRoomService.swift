import Foundation

protocol AudienceLiveRoomServiceProtocol {
    func join(anchor: LiveStreamAnchor) async throws -> AudienceLiveRoomInfo
}

/// 客态进房服务，对齐 H5 `joinLiveRoom`：
/// 1. `getRoomAndJoinRoom` 校验直播状态并补齐房间参数；
/// 2. 仅直播中的房间再拉当前账号的 Agora token；
/// 3. 不沿用广场列表的频道字段，避免列表缓存导致串房。
struct AudienceLiveRoomService: AudienceLiveRoomServiceProtocol {
    func join(anchor: LiveStreamAnchor) async throws -> AudienceLiveRoomInfo {
        let data = try await APIClient.shared.post(
            "/api/agora/live/getRoomAndJoinRoom",
            body: ["searchValue": anchor.userId]
        )
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(code: "-1", message: L10n.liveRoomStatusFailed)
        }

        // 与 AudienceLiveRoomInfo 共用响应层级：部分接口版本把房态放在 agoraLiveSimpleVO。
        // 必须先判已结束/通话中，避免无意义地拉 token 并把状态页误显示成进房失败。
        var fields = response
        if let simple = response["agoraLiveSimpleVO"] as? [String: Any] {
            for (key, value) in simple where fields[key] == nil {
                fields[key] = value
            }
        }
        let roomState = Self.int(fields["liveRoomState"])
        let userStatus = Self.int(fields["userStatus"])
        let token: String?
        if roomState == 1 || userStatus == 10_000 {
            token = nil
        } else {
            token = try await LiveService.getAgoraRtmToken().rtcToken
        }
        guard let info = AudienceLiveRoomInfo(anchor: anchor, response: response, rtcToken: token) else {
            throw APIError(code: "-1", message: L10n.liveRoomStatusFailed)
        }
        return info
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
