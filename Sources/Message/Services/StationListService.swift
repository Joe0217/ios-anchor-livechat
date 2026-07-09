import Foundation
import os

/// 站内信最新一条拉取服务（H-1c 系统消息 3 入口 - Station）。
///
/// **对齐 H5 `list.vue:154-176`**：进入 Message tab 时拉一次 `apiGetStationList` `pageSize=1`
/// 拿最新一条；本地按 UserDefaults 记录已读的 stationInfo.id，新 id 不同即 unread=1。
///
/// **依赖注入**：`fetcher` 闭包让 HilyTests 可注入 mock；`.shared` 用真 APIClient。
@MainActor
final class StationListService: StationListProviderProtocol {

    typealias Fetcher = () async throws -> [StationMail]

    let fetcher: Fetcher

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "StationListService")

    /// 已读 stationInfo.id 存储 key（UserDefaults）
    private static let readIdUserDefaultsKey = "hily.station.lastReadId"

    init(fetcher: @escaping Fetcher) {
        self.fetcher = fetcher
    }

    /// 真实生产实例：调 `/api/sysmail/loadList`（top-level array 契约）。
    static let shared: StationListService = StationListService(fetcher: {
        let sharedLogger = Logger(subsystem: "com.anchor.livechat", category: "StationListService")
        let body: [String: Any] = ["pageSize": 1, "currentPage": 1]
        let data = try await APIClient.shared.post("/api/sysmail/loadList", body: body)
        sharedLogger.info("🟣 [Station] raw response bytes=\(data.count, privacy: .public)")
        let list = try JSONDecoder().decode([StationMail].self, from: data)
        sharedLogger.info("🟣 [Station] decoded mails count=\(list.count, privacy: .public)")
        return list
    })

    /// 拉最新一条 station mail；失败 / 空返 nil（不抛，让上层 Flame 顶部 row 隐藏或空态处理）。
    func fetchLatest() async -> StationMail? {
        do {
            let list = try await fetcher()
            return list.first
        } catch {
            logger.error("[Station] fetchLatest failed \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// Batch 3.8：分页拉全量列表（Station 详情列表页用）。对齐 H5 `stationMsg.vue:10-26`。
    func fetchList(page: Int, pageSize: Int = 20) async throws -> [StationMail] {
        let body: [String: Any] = ["pageSize": pageSize, "currentPage": page]
        let data = try await APIClient.shared.post("/api/sysmail/loadList", body: body)
        return try JSONDecoder().decode([StationMail].self, from: data)
    }

    /// 该 stationMail.id 是否未读（新到达且用户未点过）。
    func isUnread(_ mail: StationMail) -> Bool {
        let lastRead = UserDefaults.standard.string(forKey: Self.readIdUserDefaultsKey) ?? ""
        return mail.id != lastRead
    }

    /// 标记已读（用户点击 Station 入口时调）。
    func markRead(_ mail: StationMail) {
        UserDefaults.standard.set(mail.id, forKey: Self.readIdUserDefaultsKey)
    }
}

/// 依赖注入协议（Store / HilyTests 用）
@MainActor
protocol StationListProviderProtocol: AnyObject {
    func fetchLatest() async -> StationMail?
    func isUnread(_ mail: StationMail) -> Bool
    func markRead(_ mail: StationMail)
}
