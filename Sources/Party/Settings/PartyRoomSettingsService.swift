import Foundation

/// 派对房设置页数据层协议（updateRoom / getRoomBgImage / setBgImages + 复用 languageList/backgroundList）。
protocol PartyRoomSettingsService: Sendable {
    func fetchLanguages() async throws -> [PartyLanguage]
    func fetchBackgrounds() async throws -> [PartyBackground]
    func fetchCurrentBackground(roomId: String) async throws -> PartyBackground?
    func setBackground(roomId: String, bgImgId: Int) async throws
    func updateRoom(
        roomId: String,
        roomName: String?,
        roomAvatar: String?,
        greetingMessage: String?,
        roomLanguage: String?
    ) async throws
}

/// 派对房管管理数据层协议
protocol PartyAdminService: Sendable {
    func fetchAdminList(roomId: String) async throws -> [PartyRoomAdmin]
    func setAdmin(roomId: String, userId: String) async throws
    func removeAdmin(roomId: String, userId: String) async throws
}
