import Foundation

/// 派对房 HTTP 端点封装（MVP 必接 10 个，spec §1.4.1）。
///
/// 路径前缀统一 `/sapi/weidou/v1/client/party`（H5 接口参考 §1 + `src/sapi/marketing/index.ts` 风格）。
/// 全部走 `PartyAPIClient`：vvi 域名 + sapi 鉴权 + envelope `code=='200'` + AES Hex 解密。
///
/// 错误：底层 `PartyAPIError` 抛上来，调用方按需 `PartyRoomErrorMapper.map(_)` 映射成 `PartyRoomError`。
/// 注意业务参数：
/// - 所有 seat/* 接口必带 `yxRoomId + roomTempId`（接口参考 §6 明示"易漏"）
/// - `updateMedia.enable` 用 Int 1/0 而非 Bool（兼容后端常见编码；M5 实测后端反馈再调）
enum PartyAPI {
    private static let pathPrefix = "/sapi/weidou/v1/client/party"
    private static let decoder = JSONDecoder()

    // MARK: - 私有解码辅助

    /// 兼容三种 sapi 返回 schema：
    /// 1. envelope.result 直接是数组 `[...]`
    /// 2. envelope.result 是分页包装 `{list/records/data/rows/items: [...], ...}`
    /// 3. envelope.result 是 "null" 字面值（视为空数组）
    /// 任一路径解码成功即返回；全部失败时打印 raw JSON 后抛具体 DecodingError 供排查字段类型不符。
    private static func decodeArrayOrEmpty<T: Decodable>(_ data: Data, as: T.Type) throws -> [T] {
        let rawPreview = String(data: data, encoding: .utf8) ?? "<binary>"
        if rawPreview == "null" { return [] }

        // 1. 直接数组
        if let arr = try? decoder.decode([T].self, from: data) { return arr }

        // 2. wrapper key 探测
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["list", "records", "data", "rows", "items"] {
                guard let inner = dict[key] else { continue }
                guard JSONSerialization.isValidJSONObject(inner) else { continue }
                if let innerData = try? JSONSerialization.data(withJSONObject: inner),
                   let arr = try? decoder.decode([T].self, from: innerData) {
                    AppLogger.party.info("[PartyAPI] decoded array via wrapper key '\(key, privacy: .public)'")
                    return arr
                }
            }
        }

        // 3. 全部失败 → 打 raw + 抛真实 DecodingError 让上层看到具体字段错
        // raw 是 AES 解密后的明文业务数据（含 PII / 收益等），Release 包必须脱敏
        AppLogger.party.error("[PartyAPI] decode array failed; raw=\(rawPreview, privacy: .private)")
        return try decoder.decode([T].self, from: data)
    }

    /// 单对象解码：兼容 envelope.result 是 `{... 业务字段 ...}` 直接对象 / `{data: {...}}` 包装。
    private static func decodeObject<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
        // 1. 直接对象
        if let obj = try? decoder.decode(T.self, from: data) { return obj }

        // 2. 单层包装探测
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["data", "result", "info"] {
                guard let inner = dict[key] else { continue }
                guard JSONSerialization.isValidJSONObject(inner) else { continue }
                if let innerData = try? JSONSerialization.data(withJSONObject: inner),
                   let obj = try? decoder.decode(T.self, from: innerData) {
                    AppLogger.party.info("[PartyAPI] decoded object via wrapper key '\(key, privacy: .public)'")
                    return obj
                }
            }
        }

        // 3. 失败 → 打 raw + 抛真实 DecodingError
        // raw 是 AES 解密后的明文业务数据（含 PII / 收益等），Release 包必须脱敏
        let rawPreview = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.error("[PartyAPI] decode object failed; raw=\(rawPreview, privacy: .private)")
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - room

    /// 房间模板列表（创建房间前选模板用）。
    ///
    /// **对齐 H5 用户端 `apiGetRoomTempList({type})`**（`livechat-h5/src/api/party/index.ts:36`）：
    /// - `type: 1` = Voice（纯语聊）
    /// - `type: 2` = Live+Voice（视频+语聊混合）
    /// - `type: 0` = MVP 兜底（当调用方未明示 mode 时用）
    static func roomTempList(type: Int = 0) async throws -> [PartyRoomTemplate] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getRoomTempList",
            body: ["type": type]
        )
        return try decodeArrayOrEmpty(data, as: PartyRoomTemplate.self)
    }

    /// 派对房支持语言列表（创建房间语言 picker 用）。
    ///
    /// **对齐 H5 用户端 `apiGetLanguageList()`**（`livechat-h5/src/api/party/index.ts:33`）：
    /// 无参 POST；response 是 `[{languageName, languageCode}]`。
    static func languageList() async throws -> [PartyLanguage] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/language/list",
            body: [:]
        )
        return try decodeArrayOrEmpty(data, as: PartyLanguage.self)
    }

    /// 创房权限校验（Party 首页点"创建"时前置 gate）。
    ///
    /// **对齐 H5 `apiGetPartyRoomAuth`** + 安卓 `PartyVM.getCreatePartyRoomConditions`。
    /// POST `/room/getCreateRoomConditions`，无参；response `{canCreateRoom, createRoomLevel, isWithlist}`。
    static func getCreateRoomConditions() async throws -> PartyCreateConditions {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getCreateRoomConditions",
            body: [:]
        )
        return try decodeObject(data, as: PartyCreateConditions.self)
    }

    /// 派对房背景图列表（创房 Background picker 用）。
    ///
    /// **对齐 H5 `apiGetPartyBgImages`** + 安卓 `getRoomBgImages`。
    /// POST `/room/getBgImages`，参数 `{pageSize, offset}`；response `[{id, imgUrl, bigImgUrl, bgImgName, duration}]`。
    static func backgroundList(pageSize: Int = 50, offset: Int = 0) async throws -> [PartyBackground] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getBgImages",
            body: ["pageSize": pageSize, "offset": offset]
        )
        return try decodeArrayOrEmpty(data, as: PartyBackground.self)
    }

    /// 创建房间。MVP 仅传 roomName + roomTempId；其他可选字段 F 期补 UI。
    static func createRoom(
        roomName: String,
        roomAvatar: String? = nil,
        greetingMessage: String? = nil,
        roomLanguage: String? = nil,
        roomTempId: Int,
        bgImgId: Int? = nil
    ) async throws -> PartyRoomInfo {
        var body: [String: Any] = [
            "roomName": roomName,
            "roomTempId": roomTempId,
        ]
        if let v = roomAvatar { body["roomAvatar"] = v }
        if let v = greetingMessage { body["greetingMessage"] = v }
        if let v = roomLanguage { body["roomLanguage"] = v }
        if let v = bgImgId { body["bgImgId"] = v }
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/room/create", body: body)
        return try decodeObject(data, as: PartyRoomInfo.self)
    }

    /// 房间列表（大厅）。游标分页：snapshotId 锁列表快照 + offset 翻页。
    ///
    /// 3 个 tab 走 3 个 endpoint（对齐 H5 用户端 `src/api/party/index.ts` L21/24/27）：
    /// - `.party`    → `/party/room/list`
    /// - `.followed` → `/party/room/followed/list`
    /// - `.recent`   → `/party/room/recent/list`
    /// 参数结构完全一致；Follow/Recent 强制不筛语言（H5 index.vue L96 语义：`tabIndex===0 ? languageCode : null`）。
    static func roomList(
        kind: PartyRoomListKind = .party,
        languageCode: String? = nil,
        snapshotId: String? = nil,
        offset: Int? = nil,
        pageSize: Int = 20,
        queryParam: String? = nil,
        version: String = "v2"
    ) async throws -> [PartyRoomInfo] {
        var body: [String: Any] = [
            "pageSize": pageSize,
            "version": version,
        ]
        if let v = languageCode { body["languageCode"] = v }
        if let v = snapshotId { body["snapshotId"] = v }
        if let v = offset { body["offset"] = v }
        if let v = queryParam { body["queryParam"] = v }
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)\(kind.endpointSuffix)", body: body)
        return try decodeArrayOrEmpty(data, as: PartyRoomInfo.self)
    }

    /// 我的派对房 + 家族信息（H5 `apiGetPartyRoomInfo`）。无 body，返回可能为 null/空对象（视为无 room）。
    /// 用于大厅浮动按钮"Create Room / My Room"分流：有 `myRoom.id` 且 `roomStatus != 2` → 显示 My Room。
    static func getMyRoomAndFamilyInfo() async throws -> PartyMyRoomInfoWrapper? {
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/room/getMyRoomAndFamilyInfo", body: [:])
        // 后端可能返回空对象/null——统一收敛为 nil
        do {
            return try decodeObject(data, as: PartyMyRoomInfoWrapper.self)
        } catch {
            return nil
        }
    }

    /// 进房。`isAnchor` 主播端固定 true。
    static func enterRoom(roomId: String, password: String? = nil) async throws -> PartyRoomInfo {
        var body: [String: Any] = [
            "roomId": roomId,
            "isAnchor": true,
        ]
        if let v = password { body["password"] = v }
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/room/enter", body: body)
        return try decodeObject(data, as: PartyRoomInfo.self)
    }

    /// 退房。`seatIndex` 传当前在麦的位号；不在麦时传 0。
    static func exitRoom(roomId: String, seatIndex: Int, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/exitRoom",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    // MARK: - seat

    static func seatList(roomId: String) async throws -> [PartyRoomSeat] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/list",
            body: ["roomId": roomId]
        )
        return try decodeArrayOrEmpty(data, as: PartyRoomSeat.self)
    }

    /// 上麦。返回 micId 字符串（接口参考 §3.B 描述返回 String，实际语义 M2 联调时确认）。
    /// 错误码 `ROOM_SEAT_IS_OCCUPIED / ROOM_SEAT_EMPTY` 由上层 `PartyRoomErrorMapper` 映射后触发自动重拉对账。
    /// `roomTempId` **Int（后端 Long）**——安卓确认结果 §2.2：全系统 DTO 是 Long。
    /// 调用方从 `PartyRoomInfo.roomTempId(String?)` 转：`Int(info.roomTempId ?? "1") ?? 1`。
    /// 排队 vs 直接占座由服务端按"房内角色 + 申请开关"决定，调用方需能处理「已入队」返回。
    static func onSeat(roomId: String, seatIndex: Int, yxRoomId: String, roomTempId: Int) async throws -> String {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/onSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "roomTempId": roomTempId,
            ]
        )
        if let s = try? decoder.decode(String.self, from: data) { return s }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func downSeat(roomId: String, seatIndex: Int, yxRoomId: String, roomTempId: Int) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/downSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "roomTempId": roomTempId,
            ]
        )
    }

    /// 切换麦克风/摄像头开关。`type: 1=麦克风 / 2=摄像头 / 3=麦+摄像头`（安卓确认 §2.3）。
    /// 服务端成功后下发 NIM `1008 PARTY_ROOM_UPDATE_MEDIA` 广播全员（M3 内分发）。
    /// `enable` Int 0/1（安卓确认 §2.3 后端 DTO 是 Integer）。
    /// 安卓接受视频位邀请后调 `updateMedia(type=3, enable=1)` 自动开摄像头。
    static func updateMedia(roomId: String, seatIndex: Int, type: Int, enable: Bool, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/updateMedia",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "type": type,
                "enable": enable ? 1 : 0,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    /// 响应视频位邀请（安卓确认 §3.8）。1040 弹窗后必须走此接口（**不是直接 onSeat**）。
    /// `action`: 1=接受 / 2=拒绝 / 3=超时；接受时后端内部置 byInvite=true 直接 doOnSeat（绕过排队与等级校验）。
    /// 接受成功后客户端再调 `updateMedia(type=3, enable=1)` 自动开摄像头。
    static func respondInvite(
        roomId: String,
        yxRoomId: String,
        seatIndex: Int,
        inviteId: String,
        action: Int,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/respondInvite",
            body: [
                "roomId": roomId,
                "yxRoomId": yxRoomId,
                "seatIndex": seatIndex,
                "inviteId": inviteId,
                "action": action,
                "roomTempId": roomTempId,
            ]
        )
    }

    // MARK: - gift

    /// 派对房送礼（普通骨架）。`scene` 固定 "PARTY_ROOM"。
    /// 服务端成功后下发 NIM `2049 RECEIVE_PARTY_ROOM_GIFT_COMPRESSED` 广播；
    /// 客户端按 2049 渲染（**不识别** 1007 老版双发，spec §1.2 决策）。
    static func sendGift(roomId: String, giftId: Int, num: Int, yxAccidList: [String]) async throws -> PartySendGiftResult {
        let body: [String: Any] = [
            "scene": "PARTY_ROOM",
            "roomId": roomId,
            "giftId": giftId,
            "num": num,
            "yxAccidList": yxAccidList,
        ]
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/gift/sendGift", body: body)
        return try decodeObject(data, as: PartySendGiftResult.self)
    }
}
