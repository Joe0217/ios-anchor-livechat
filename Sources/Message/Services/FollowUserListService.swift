import Foundation
import os

/// 关注列表服务（Flame 通道 B 数据源，对齐 H5 `use/useFollowUserList.js`）。
///
/// **契约**：
/// - `POST /api/user/userFriend` body `{type: 3}` → `FollowListData[]`（每项含 `yxAccid: String`）
/// - **24h 缓存**（对齐 H5 `FOLLOW_LIST_CACHE_TIME = 24 * 60 * 60 * 1000`）
/// - **失败降级**：请求失败保留旧缓存（H5 `useFollowUserList.js:53-57` 同款）
/// - **注意**：H5 只传 `{type:3}` 不传 `currentPage/pageSize`，后端返全部；iOS 沿用同款调用
///
/// **对齐 H5 语义**：
/// - Flame 分类的用户 = ext 通道 A 命中 **OR** 本关注列表命中（[MessageSessionCategory.swift](../Models/MessageSessionCategory.swift)）
@MainActor
final class FollowUserListService: FollowUserListProviderProtocol {

    typealias Fetcher = () async throws -> Set<String>

    private let fetcher: Fetcher
    private let cacheDurationSec: TimeInterval

    private var cachedSet: Set<String> = []
    private var lastFetchedAt: Date?
    private var inflightTask: Task<Set<String>, Never>?

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "FollowUserListService")

    init(fetcher: @escaping Fetcher, cacheDurationSec: TimeInterval = 24 * 60 * 60) {
        self.fetcher = fetcher
        self.cacheDurationSec = cacheDurationSec
    }

    static let shared: FollowUserListService = FollowUserListService(fetcher: {
        // H5 `useFollowUserList.js:41`：只传 type，后端返全部
        let debugLogger = Logger(subsystem: "com.anchor.livechat", category: "FollowUserListService")
        let data = try await APIClient.shared.post("/api/user/userFriend", body: ["type": 3])
        // v4 诊断：dump raw response（用户报 followList=0 但 H5 里明显有关注）
        let raw = String(data: data, encoding: .utf8) ?? "<not-utf8>"
        debugLogger.info("[FollowList] raw response size=\(data.count, privacy: .public) preview=\(raw.prefix(500), privacy: .public)")
        do {
            let items = try JSONDecoder().decode([FollowUserItem].self, from: data)
            let ids = items.compactMap { item -> String? in
                guard !item.yxAccid.isEmpty else { return nil }
                return item.yxAccid
            }
            debugLogger.info("[FollowList] decoded array items=\(items.count, privacy: .public) validIds=\(ids.count, privacy: .public)")
            return Set(ids)
        } catch {
            debugLogger.error("[FollowList] decode as array failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    })

    // MARK: - Protocol

    func fetch() async -> Set<String> {
        // 命中缓存直接返（对齐 H5 `useFollowUserList.js:28-31`）
        if let ts = lastFetchedAt, Date().timeIntervalSince(ts) < cacheDurationSec {
            logger.debug("[FollowList] cache hit count=\(self.cachedSet.count, privacy: .public)")
            return cachedSet
        }

        // 已在拉取中 → 共享同一次结果（避免并发重复请求；对齐 H5 `isLoading` 保护）
        if let inflight = inflightTask {
            return await inflight.value
        }

        let task = Task<Set<String>, Never> { [self] in
            do {
                let set = try await fetcher()
                cachedSet = set
                lastFetchedAt = Date()
                logger.info("[FollowList] fetched count=\(set.count, privacy: .public)")
                return set
            } catch {
                // H5 `useFollowUserList.js:53-57`：失败保留旧缓存
                logger.notice("[FollowList] fetch failed, preserve cache count=\(self.cachedSet.count, privacy: .public) error=\(String(describing: error), privacy: .public)")
                return cachedSet
            }
        }
        inflightTask = task
        let result = await task.value
        inflightTask = nil
        return result
    }

    func clear() {
        cachedSet.removeAll()
        lastFetchedAt = nil
        inflightTask?.cancel()
        inflightTask = nil
        logger.info("[FollowList] cleared (logout/switch account)")
    }
}

/// H5 `FollowListData` 部分字段（本 service 只需 yxAccid；其他字段留待未来扩展）
private struct FollowUserItem: Decodable {
    let yxAccid: String

    enum CodingKeys: String, CodingKey { case yxAccid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // yxAccid 一般 String（对齐 [ios-decode-userid-compat.md](../../../.claude/rules/ios-decode-userid-compat.md)
        // 精神容错：若后端偶发 Int，转 String 兜底）
        if let s = try? c.decode(String.self, forKey: .yxAccid) {
            self.yxAccid = s
        } else if let i = try? c.decode(Int64.self, forKey: .yxAccid) {
            self.yxAccid = String(i)
        } else {
            self.yxAccid = ""
        }
    }
}
