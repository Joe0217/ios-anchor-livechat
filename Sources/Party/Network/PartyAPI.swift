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

    /// envelope.result 为 "null" 字面值时数组类型自动空数组
    private static func decodeArrayOrEmpty<T: Decodable>(_ data: Data, as: T.Type) throws -> [T] {
        if let s = String(data: data, encoding: .utf8), s == "null" { return [] }
        return try decoder.decode([T].self, from: data)
    }

    private static func decodeObject<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
        try decoder.decode(T.self, from: data)
    }

    // MARK: - room

    /// 房间模板列表（创建房间前选模板用）。
    /// `type` 参数语义待 implement 期对照接口返回；MVP 传 0 兜底。
    static func roomTempList(type: Int = 0) async throws -> [PartyRoomTemplate] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getRoomTempList",
            body: ["type": type]
        )
        return try decodeArrayOrEmpty(data, as: PartyRoomTemplate.self)
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
    static func roomList(
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
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/room/list", body: body)
        return try decodeArrayOrEmpty(data, as: PartyRoomInfo.self)
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

    /// 切换麦克风/摄像头开关。`type: 1=麦克风 2=摄像头`。
    /// 服务端成功后下发 NIM `1008 PARTY_ROOM_UPDATE_MEDIA` 广播给全员（M3 内分发）。
    /// `enable` 走 Int 1/0；M5 真机自检确认后端实际接受类型再切 Bool。
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
