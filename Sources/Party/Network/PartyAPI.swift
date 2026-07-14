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

    // MARK: - room settings（设置功能，2026-07-13 v8）

    /// 更新房间信息（房主设置页 save 时调）。
    /// 对齐 H5 `apiPartyUpdateRoom` 与安卓 `updateRoom`。
    /// **仅传变更 diff**（对齐 H5 create.vue:296-302；nil 参数跳过 body key）。
    static func updateRoom(
        roomId: String,
        roomName: String? = nil,
        roomAvatar: String? = nil,
        greetingMessage: String? = nil,
        roomLanguage: String? = nil
    ) async throws {
        var body: [String: Any] = ["roomId": roomId]
        if let v = roomName { body["roomName"] = v }
        if let v = roomAvatar { body["roomAvatar"] = v }
        if let v = greetingMessage { body["greetingMessage"] = v }
        if let v = roomLanguage { body["roomLanguage"] = v }
        _ = try await PartyAPIClient.shared.post("\(pathPrefix)/room/updateRoom", body: body)
    }

    /// 拉当前房间的背景（编辑态显示 selectedBackground 用）。
    /// 对齐 H5 `apiGetRoomBgImage`（index.ts:260）。
    static func getRoomBgImage(roomId: String) async throws -> PartyBackground? {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getRoomBgImage",
            body: ["roomId": roomId]
        )
        return try? decodeObject(data, as: PartyBackground.self)
    }

    /// 设置房间背景（编辑态即时保存，选完 sheet close 就调）。
    /// 对齐 H5 `apiSetPartyBgImage`（index.ts:257）。
    static func setBgImages(roomId: String, bgImgId: Int) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/setBgImages",
            body: ["roomId": roomId, "bgImgId": bgImgId]
        )
    }

    /// 房管列表（房主设置页 Admin 子页拉）。**待真机验证 path/字段**（对齐 agent-recon-field-names-unverified rule）
    static func roomAdminList(roomId: String) async throws -> [PartyRoomAdmin] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getRoomAdminList",
            body: ["roomId": roomId]
        )
        return try decodeArrayOrEmpty(data, as: PartyRoomAdmin.self)
    }

    /// 设为房管
    static func setRoomAdmin(roomId: String, userId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/setRoomAdmin",
            body: ["roomId": roomId, "userId": userId]
        )
    }

    /// 撤销房管
    static func removeRoomAdmin(roomId: String, userId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/removeRoomAdmin",
            body: ["roomId": roomId, "userId": userId]
        )
    }

    // MARK: - lock room (E spec §3 Lock Room)

    /// 房间加/解锁（E spec §3）。对齐 H5 `apiPartylockRoom`（`src/api/party/index.ts:177`）。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/lockRoom`
    /// **加锁 payload**：`{ roomId: Int64, password: "1234", lockRoomFlag: 1 }`（H5 硬编码 4 位数字）
    /// **解锁 payload**：`{ roomId: Int64, lockRoomFlag: 0 }`（password 字段省略，对齐 H5 `feachLockRoom({ lockFlag: 0 })`）
    ///
    /// - **字段名 `lockRoomFlag`（非 `lockFlag`）**：对齐 H5 payload 字面（spec §0 校验点）
    /// - **roomId Int64**：H5 用户端 `roomId * 1` 数字化，与 sendGift 同款陷阱（避免后端 400）
    /// - **response 无 lockFlag 回填**：客户端本地乐观更新 `roomInfo.lockFlag`（对齐 H5）
    /// - **无 IM 广播**：加锁瞬间已在房观众不 kick；跨端一致靠 `enterRoom` 拦截返 10006 触发密码弹窗
    ///
    /// truthy 即成功（对齐 setBgImages / switchRoomTemp pattern）；envelope `code!='0000'` 由
    /// PartyAPIClient 抛 PartyAPIError.business，调用方转 error toast。
    static func lockRoom(roomId: String, password: String?) async throws {
        var body: [String: Any] = [
            "lockRoomFlag": password == nil ? 0 : 1,
        ]
        // roomId 数字化（H5 `id * 1` 对齐）—— fallback 到 String 兼容非数字 id 极端场景
        if let roomIdInt = Int64(roomId) {
            body["roomId"] = roomIdInt
        } else {
            body["roomId"] = roomId
        }
        if let password = password {
            body["password"] = password
        }
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/lockRoom",
            body: body
        )
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
        let rooms = try decodeArrayOrEmpty(data, as: PartyRoomInfo.self)
        // v7 诊断（2026-07-14）：后端可能对主播端账号返 [] —— 打 log 让真机能确认到底是 rooms=[] 还是 decode 失败
        // rawPreview 是 AES 解密后明文；Release 打脱敏
        let rawPreview = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.info("[PartyAPI] roomList kind=\(kind.endpointSuffix, privacy: .public) count=\(rooms.count) raw=\(rawPreview, privacy: .private)")
        return rooms
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

    /// 拉用户基础信息（对齐 H5 `apiPartyGetUser({userId})`）。
    /// endpoint 特殊：**不带 pathPrefix `/party` 段**（H5 是 `/sapi/weidou/v1/client/user/get`），
    /// 因此显式拼绝对 path 而非 `pathPrefix+/room/...` 模式。
    /// 主播端派对房用途：拉房主 ownerInfo → `headFrameSmallImg` 装饰顶部头像框。
    static func getUserBasicInfo(userId: Int) async throws -> PartyUserBasicInfo? {
        let data = try await PartyAPIClient.shared.post(
            "/sapi/weidou/v1/client/user/get",
            body: ["userId": userId]
        )
        // 后端可能返回 null / 空对象（用户已注销等）—— 静默降级 nil
        do {
            return try decodeObject(data, as: PartyUserBasicInfo.self)
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

    /// 禁麦/解禁麦（房主/房管专用；对齐 H5 apiPartyProhibitSeat + usePartyHooks.js:1157 `feachProhibitSeat`）。
    /// - operatorType: **6=禁麦，7=解禁麦**（H5 硬编码 magic number；后端 DTO 强校验）
    /// - 作用于**占用位**（切换 seatMicrophoneEnabled 服务端管理态，独立于用户自身 microphoneEnabled）
    /// - 成功后服务端下发 1008 updateMedia 广播全员（seat.seatMicrophoneEnabled 切换），前端不做乐观更新
    static func prohibitSeat(
        roomId: String,
        seatIndex: Int,
        yxRoomId: String,
        operatorType: Int,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/prohibitSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "operatorType": operatorType,
                "roomTempId": roomTempId,
            ]
        )
    }

    /// 锁麦/解锁麦（房主/房管专用；对齐 H5 apiPartylockSeat + usePartyHooks.js:1205 `feachLockSeat`）。
    /// - operatorType: **8=锁麦，9=解锁**（H5 硬编码 magic number；后端 DTO 强校验）
    /// - 只作用于**空位**（有人时后端会拒；调用方需前置校验）
    /// - 成功后服务端下发 1001 seat/update 广播全员（seat.lockFlag 切换），前端不做乐观更新
    static func lockSeat(
        roomId: String,
        seatIndex: Int,
        yxRoomId: String,
        operatorType: Int,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/lockSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "operatorType": operatorType,
                "roomTempId": roomTempId,
            ]
        )
    }

    /// 切麦：从当前麦位切到目标 seatIndex（对齐 H5 apiPartyExchangeSeat + usePartyHooks.js:1322）。
    /// - operatorType 固定 10（H5 硬编码）
    /// - seatType 传目标麦位的 seatType（1=video / 2=voice）
    /// 成功后服务端下发 1001 seat/update 广播全员，前端等 seatList 更新，不做乐观。
    static func exchangeSeat(
        roomId: String,
        seatIndex: Int,
        yxRoomId: String,
        seatType: Int,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/exchangeSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "operatorType": 10,
                "seatType": seatType,
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

    // MARK: - MC Seat (E spec §3, 2026-07-14)

    /// 设置接待位 MC Seat（E spec §3）。对齐 H5 `apiSetHostSeat`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/seat/setHostSeat`
    /// **body**：`{ roomId, seatIndex, yxRoomId, roomTempId }`
    ///
    /// - 权限：Owner / PlatformAdmin（后端强校验；前端 tools sheet 已门控）
    /// - 全房至多 1 个 MC 位（服务端保证）；重复设置不同 seatIndex 时后端会自动清旧
    /// - 成功后服务端下发 1001 seat/update 广播 → 前端 seatList 全量替换自然刷新
    /// - **字段名/method/path 未真机验证**（agent-recon-field-names-unverified rule）；
    ///   首次真机拉取后按 Console log 回写 alias 兜底
    static func setMCSeat(
        roomId: String,
        seatIndex: Int,
        yxRoomId: String,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/setHostSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "roomTempId": roomTempId,
            ]
        )
    }

    /// 关闭接待位 MC Seat（E spec §3）。对齐 H5 `apiCloseHostSeat`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/seat/closeHostSeat`
    /// **body**：`{ roomId, yxRoomId, roomTempId }`（**无 seatIndex** —— MC 全房唯一，服务端按 roomId 定位）
    ///
    /// - 权限：Owner / PlatformAdmin
    /// - 成功后服务端下发 1001 seat/update 广播 → 前端 seatList 全量替换自然刷新
    /// - 无二次确认由 UI 层遵循（对齐 H5）
    static func closeMCSeat(
        roomId: String,
        yxRoomId: String,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/closeHostSeat",
            body: [
                "roomId": roomId,
                "yxRoomId": yxRoomId,
                "roomTempId": roomTempId,
            ]
        )
    }

    // MARK: - room mode (E v2 §1)

    /// 切换房间模板（Room Mode 切模式）。spec §1 契约。
    /// 对齐 H5 `apiSwitchRoomTemp({roomId, roomTempId, yxRoomId})`。
    /// 无字段消费；truthy 即成功。房主本地兜底：成功后立即调 `handleRoomModeChanged`，
    /// 不等 IM 1017（云信可能不发自己回执），观众端走 IM 到达路径 + `roomTempId==newTempId` 幂等。
    static func switchRoomTemp(roomId: String, roomTempId: Int, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/switchRoomTemp",
            body: [
                "roomId": roomId,
                "roomTempId": roomTempId,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    // MARK: - mic application (E v2 §2)

    /// 拉排麦申请列表（房主/房管端 Mic Application 面板用）。spec §2 契约。
    /// 对齐 H5 `apiGetQueueSeatList({roomId, pageSize})`。
    /// `myIndex = -1` 表示当前用户不在列表；`totalNum` 队列总长度用于 badge / 系统消息计数。
    static func getQueueSeatList(roomId: String, pageSize: Int = 99) async throws -> PartyMicApplicationListResponse {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/getQueueSeatList",
            body: [
                "roomId": roomId,
                "pageSize": pageSize,
            ]
        )
        return try decodeObject(data, as: PartyMicApplicationListResponse.self)
    }

    /// 拒绝申请（房主/房管操作，spec §2）。对齐 H5 `apiRefuseQueueSeat`。
    /// 服务端成功后下发 1018 op=3 广播；申请者本地设 `rejectedAt = now` 触发 30s 冷却。
    static func refuseQueueSeat(roomId: String, targetUserId: String, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/refuseQueueSeat",
            body: [
                "roomId": roomId,
                "targetUserId": targetUserId,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    /// 通过申请（房主/房管操作，spec §2）。对齐 H5 `apiAgreeSeat`。
    /// - `seatIndex`：房主端挑首空位（排除 `pendingApproveSeatIndex` 已占位集合防并发冲突）
    /// - `operatorType`：房主端硬编 1；房管路径待真机验证后回填（spec §5 TODO）
    /// - 服务端成功后下发 1001/1012（麦位刷新）+ 1018 op=2（出队通知）组合，无独立"批准"广播
    static func agreeSeat(
        roomId: String,
        seatIndex: Int,
        targetUserId: String,
        operatorType: Int,
        roomTempId: Int,
        yxRoomId: String
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/agreeSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "targetUserId": targetUserId,
                "operatorType": operatorType,
                "roomTempId": roomTempId,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    /// 切换排麦申请开关（房主端，spec §2）。对齐 H5 `apiUpdateOnSeatEnable({roomId, enable})`。
    /// `enable: 0` 关闭 / `1` 开启；服务端成功后下发 1021 广播全员同步 `onSeatApplySwitch`。
    /// 首次切换需 UI 层前置协议弹窗（`partySaveInfo.autoEnterOn/OffApplication` = false 时）。
    static func updateOnSeatEnable(roomId: String, enable: Int) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/updateOnSeatEnable",
            body: [
                "roomId": roomId,
                "enable": enable,
            ]
        )
    }

    /// 观众放弃排麦（spec §2）。对齐 H5 `apiGiveUpQueueSeat({roomId, yxRoomId})`。
    /// 成功后本地清 `myApplyInfo.inIndex = 0` + toast；服务端下发 1018 op=4 广播。
    static func giveUpQueueSeat(roomId: String, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/giveUpQueueSeat",
            body: [
                "roomId": roomId,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    // MARK: - blocklist (E spec §1，房主/房管房间维度黑名单)

    /// 拉房间黑名单列表（E spec §1）。对齐 H5 `apiGetKickOutBlacklist`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/getKickOutBlacklist`
    /// **body**：`{ roomId: Int }` —— roomId 传业务 db id（H5 `currentPartyInfo.id`，**非**云信 yxRoomId）
    /// **response**：**直接数组** `[PartyBlocklistItem]`（无 list/records 包装；spec §0 校验 point 2）
    ///
    /// 无分页（H5 全量拉，van-list 只做壳未配 finished/loading —— iOS 沿用全量策略，量级由后端保证）。
    static func getKickOutBlacklist(roomId: Int) async throws -> [PartyBlocklistItem] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getKickOutBlacklist",
            body: ["roomId": roomId]
        )
        return try decodeArrayOrEmpty(data, as: PartyBlocklistItem.self)
    }

    /// 解除封禁（E spec §1）。对齐 H5 `apiRemoveKickOutBlacklist`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/removeKickOutBlacklist`
    /// **body**：`{ roomId: Int, targetUserId: String }`
    /// **response**：Bool（真为成功；后端可能返裸 `true` / envelope 包装 `{data: true}` / `{result: true}`）
    ///
    /// H5 存在 bug：`.then/.finally` 均弹"Removed successfully"，失败静默 —— iOS 修正走 error toast
    /// （spec §0 校验 point 6）。此方法失败抛异常由调用方转 error toast。
    ///
    /// 加/解黑本 spec 范围内**无 IM 广播**（H5 blocklist.vue 无订阅；spec §2）——调用成功后由 Store 层
    /// 乐观 filter 本地 items，其他管理员端下次开 popup 才见新态。
    static func removeKickOutBlacklist(roomId: Int, targetUserId: String) async throws -> Bool {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/removeKickOutBlacklist",
            body: [
                "roomId": roomId,
                "targetUserId": targetUserId,
            ]
        )
        // 1. 裸 Bool
        if let b = try? decoder.decode(Bool.self, from: data) { return b }
        // 2. 单层包装 {data|result|success: true}
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["data", "result", "success"] {
                if let v = dict[key] as? Bool { return v }
                if let n = dict[key] as? NSNumber { return n.boolValue }
            }
        }
        // 3. 字符串 "true" / "1"
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if s == "true" || s == "1" { return true }
            if s == "false" || s == "0" { return false }
        }
        // 4. 空 / 未识别 —— 后端 sapi envelope code==200 已由 PartyAPIClient 层过滤成功，
        //    到这里说明 HTTP 层成功但 body 无明确 Bool；默认视为成功
        return true
    }

    // MARK: - gift

    /// 派对房礼物架列表（H-5 · 对齐 H5 用户端 `apiPartyGetRoomGift`）。
    ///
    /// **path**: `/sapi/weidou/v1/client/party/gift/getPartyRoomGift`（sapi 域，与 sendGift 同域）
    /// **⚠️ 不走** `/api/gift/v3/getGiftList`（主接口不识别 PARTY_ROOM/PARTY_GIFT scene → parameter.error）
    ///
    /// **Request body**（H5 `stores/modules/party.js:1269-1272`）：
    /// - `showType`: 0=礼物架 / 1=底部栏（默认 0）
    /// - `apiVersion`: 2 触发后端 tabs[] 结构（灰度关闭时后端自动 v1 回退）
    ///
    /// **Response 结构**：`{tabs: [{tabCode, tabName, tabSort, gifts: [GiftListData]}]}`
    /// v1 兜底（`{giftInfoDtoList: {Popular: [...], ...}}`）由调用侧另作 fallback；本方法只识别 v2。
    static func getPartyRoomGift(showType: Int = 0, apiVersion: Int = 2) async throws -> PartyGiftV2Response {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/gift/getPartyRoomGift",
            body: [
                "showType": showType,
                "apiVersion": apiVersion,
            ]
        )
        return try decodeObject(data, as: PartyGiftV2Response.self)
    }

    /// 派对房送礼。`scene` 固定 "PARTY_ROOM"（对齐 H5 party-gift-popup.vue L417 字面值）。
    /// 服务端成功后下发 NIM `2049 RECEIVE_PARTY_ROOM_GIFT_COMPRESSED` 广播；
    /// 客户端按 2049 渲染（**不识别** 1007 老版双发，spec §1.2 决策）。
    ///
    /// **⚠️ roomId 类型陷阱**（2026-07-14 真机 400 修复）：H5 用户端 `partyStore.currentPartyInfo.id * 1` 把
    /// roomId 数字化再传（party-gift-popup.vue L419）。iOS 若传 String → JSON 序列化成 `"roomId":"1234567"`
    /// → 后端 code=400 "Illegal parameter"。**必须转 Int64 传数字**。
    static func sendGift(roomId: String, giftId: Int, num: Int, yxAccidList: [String]) async throws -> PartySendGiftResult {
        var body: [String: Any] = [
            "scene": "PARTY_ROOM",
            "giftId": giftId,
            "num": num,
            "yxAccidList": yxAccidList,
        ]
        // roomId 数字化（H5 `id * 1` 对齐）—— fallback 到 String 兼容非数字 id 极端场景
        if let roomIdInt = Int64(roomId) {
            body["roomId"] = roomIdInt
        } else {
            body["roomId"] = roomId
        }
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/gift/sendGift", body: body)
        return try decodeObject(data, as: PartySendGiftResult.self)
    }

    // MARK: - party call (F spec §4.3)

    /// 更新房间私 call 开关（房主设置弹窗调用）。对齐安卓 `HttpHelper.updatePartyPrivateCall`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/updatePartyPrivateCall`
    /// **body**：`{ roomId: String, enable: Int(0/1), giftId: String? }`
    ///
    /// - 权限：Owner / RoomAdmin / PlatformAdmin（后端强校验）
    /// - 关闭状态下用户端拨打时后端拦截，主播端不收 RTM VideoCall
    /// - 成功后可能下发 1029 payload `status=calling/ended` 更新其他客户端（本 spec 不做本地乐观回写）
    ///
    /// **⚠️ 字段名/method 未真机验证**（agent-recon-field-names-unverified rule）；
    /// Step 3 真机首次调用后按 log 补 alias 兼容。
    static func updatePartyPrivateCall(
        roomId: String,
        enable: Int,
        giftId: String? = nil
    ) async throws {
        var body: [String: Any] = [
            "roomId": roomId,
            "enable": enable,
        ]
        if let v = giftId { body["giftId"] = v }
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/updatePartyPrivateCall",
            body: body
        )
    }

    /// 拉私 call 礼物列表（房主设置弹窗内选礼物用）。对齐安卓 `ApiService.getPartyCallGiftList`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/getPartyCallGiftList`
    /// **body**：`{ scene: Int }` —— `scene=2` 设置弹窗（本 spec 仅用此场景）；`scene=1` 通话内送礼（后续里程碑）
    /// **response**：`[PartyCallGiftItem]`
    ///
    /// **⚠️ 字段名/scene 语义未真机验证**（agent-recon-field-names-unverified rule）；
    /// Step 3 真机首次拉取后按 log 补 alias 兼容 PartyCallGiftItem 字段。
    static func getPartyCallGiftList(scene: Int = 2) async throws -> [PartyCallGiftItem] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getPartyCallGiftList",
            body: ["scene": scene]
        )
        return try decodeArrayOrEmpty(data, as: PartyCallGiftItem.self)
    }
}

/// 排麦申请列表 API response（`getQueueSeatList` 的 DTO 包装，spec §2）。
///
/// 字段来源：H5 `apiGetQueueSeatList` response 起草推断；真机 log 未验证前所有字段用兜底
/// (agent-recon-field-names-unverified rule)。手写 `init(from:)` 让缺字段回退到安全默认值，
/// 而非整体 decode 失败（列表接口整体挂 = 房主 Mic Application 面板整体瘫）。
struct PartyMicApplicationListResponse: Decodable, Equatable {
    /// 队列总长度（可能超过 records.count；records 受 pageSize 限制）
    let totalNum: Int
    /// 排麦申请人列表（按排队顺序）
    let records: [PartyMicApplication]
    /// 当前用户在队列中的位序；`-1` 表示不在队列（房主/房管拉时通常 -1）
    let myIndex: Int

    private enum CodingKeys: String, CodingKey {
        case totalNum, records, myIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 缺字段兜底：totalNum/records 缺失时视为空列表；myIndex 缺失视为不在队
        self.totalNum = (try? c.decode(Int.self, forKey: .totalNum)) ?? 0
        self.records = (try? c.decode([PartyMicApplication].self, forKey: .records)) ?? []
        self.myIndex = (try? c.decode(Int.self, forKey: .myIndex)) ?? -1
    }
}
