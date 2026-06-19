import Foundation

/// getAgoraRtmToken 响应（join 用的声网 token）。
struct AgoraRtmTokenResult: Codable {
    let rtcToken: String?
    let rtmToken: String?
    let channelId: String?
}

/// beginLiveRoom 返回的开播信息（取关键字段）。
struct LiveRoomInfo: Codable {
    let id: Int?               // 直播间 ID（心跳 roomId）
    let agoraChannelId: String?
    let rtcToken: String?
    let userId: Int?           // 主播 uid（与 rtcToken 绑定）
    let yxRoomId: Int?         // 云信聊天室 ID（后续阶段用）
    let hotScore: Int?
}

/// 直播开播相关接口（对应 H5 src/api/live）。请求头里的 loginToken 由 APIClient 自动附带。
enum LiveService {
    /// 获取我的直播间配置（含已存封面/简介）。返回原始字段，便于原样回传 beginLiveRoom。
    static func getMyLiveRoomRaw() async throws -> [String: Any] {
        let data = try await APIClient.shared.post("/api/agora/live/getMyLiveRoomV2")
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 开播建房。对齐 H5：把 getMyLiveRoom 的配置整体回传，并附礼物/愿望单字段。
    /// 返回 beginLiveRoom 的原始响应（与 getMyLiveRoom 合并后才有完整频道/token）。
    static func beginLiveRoomRaw(settings: [String: Any], liveDescribe: String) async throws -> [String: Any] {
        var body = settings
        if !liveDescribe.isEmpty { body["liveDescribe"] = liveDescribe }
        body["giftId"] = NSNull()
        body["giftPrice"] = NSNull()
        body["privateCallOpen"] = 0
        body["wishlistList"] = []
        let data = try await APIClient.shared.post("/api/agora/live/beginLiveRoom", body: body)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 声网 token 接口（与 H5 myCallStore.rtcToken 同源）。
    static func getAgoraRtmToken() async throws -> AgoraRtmTokenResult {
        let data = try await APIClient.shared.post("/api/index/getAgoraRtmToken", body: [:])
        return try JSONDecoder().decode(AgoraRtmTokenResult.self, from: data)
    }

    /// 完整开播：getMyLiveRoom(拿频道/配置) + beginLiveRoom(建房) + getAgoraRtmToken(拿 join token)。
    /// 对齐 H5：频道来自 agoraChannelId，token 来自 getAgoraRtmToken，uid 为 userId。
    static func startLive(liveDescribe: String) async throws -> LiveRoomInfo {
        let settings = try await getMyLiveRoomRaw()
        guard let cover = settings["backgroundImgUrl"] as? String, !cover.isEmpty else {
            throw APIError(code: "-1", message: "账号还没有直播封面，请先在主端设置封面后再试")
        }
        let beginRes = try await beginLiveRoomRaw(settings: settings, liveDescribe: liveDescribe)
        // 合并 getMyLiveRoom + beginLiveRoom（频道/roomId/uid 在这里）
        var merged = settings
        for (k, v) in beginRes { merged[k] = v }
        // join token 来自 getAgoraRtmToken（与 H5 一致）
        let tokenRes = try await getAgoraRtmToken()
        print("🔧 [Live] channel=\(merged["agoraChannelId"] ?? "nil") id=\(merged["id"] ?? "nil") userId=\(merged["userId"] ?? "nil") rtcToken=\((tokenRes.rtcToken)?.prefix(12) ?? "nil")")
        // 手动取字段，避免后端字段类型（浮点/字符串）与严格解码不匹配导致整体失败
        return LiveRoomInfo(
            id: intValue(merged["id"]),
            agoraChannelId: merged["agoraChannelId"] as? String,
            rtcToken: tokenRes.rtcToken,
            userId: intValue(merged["userId"]),
            yxRoomId: intValue(merged["yxRoomId"]),
            hotScore: intValue(merged["hotScore"])
        )
    }

    /// 从 Int / NSNumber(含浮点) / 字符串 中稳健取整数
    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// 直播心跳（每 6s）。callState=0 直播中。
    static func heartbeat(roomId: Int) async throws {
        _ = try await APIClient.shared.post("/api/agora/liveHeartBeatV2",
                                            body: ["roomId": roomId, "callState": 0])
    }

    /// 下播（正常关闭无需 body）。
    static func endLiveRoom() async throws {
        _ = try await APIClient.shared.post("/api/agora/live/endLiveRoom")
    }

    /// 获取云信聊天室服务器地址（独立模式 enter 需要）。
    /// 对齐 H5 useCallApi.joinChatRoom：getChatRoomAddress({ searchValue: roomId }) 的 result 直接就是地址数组。
    static func getChatRoomAddress(roomId: String) async throws -> [String] {
        let data = try await APIClient.shared.post("/api/agora/live/getChatRoomAddress",
                                                   body: ["searchValue": roomId])
        // result 直接是字符串数组（H5 直接赋值）；兼容包在 addrs/chatroomAddresses/addresses 的情况
        if let arr = try? JSONDecoder().decode([String].self, from: data) {
            print("🟣 [Chatroom] getChatRoomAddress(\(roomId)) → \(arr.count) 个地址: \(arr)")
            return arr
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let a = (obj["addrs"] as? [String]) ?? (obj["chatroomAddresses"] as? [String]) ?? (obj["addresses"] as? [String]) ?? []
            print("🟣 [Chatroom] getChatRoomAddress(\(roomId)) → 对象内 \(a.count) 个地址: \(a) | 原始keys=\(Array(obj.keys))")
            return a
        }
        print("🔴 [Chatroom] getChatRoomAddress(\(roomId)) → 无法解析地址, data=\(String(data: data, encoding: .utf8) ?? "<二进制>")")
        return []
    }
}
