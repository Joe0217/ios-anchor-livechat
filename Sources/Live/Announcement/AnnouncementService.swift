import Foundation

/// Announcement 数据源 protocol（H 里程碑接入真 API 时 replace Fakes → Real）
///
/// **真 API 契约**（对齐 H5 liveAnnouncementPopup.vue store 调用点）：
/// - 查询: POST `/api/agora/live/getLiveAnnouncement`  body: `{ searchValue: roomId }`
/// - 保存: POST `/api/agora/live/editLiveAnnouncement`  body: `{ content, roomId }`  （content='' = 清空）
/// - 敏感词错误码 1070；返回命中词列表
/// - 加密: AES-128-CBC + Hex（走 APIClient 主链路自动处理）
protocol AnnouncementServiceProtocol {
    func fetch(roomId: String) async throws -> LiveAnnouncement
    func save(content: String, roomId: String) async throws
}

/// Fakes 实现（Level B）
struct AnnouncementServiceFakes: AnnouncementServiceProtocol {
    func fetch(roomId: String) async throws -> LiveAnnouncement {
        try await Task.sleep(nanoseconds: 200_000_000)
        return LiveAnnouncement(content: "Welcome to my live! Enjoy the show ✨")
    }

    func save(content: String, roomId: String) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        // no-op（Fakes 不持久化到后端）
    }
}

/// 真 API 实现（H 里程碑接入）
///
/// TODO H 里程碑：
/// ```
/// let body: [String: Any] = ["searchValue": roomId]
/// let resp = try await APIClient.shared.post("/api/agora/live/getLiveAnnouncement", body: body)
/// // parse content; 处理 code=1070 → throw .sensitiveWords(hits:)
/// ```
struct AnnouncementServiceReal: AnnouncementServiceProtocol {
    func fetch(roomId: String) async throws -> LiveAnnouncement {
        try await AnnouncementServiceFakes().fetch(roomId: roomId)
    }
    func save(content: String, roomId: String) async throws {
        try await AnnouncementServiceFakes().save(content: content, roomId: roomId)
    }
}
