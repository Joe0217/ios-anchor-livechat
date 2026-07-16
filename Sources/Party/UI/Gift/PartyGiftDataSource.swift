import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "Party.GiftDataSource")

/// 派对房礼物列表数据源（H-5 · GiftPanelDataSource + GiftPanelBalanceSource 双 protocol）。
///
/// **走 sapi 域 `PartyAPI.getPartyRoomGift`** —— 不走主接口 `/api/gift/v3/getGiftList`（后端不识别 PARTY_ROOM/PARTY_GIFT scene → parameter.error）。
///
/// **balance 一体化**（review #2）：response 里已经带 `userDiamond`，DataSource 内部缓存 → 同时实作
/// `GiftPanelBalanceSource.currentBalance()`。避免 `gem/getBalance` 额外 HTTP + 消除余额展示与 sendGift
/// 扣款域可能不匹配的风险（H5 gift.js:1359 就是这么做的）。
///
/// **v2/v1 双 fallback**（review #1）：response.tabs 优先 · 缺失 → 走 v1 giftInfoDtoList 兜底（后端灰度关闭时）。
///
/// **本轮 MVP 约束**：Config.partySend factory 只挂 `[.popular]` tab，`load()` 返回全部 tabs 但
/// Store 层按 `config.tabs` 过滤（`Store.gifts(for tab:)`），未开 tab 静默隐藏。
///
/// **线程安全**：`loadGifts()` 与 `currentBalance()` 都在 async 上下文，`_latestBalance` 用 NSLock 保护
/// 双 queue 竞态（DataSource 单例被 Store + BalancePolicy 双引用）。
final class PartyGiftDataSource: GiftPanelDataSource, GiftPanelBalanceSource {

    private let lock = NSLock()
    private var _latestBalance: Int64?

    init() {}

    /// 同步 fast path（Store.load 入口调）：命中 GiftCatalogCache 直接返 + sync balance；无网络
    /// 让面板打开时秒显礼物 grid，跳过 loading 转圈
    func syncCachedGroups() -> [GiftPanelGroup]? {
        guard let entry = GiftCatalogCache.shared.get(scene: .party) else { return nil }
        if let b = entry.userDiamond {
            lock.lock(); _latestBalance = b; lock.unlock()
        }
        logger.info("[PartyGift] sync cache hit groups=\(entry.groups.count, privacy: .public)")
        return entry.groups
    }

    func loadGifts() async throws -> [GiftPanelGroup] {
        // 缓存命中 fast path：TTL 5min 内直接返 + sync balance；跨面板反复打开秒开
        if let entry = GiftCatalogCache.shared.get(scene: .party) {
            if let b = entry.userDiamond {
                lock.lock(); _latestBalance = b; lock.unlock()
            }
            logger.info("[PartyGift] cache hit groups=\(entry.groups.count, privacy: .public)")
            return entry.groups
        }

        let response = try await PartyAPI.getPartyRoomGift(showType: 0, apiVersion: 2)

        // 缓存 balance（review #2 · 与 send response 里 userDiamond 同源，避免扣款/展示不一致）
        if let b = response.userDiamond {
            lock.lock(); _latestBalance = b; lock.unlock()
        }

        var groups: [GiftPanelGroup] = []

        // v2 优先（review #1 · 灰度开启时的主路径）
        if let tabs = response.tabs, !tabs.isEmpty {
            let sortedTabs = tabs.sorted { (a, b) -> Bool in
                (a.tabSort ?? 0) < (b.tabSort ?? 0)
            }
            for tab in sortedTabs {
                let rawName = tab.tabCode ?? tab.tabName ?? ""
                guard let mappedTab = GiftPanelTab.fromGroupName(rawName) else {
                    logger.info("[PartyGift] unknown v2 tab code=\(rawName, privacy: .public); dropping")
                    continue
                }
                groups.append(GiftPanelGroup(tab: mappedTab, gifts: tab.gifts ?? []))
            }
            logger.info("[PartyGift] v2 loaded groups=\(groups.count, privacy: .public) balance=\(response.userDiamond ?? -1, privacy: .public)")
            // review #3 · 空态守护：所有 tabCode 未识别时 groups=[]，不写 cache（避免 5min 内多次开面板都看空）
            //   触发场景：服务端上线新 tabCode 但 iOS `GiftPanelTab.fromGroupName` 未同步 → mappedTab 全 nil
            //   下次开面板 fast-path 不命中会重拉 API 再 try
            if !groups.isEmpty {
                GiftCatalogCache.shared.set(scene: .party, groups: groups, userDiamond: response.userDiamond)
            } else {
                logger.notice("[PartyGift] v2 all tabCode unmapped; skip cache write to allow retry")
            }
            return groups
        }

        // v1 fallback（review #1 · 灰度关闭 apiVersion=2 → 后端回退 giftInfoDtoList · party.js:1347）
        if let v1Tabs = response.giftInfoDtoList, !v1Tabs.isEmpty {
            for tab in v1Tabs {
                let rawName = tab.tabName ?? ""
                guard let mappedTab = GiftPanelTab.fromGroupName(rawName) else {
                    logger.info("[PartyGift] unknown v1 tabName=\(rawName, privacy: .public); dropping")
                    continue
                }
                groups.append(GiftPanelGroup(tab: mappedTab, gifts: tab.giftVoList ?? []))
            }
            logger.info("[PartyGift] v1 fallback loaded groups=\(groups.count, privacy: .public)")
            // review #3 · 同 v2 · 空态不缓存让下次可重拉
            if !groups.isEmpty {
                GiftCatalogCache.shared.set(scene: .party, groups: groups, userDiamond: response.userDiamond)
            } else {
                logger.notice("[PartyGift] v1 all tabName unmapped; skip cache write to allow retry")
            }
            return groups
        }

        logger.notice("[PartyGift] both v2 tabs and v1 giftInfoDtoList empty; returning empty groups")
        return []
    }

    /// GiftPanelBalanceSource · 直接返回 loadGifts() 缓存的 userDiamond
    /// - nil = 尚未 loadGifts 或 response 未携带 userDiamond → UI 显 `--`（对齐 spec R6）
    func currentBalance() async -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return _latestBalance
    }

    /// 同步版本（Store.load fast-path 用）：与 currentBalance 同源 `_latestBalance`，无 async 无阻塞。
    /// syncCachedGroups 命中 GiftCatalogCache 时已把 balance seed 到 `_latestBalance`；此处直接返。
    func syncCachedBalance() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return _latestBalance
    }

    /// 强制走网络重拉最新余额（用户 tap 余额胶囊触发）。
    /// **走 getPartyRoomGift** 拿 response.userDiamond + tabs（H-5 balance 一体化 · 无独立 gem/getBalance）；
    /// 副作用：**groups + userDiamond 都刷入 GiftCatalogCache**（服务端上线新礼物用户可立即看到 · 不需等 TTL 过期）
    /// 失败静默返 _latestBalance（保留原值 · PartyAPIClient 底层 GlobalErrorBannerNotify 已 post error banner）
    func refreshFromServer() async -> Int64? {
        do {
            let response = try await PartyAPI.getPartyRoomGift(showType: 0, apiVersion: 2)
            // review #3 · 顺手把最新 groups 写 cache（避免服务端新礼物需要等 5min TTL 过期）
            let freshGroups = Self.decodeGroupsFromResponse(response)
            lock.lock()
            if let b = response.userDiamond {
                _latestBalance = b
            }
            let syncedBalance = _latestBalance
            lock.unlock()
            if !freshGroups.isEmpty {
                GiftCatalogCache.shared.set(scene: .party, groups: freshGroups, userDiamond: response.userDiamond ?? syncedBalance)
            } else if let b = response.userDiamond {
                // groups 空但 balance 有 → 只更 balance 不写空 groups（对齐 review #3 空态守护）
                GiftCatalogCache.shared.updateBalance(scene: .party, userDiamond: b)
            }
            logger.info("[PartyGift] refreshFromServer done balance=\(response.userDiamond ?? -1, privacy: .public) groups=\(freshGroups.count, privacy: .public)")
            return response.userDiamond ?? syncedBalance
        } catch {
            logger.error("[PartyGift] refreshFromServer failed: \(String(describing: error), privacy: .private)")
            // review #1 #2 · 持锁读 _latestBalance（避免与 updateBalanceFromSend 并发 race · 保持类自设 NSLock 契约）
            lock.lock(); defer { lock.unlock() }
            return _latestBalance
        }
    }

    /// 从 PartyGiftV2Response 解析 groups（v2 优先 / v1 兜底）。抽出复用给 loadGifts 与 refreshFromServer。
    private static func decodeGroupsFromResponse(_ response: PartyGiftV2Response) -> [GiftPanelGroup] {
        var groups: [GiftPanelGroup] = []
        if let tabs = response.tabs, !tabs.isEmpty {
            let sortedTabs = tabs.sorted { ($0.tabSort ?? 0) < ($1.tabSort ?? 0) }
            for tab in sortedTabs {
                let rawName = tab.tabCode ?? tab.tabName ?? ""
                guard let mapped = GiftPanelTab.fromGroupName(rawName) else { continue }
                groups.append(GiftPanelGroup(tab: mapped, gifts: tab.gifts ?? []))
            }
            return groups
        }
        if let v1Tabs = response.giftInfoDtoList, !v1Tabs.isEmpty {
            for tab in v1Tabs {
                let rawName = tab.tabName ?? ""
                guard let mapped = GiftPanelTab.fromGroupName(rawName) else { continue }
                groups.append(GiftPanelGroup(tab: mapped, gifts: tab.giftVoList ?? []))
            }
        }
        return groups
    }

    /// sendGift 成功后 Store 侧从 response.userDiamond 更新余额；同步到 DataSource 缓存 + GiftCatalogCache
    /// 让下次 currentBalance() 返回最新值（若面板 reopen 不需要重拉 API）
    func updateBalanceFromSend(_ balance: Int64) {
        lock.lock(); _latestBalance = balance; lock.unlock()
        GiftCatalogCache.shared.updateBalance(scene: .party, userDiamond: balance)
    }
}
