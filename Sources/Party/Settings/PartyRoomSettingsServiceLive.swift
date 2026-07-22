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
    /// H5 用户端无独立"房管列表"接口；房管弹窗（`party-admin-popup.vue`）拉 `getViewers` 传 `type: 1`，
    /// 前端按 `roomRoleType === 2` 筛出"已是房管"。iOS 复用同路径。
    func fetchAdminList(roomId: String) async throws -> [PartyRoomAdmin] {
        let viewers = try await PartyAPI.partyOnlineViewers(roomId: roomId, type: 1)
        return viewers
            .filter { $0.roomRoleType == 2 }
            .map { PartyRoomAdmin(userId: $0.userId, nickname: $0.nickname, icon: $0.avatar) }
    }
    func setAdmin(roomId: String, userId: String) async throws {
        try await PartyAPI.setAdmin(roomId: roomId, userId: userId, operationType: 1)
    }
    func removeAdmin(roomId: String, userId: String) async throws {
        try await PartyAPI.setAdmin(roomId: roomId, userId: userId, operationType: 2)
    }
}
