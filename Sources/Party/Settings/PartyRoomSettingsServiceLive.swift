import Foundation

/// 生产实现（包装 PartyAPI；间接 SDK 依赖，不入 HilyTests 白名单）
struct PartyRoomSettingsServiceLive: PartyRoomSettingsService {
    func fetchLanguages() async throws -> [PartyLanguage] {
        try await PartyAPI.languageList()
    }
    func fetchBackgrounds() async throws -> [PartyBackground] {
        try await PartyAPI.backgroundList()
    }
    func fetchCurrentBackground(roomId: String) async throws -> PartyBackground? {
        try await PartyAPI.getRoomBgImage(roomId: roomId)
    }
    func setBackground(roomId: String, bgImgId: Int) async throws {
        try await PartyAPI.setBgImages(roomId: roomId, bgImgId: bgImgId)
    }
    func updateRoom(
        roomId: String,
        roomName: String?,
        roomAvatar: String?,
        greetingMessage: String?,
        roomLanguage: String?
    ) async throws {
        try await PartyAPI.updateRoom(
            roomId: roomId,
            roomName: roomName,
            roomAvatar: roomAvatar,
            greetingMessage: greetingMessage,
            roomLanguage: roomLanguage
        )
    }
}

struct PartyAdminServiceLive: PartyAdminService {
    func fetchAdminList(roomId: String) async throws -> [PartyRoomAdmin] {
        try await PartyAPI.roomAdminList(roomId: roomId)
    }
    func setAdmin(roomId: String, userId: String) async throws {
        try await PartyAPI.setRoomAdmin(roomId: roomId, userId: userId)
    }
    func removeAdmin(roomId: String, userId: String) async throws {
        try await PartyAPI.removeRoomAdmin(roomId: roomId, userId: userId)
    }
}
