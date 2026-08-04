import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftCatalogCache")

/// 礼物列表 + 余额 in-memory 缓存单例。
///
/// **目的**：礼物面板反复打开、跨场景（Party / Live / Call）显示礼物图标时，
/// 避免每次都走网络重拉相同的礼物架数据。TTL 5 分钟内命中直接返；
/// 手动 `invalidate(scene:)` 或 `clear()` 强制重拉。
///
/// **不做 stale-while-revalidate**：Store 层 `load()` 语义是一次性返数据；
/// 后台异步 refresh 需要 publisher 侵入面板 view 层。用 TTL + 手动 invalidate 简化模型。
///
/// **balance 一并缓存**：`PartyGiftDataSource.loadGifts()` 返 groups + response.userDiamond；
/// 送礼成功 store 层调 `updateBalance(scene:, userDiamond:)` 同步刷新，让下次开面板显示最新余额。
///
/// **session 挂点**：`SessionStore.logout()` 调 `clear()`（对齐 [session-scoped-store-refresh] rule）。
///
/// **线程安全**：NSLock 保护读写；所有方法 nonisolated，可从任意 Task 上下文调用（含 background queue）。
final class GiftCatalogCache: @unchecked Sendable {

    static let shared = GiftCatalogCache()

    /// 缓存场景（与 GiftService.Scene 解耦；本 cache 内部枚举）
    enum Scene: String, Hashable {
        case party
        case live
        case call
    }

    /// 缓存条目：groups + balance + 时戳
    struct Entry {
        let groups: [GiftPanelGroup]
        var userDiamond: Int64?
        let timestamp: Date

        /// TTL 5 分钟（礼物架服务端配置级低频变更；下拉刷新时可 invalidate 强制重拉）
        static let ttl: TimeInterval = 300

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > Self.ttl
        }
    }

    private let lock = NSLock()
    private var cache: [Scene: Entry] = [:]

    private init() {}

    /// 读缓存：命中且未过期返 entry；过期或不存在返 nil（caller 需自行拉网络重填）
    func get(scene: Scene) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache[scene] else { return nil }
        if entry.isExpired {
            logger.info("[GiftCache] hit but expired scene=\(scene.rawValue, privacy: .public); caller will refetch")
            return nil
        }
        logger.info("[GiftCache] hit scene=\(scene.rawValue, privacy: .public) groups=\(entry.groups.count, privacy: .public) userDiamond=\(entry.userDiamond ?? -1, privacy: .public)")
        return entry
    }

    /// 写缓存：loadGifts 成功拿到 API 结果时调
    func set(scene: Scene, groups: [GiftPanelGroup], userDiamond: Int64?) {
        lock.lock()
        cache[scene] = Entry(groups: groups, userDiamond: userDiamond, timestamp: Date())
        lock.unlock()
        logger.info("[GiftCache] set scene=\(scene.rawValue, privacy: .public) groups=\(groups.count, privacy: .public) userDiamond=\(userDiamond ?? -1, privacy: .public)")

        // 礼物架接口返回后立即后台预下载缩略图。UI 使用同一个 CDN 缩放 URL，
        // 因此第一次打开面板也可直接命中本地文件，不必逐格发起请求。
        let urls = groups
            .flatMap(\.gifts)
            .compactMap { gift -> URL? in
                let raw = gift.giftSmallImg.isEmpty ? gift.giftImg : gift.giftSmallImg
                guard let url = URL(string: raw) else { return nil }
                return url.cdnScaled(.gift, mode: .fit)
            }
        Task {
            await ImageCache.shared.prefetchPublicAssets(urls)
        }
    }

    /// 仅更新余额（送礼成功后 sync；不重置 timestamp，避免延长 groups TTL）
    func updateBalance(scene: Scene, userDiamond: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = cache[scene] else { return }
        entry.userDiamond = userDiamond
        cache[scene] = entry
        logger.info("[GiftCache] updateBalance scene=\(scene.rawValue, privacy: .public) userDiamond=\(userDiamond, privacy: .public)")
    }

    /// 精准 invalidate 单场景（下拉刷新用；未来面板加下拉手势时挂）
    func invalidate(scene: Scene) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: scene)
        logger.info("[GiftCache] invalidate scene=\(scene.rawValue, privacy: .public)")
    }

    /// 全清：logout / 切账号时调（避免 A 账号礼物架泄漏到 B）
    func clear() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        logger.info("[GiftCache] cleared all")
    }
}
