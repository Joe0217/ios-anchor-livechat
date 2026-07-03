import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveService")

/// 心跳错误（B 里程碑 spec §3.3）。
enum HeartbeatError: Error, Equatable {
    case banned                                  // 1992 / 1006
    case noPermission                            // 2001
    case invalidPayload                          // 上行 body NSNull 守卫失败
    case unknown(code: String, message: String)  // 其它业务码
}

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
    let yxRoomId: Int?         // 云信聊天室 ID
    let hotScore: Int?
}

/// 直播开播相关接口（对应 H5 src/api/live）。请求头里的 loginToken 由 APIClient 自动附带。
enum LiveService {
    /// 获取我的直播间配置（含已存封面/简介）。返回原始字段，便于原样回传 beginLiveRoom。
    static func getMyLiveRoomRaw() async throws -> [String: Any] {
        let data = try await APIClient.shared.post("/api/agora/live/getMyLiveRoomV2")
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 开播建房。对齐 H5 `checkCanLive` 组装 payload（index.vue:214-226）：
    /// - `liveDescribe` 非空覆盖 settings 原值
    /// - `backgroundImgUrl` 若用户上传了新封面，覆盖服务端 default
    /// - `giftId/giftPrice/privateCallOpen`：选中 gift 时置 1；否则占位 NSNull/0
    /// - `wishlistList` 本次为空数组（愿望单归 H 里程碑）
    static func beginLiveRoomRaw(
        settings: [String: Any],
        liveDescribe: String,
        coverUrl: String? = nil,
        gift: (id: Int64, price: Int64)? = nil,
        wishlist: [[String: Any]] = [],
        promiseType: Int = 0,
        promiseTemplateId: Int64? = nil,
        promiseText: String? = nil
    ) async throws -> [String: Any] {
        var body = settings
        if !liveDescribe.isEmpty { body["liveDescribe"] = liveDescribe }
        if let coverUrl, !coverUrl.isEmpty { body["backgroundImgUrl"] = coverUrl }
        if let gift {
            body["giftId"] = gift.id
            body["giftPrice"] = gift.price
            body["privateCallOpen"] = 1
        } else {
            body["giftId"] = NSNull()
            body["giftPrice"] = NSNull()
            body["privateCallOpen"] = 0
        }
        body["wishlistList"] = wishlist
        body["promiseType"] = promiseType
        // 对齐 H5 checkCanLive:222-225：templateId 仅 promiseType==common 且 id>0 才下发；text 仅 type>0 才下发
        if promiseType == 1, let tid = promiseTemplateId, tid > 0 {
            body["promiseTemplateId"] = tid
        }
        if promiseType > 0, let text = promiseText, !text.isEmpty {
            body["promiseText"] = text
        }
        let data = try await APIClient.shared.post("/api/agora/live/beginLiveRoom", body: body)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 声网 token 接口（与 H5 myCallStore.rtcToken 同源；绑 uid、与 channel 无关）。
    static func getAgoraRtmToken() async throws -> AgoraRtmTokenResult {
        let data = try await APIClient.shared.post("/api/index/getAgoraRtmToken", body: [:])
        return try JSONDecoder().decode(AgoraRtmTokenResult.self, from: data)
    }

    /// 完整开播：getMyLiveRoom + beginLiveRoom + getAgoraRtmToken。
    /// 频道来自 agoraChannelId，token 来自 getAgoraRtmToken（绑 uid），uid 为 userId。
    ///
    /// - parameter coverUrl: 若非空覆盖服务端 default（用户在设置页刚上传的新封面）
    /// - parameter gift: 私 call 礼物（可选；选中即 privateCallOpen=1）
    static func startLive(
        liveDescribe: String,
        coverUrl: String? = nil,
        gift: (id: Int64, price: Int64)? = nil,
        wishlist: [[String: Any]] = [],
        promiseType: Int = 0,
        promiseTemplateId: Int64? = nil,
        promiseText: String? = nil
    ) async throws -> LiveRoomInfo {
        let settings = try await getMyLiveRoomRaw()
        // v5：优先用调用方传入的 coverUrl（用户新上传）；否则用服务端 default
        let effectiveCover = (coverUrl?.isEmpty == false) ? coverUrl : (settings["backgroundImgUrl"] as? String)
        guard let cover = effectiveCover, !cover.isEmpty else {
            throw APIError(code: "-1", message: L10n.liveErrorNoCover)
        }
        _ = cover  // 保留 fail-safe，实际由 beginLiveRoomRaw 传给后端
        let beginRes = try await beginLiveRoomRaw(
            settings: settings,
            liveDescribe: liveDescribe,
            coverUrl: coverUrl,
            gift: gift,
            wishlist: wishlist,
            promiseType: promiseType,
            promiseTemplateId: promiseTemplateId,
            promiseText: promiseText
        )
        var merged = settings
        for (k, v) in beginRes { merged[k] = v }
        let tokenRes = try await getAgoraRtmToken()
        logger.info("startLive channel=\(merged["agoraChannelId"] as? String ?? "nil") id=\(merged["id"] as? String ?? "nil") tokenLen=\(tokenRes.rtcToken?.count ?? 0)")
        return LiveRoomInfo(
            id: intValue(merged["id"]),
            agoraChannelId: merged["agoraChannelId"] as? String,
            rtcToken: tokenRes.rtcToken,
            userId: intValue(merged["userId"]),
            yxRoomId: intValue(merged["yxRoomId"]),
            hotScore: intValue(merged["hotScore"])
        )
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// 直播心跳（B 里程碑 spec §3.3）：10s 间隔由 HeartbeatController 驱动。
    /// 必须读 response code 并按 1992/2001 分流；禁止 try? 静默吞错。
    static func heartbeat(roomId: Int, callState: Int) async throws {
        let body: [String: Any] = ["roomId": roomId, "callState": callState]
        // CLAUDE.md NSNull 守卫：避免 NSNull 触发 OC 异常崩溃
        guard JSONSerialization.isValidJSONObject(body) else {
            throw HeartbeatError.invalidPayload
        }
        do {
            _ = try await APIClient.shared.post("/api/agora/liveHeartBeatV2", body: body)
        } catch let api as APIError {
            switch api.code {
            case "1992", "1006": throw HeartbeatError.banned
            case "2001":         throw HeartbeatError.noPermission
            default:             throw HeartbeatError.unknown(code: api.code, message: api.message)
            }
        }
    }

    /// 下播（B 里程碑 spec §10.2）：endType 数字编码 1/2/4/5/6/7（覆盖 H5 字符串编码）。
    static func endLiveRoom(endType: Int) async throws {
        _ = try await APIClient.shared.post("/api/agora/live/endLiveRoom", body: ["endType": endType])
    }

    /// 获取云信聊天室服务器地址（独立模式 enter 需要；当前未用）。
    static func getChatRoomAddress(roomId: String) async throws -> [String] {
        let data = try await APIClient.shared.post("/api/agora/live/getChatRoomAddress",
                                                   body: ["searchValue": roomId])
        if let arr = try? JSONDecoder().decode([String].self, from: data) {
            logger.info("getChatRoomAddress(\(roomId)) → \(arr.count) addrs")
            return arr
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let a = (obj["addrs"] as? [String]) ?? (obj["chatroomAddresses"] as? [String]) ?? (obj["addresses"] as? [String]) ?? []
            logger.info("getChatRoomAddress(\(roomId)) → object \(a.count) addrs, keys=\(Array(obj.keys))")
            return a
        }
        logger.error("getChatRoomAddress(\(roomId)) → unparseable")
        return []
    }
}
