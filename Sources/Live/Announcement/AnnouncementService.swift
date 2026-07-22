import Foundation

/// Announcement 数据源协议。
///
/// **真 API 契约**（对齐 H5 liveAnnouncementPopup.vue store 调用点）：
/// - 查询: POST `/api/agora/live/getLiveAnnouncement`  body: `{ searchValue: roomId }`
/// - 保存: POST `/api/agora/live/editLiveAnnouncement`  body: `{ content }`  （content='' = 清空）
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

struct AnnouncementServiceReal: AnnouncementServiceProtocol {
    func fetch(roomId: String) async throws -> LiveAnnouncement {
        let data = try await APIClient.shared.post(
            "/api/agora/live/getLiveAnnouncement",
            body: ["searchValue": roomId]
        )
        // H5 仅在 result 为字符串时回显；空或其它结构一律作为空公告。
        let content = (try? JSONDecoder().decode(String.self, from: data)) ?? ""
        return LiveAnnouncement(content: content)
    }

    func save(content: String, roomId: String) async throws {
        do {
            // H5 saveLiveAnnouncement({ content }) 不携带 roomId，服务端由当前主播直播态定位房间。
            _ = try await APIClient.shared.post(
                "/api/agora/live/editLiveAnnouncement",
                body: ["content": content],
                suppressCodes: ["1070"]
            )
        } catch let error as APIError where error.code == "1070" {
            let hits = error.message
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            throw AnnouncementError.sensitiveWords(hits: hits)
        } catch let error as APIError {
            throw AnnouncementError.generic(error.message)
        }
    }
}
