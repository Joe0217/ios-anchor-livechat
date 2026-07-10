import Foundation

/// 派对房创建流程数据层协议（E-spec v5 · B 档降档，2026-07-10）。
///
/// 对齐 H5 用户端 `livechat-h5/src/views/party/create.vue` 需要的 3 类接口。
/// **Live 实现见 `PartyCreateServiceLive`（依赖 PartyAPI，不入 HilyTests 白名单）**。
/// Preview / 单测走 `PartyCreateServicePreviewFake`。
protocol PartyCreateService: Sendable {
    /// 拉模板列表（H5: `apiGetRoomTempList({type})`）
    /// - Parameter type: 1=Voice / 2=Live+Voice
    func fetchTemplates(type: Int) async throws -> [PartyRoomTemplate]

    /// 拉语言列表（H5: `apiGetLanguageList()`）
    func fetchLanguages() async throws -> [PartyLanguage]

    /// 拉背景图列表（H5: `apiGetPartyBgImages`；对齐安卓 `getRoomBgImages`）
    func fetchBackgrounds() async throws -> [PartyBackground]

    /// 拉创房权限（H5: `apiGetPartyRoomAuth`；对齐安卓 `getCreatePartyRoomConditions`）
    func fetchCreateConditions() async throws -> PartyCreateConditions

    /// 提交创房（H5: `apiCreatePartyRoom`；对齐安卓 6 字段）
    func createRoom(
        roomName: String,
        greetingMessage: String,
        roomLanguage: String,
        roomTempId: Int,
        roomAvatar: String?,
        bgImgId: Int?
    ) async throws -> PartyRoomInfo
}

// MARK: - PreviewFake（Preview / 单测用）

struct PartyCreateServicePreviewFake: PartyCreateService {
    enum Kind: Sendable {
        case success
        case delayThenSuccess(delayNanos: UInt64)
        case networkError
        case businessError(code: String, message: String)
    }

    let templates: [PartyRoomTemplate]
    let languages: [PartyLanguage]
    let backgrounds: [PartyBackground]
    let conditions: PartyCreateConditions
    let createResult: Kind

    init(
        templates: [PartyRoomTemplate] = [],
        languages: [PartyLanguage] = [],
        backgrounds: [PartyBackground] = [],
        conditions: PartyCreateConditions = PartyCreateConditions(canCreateRoom: true, createRoomLevel: nil, isWithlist: nil),
        createResult: Kind = .success
    ) {
        self.templates = templates
        self.languages = languages
        self.backgrounds = backgrounds
        self.conditions = conditions
        self.createResult = createResult
    }

    func fetchTemplates(type: Int) async throws -> [PartyRoomTemplate] {
        try Task.checkCancellation()
        return templates
    }

    func fetchLanguages() async throws -> [PartyLanguage] {
        try Task.checkCancellation()
        return languages
    }

    func fetchBackgrounds() async throws -> [PartyBackground] {
        try Task.checkCancellation()
        return backgrounds
    }

    func fetchCreateConditions() async throws -> PartyCreateConditions {
        try Task.checkCancellation()
        return conditions
    }

    func createRoom(roomName: String, greetingMessage: String, roomLanguage: String, roomTempId: Int, roomAvatar: String?, bgImgId: Int?) async throws -> PartyRoomInfo {
        switch createResult {
        case .success:
            return Self.makeFakeRoom(id: "fake-room-\(roomTempId)", name: roomName)
        case .delayThenSuccess(let delay):
            try await Task.sleep(nanoseconds: delay)
            try Task.checkCancellation()
            return Self.makeFakeRoom(id: "fake-room-\(roomTempId)", name: roomName)
        case .networkError:
            throw PartyCreateFakeError.networkError
        case .businessError(let code, let message):
            throw PartyCreateFakeError.businessError(code: code, message: message)
        }
    }

    private static func makeFakeRoom(id: String, name: String) -> PartyRoomInfo {
        let json: [String: Any] = ["id": id, "roomName": name]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(PartyRoomInfo.self, from: data)
    }
}

enum PartyCreateFakeError: Error, Equatable, Sendable {
    case networkError
    case businessError(code: String, message: String)
}
