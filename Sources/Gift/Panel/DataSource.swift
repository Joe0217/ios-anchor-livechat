import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftPanel.DataSource")

/// 礼物面板 tab（对齐 v3 `getGiftList` grouping — spec §1.5 名映射表）。
///
/// Backpack **不是 tab**（是独立子面板入口，走 config.backpack），本轮不列。
///
/// **H5 对齐**（`views/liveSetting/components/newGiftsPopup.vue:22-35`）：
/// 直播中主播端礼物弹窗有 3 tab —— Popular / Exclusive / Lucky Gift；
/// 开播设置 / 心愿单等场景仍是 [.popular] 单 tab。
public enum GiftPanelTab: String, Hashable, CaseIterable {
    case popular
    case exclusiveGift
    case luckyGift

    /// 显示名（对齐设计稿 `送礼弹窗-背包礼物.png` + H5 newGiftsPopup 分类命名）
    var displayName: String {
        switch self {
        case .popular: return "Popular"
        case .exclusiveGift: return "Exclusive"
        case .luckyGift: return "Lucky Gift"
        }
    }

    /// 后端 v3 group name 映射（spec §1.5，硬编码；未知 group drop + log）
    static func fromGroupName(_ raw: String) -> GiftPanelTab? {
        switch raw.lowercased() {
        case "popular":
            return .popular
        case "exclusive", "exclusive gift", "luxury":
            return .exclusiveGift
        case "lucky", "lucky gift", "luckygift":
            return .luckyGift
        default:
            return nil
        }
    }
}

/// 单个 tab 的礼物列表（DataSource 返回单元）。
public struct GiftPanelGroup: Equatable {
    public let tab: GiftPanelTab
    public let gifts: [GiftListData]

    public init(tab: GiftPanelTab, gifts: [GiftListData]) {
        self.tab = tab
        self.gifts = gifts
    }
}

/// 礼物面板数据源（spec §1.5）：一次 load 拉全部 tabs 的分组数据。
///
/// 实现方决定接口 + 分组策略；本文件提供 2 个默认实现：
/// - `DefaultGiftDataSource`：v3 `/api/gift/v3/getGiftList` grouped 响应
/// - `IMGiftDataSource`：IM 场景 `GiftMessageServiceProtocol.fetchGifts()` adapter
public protocol GiftPanelDataSource: AnyObject {
    /// 拉取所有 tab 的礼物列表；返回 [GiftPanelGroup]，顺序由实现方决定（View 层按 config.tabs 显示顺序取用）
    func loadGifts() async throws -> [GiftPanelGroup]
}

// MARK: - Default: v3 grouped

#if !HILY_TESTS
/// 默认数据源：走 `GiftService.getGroupedGiftList(scene:)` v3 grouped API。
///
/// group name 映射由 `GiftPanelTab.fromGroupName` 完成；未知 group 丢弃并记 log。
/// 未来场景（派对房 scene=`PARTY_ROOM`）返回是否含 Exclusive 分组，后端未验证——本轮先按已知 `Popular` / `Luxury` / `Exclusive` 处理。
///
/// `#if !HILY_TESTS` 屏蔽：依赖 GiftService/APIClient 不入 test target；tests 用 FakeGiftPanelDataSource 注入。
public final class DefaultGiftDataSource: GiftPanelDataSource {
    private let scene: GiftService.Scene

    /// 参数 GiftService.Scene 是 internal，init 显式 internal 避开 public 继承报错
    init(scene: GiftService.Scene) {
        self.scene = scene
    }

    public func loadGifts() async throws -> [GiftPanelGroup] {
        let grouped = try await GiftService.getGroupedGiftList(scene: scene)
        var result: [GiftPanelTab: [GiftListData]] = [:]
        var seen = Set<Int64>()
        for (rawName, gifts) in grouped {
            guard let tab = GiftPanelTab.fromGroupName(rawName) else {
                logger.info("unknown group name dropped: \(rawName, privacy: .public) count=\(gifts.count)")
                continue
            }
            // 跨 group 去重（同 id 出现在多组时保留首次）
            var acc = result[tab] ?? []
            for g in gifts where !seen.contains(g.id) {
                seen.insert(g.id)
                acc.append(g)
            }
            result[tab] = acc
        }
        // 稳定顺序：Popular 在前
        return GiftPanelTab.allCases.compactMap { tab in
            result[tab].map { GiftPanelGroup(tab: tab, gifts: $0) }
        }
    }
}
#endif

// MARK: - IM adapter

#if !HILY_TESTS
/// IM 场景 adapter：把 `GiftMessageServiceProtocol.fetchGifts()` (`[GiftMessageItem]`) 转成 panel 需要的 `[GiftListData]`。
///
/// spec §1.2 IM 场景保留 tap-cell-instant-dismiss 语义；用户 onSelect 需要拿回 `GiftMessageItem`，
/// 本 adapter 内部维护 id→GiftMessageItem 映射（load 时缓存），Config.imBind factory 通过 `itemById(_:)` 反查。
public final class IMGiftDataSource: GiftPanelDataSource {
    private let service: GiftMessageServiceProtocol
    /// gift.id (Int64) → GiftMessageItem 反查表（load 后填充）
    private var idToItem: [Int64: GiftMessageItem] = [:]

    /// 参数 GiftMessageServiceProtocol 是 internal，init 显式 internal 避开 public 继承报错
    init(service: GiftMessageServiceProtocol) {
        self.service = service
    }

    public func loadGifts() async throws -> [GiftPanelGroup] {
        let items = try await service.fetchGifts()
        var gifts: [GiftListData] = []
        var mapping: [Int64: GiftMessageItem] = [:]
        for item in items {
            // GiftMessageItem.id 是 String；Int64 转换失败则 hash 兜底（保证 identity 稳定）
            let numericId = Int64(item.id) ?? Int64(item.id.hashValue)
            let gift = GiftListData(
                id: numericId,
                name: item.name,
                giftPrice: Int64(item.price),
                giftSmallImg: item.iconUrl ?? "",
                giftImg: item.iconUrl ?? "",
                vaild: nil
            )
            gifts.append(gift)
            mapping[numericId] = item
        }
        idToItem = mapping
        // IM 场景只有 Popular 单 tab
        return [GiftPanelGroup(tab: .popular, gifts: gifts)]
    }

    /// factory 在 onSelect 回调内查表反算 GiftMessageItem；返回值 internal，方法显式 internal 避开 public 继承报错
    func itemById(_ id: Int64) -> GiftMessageItem? {
        idToItem[id]
    }
}
#endif
