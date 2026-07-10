import Foundation

/// PartyCreateService 的生产实现——包装 PartyAPI（间接依赖 SDK，**不入 HilyTests 白名单**）。
struct PartyCreateServiceLive: PartyCreateService {
    func fetchTemplates(type: Int) async throws -> [PartyRoomTemplate] {
        try await PartyAPI.roomTempList(type: type)
    }

    func fetchLanguages() async throws -> [PartyLanguage] {
        try await PartyAPI.languageList()
    }

    func fetchBackgrounds() async throws -> [PartyBackground] {
        try await PartyAPI.backgroundList()
    }

    func fetchCreateConditions() async throws -> PartyCreateConditions {
        try await PartyAPI.getCreateRoomConditions()
    }

    func createRoom(
        roomName: String,
        greetingMessage: String,
        roomLanguage: String,
        roomTempId: Int,
        roomAvatar: String?,
        bgImgId: Int?
    ) async throws -> PartyRoomInfo {
        try await PartyAPI.createRoom(
            roomName: roomName,
            roomAvatar: roomAvatar,
            greetingMessage: greetingMessage,
            roomLanguage: roomLanguage,
            roomTempId: roomTempId,
            bgImgId: bgImgId
        )
    }
}
