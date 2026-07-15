import Foundation

/// 面板底部余额显示数据源（spec §2.2 `BalancePolicy.visible`）。
///
/// **本轮 stub**：H+ 派对房送礼里程碑接入真 API（`apiGetBalance` 或聊天室广播推）。
/// 面板 UI 在 config.balance = `.visible(source:)` 时才调用；返 nil 时 UI 显示 `--`。
protocol GiftPanelBalanceSource {
    /// 当前余额（钻石数）；nil = 未知/未接入
    func currentBalance() async -> Int64?

    /// 同步查内部缓存的余额（Store fast-path 用；无网络无 async）
    /// 用途：Store.load 命中 syncCachedGroups fast-path 时，同步 seed balanceValue —— 避免
    /// 面板 phase=.loaded 后 balanceValue nil 短暂让 canTriggerAction 的 balance gate 失效。
    /// 默认返 nil（未实现缓存的 source 走原 async currentBalance path）
    func syncCachedBalance() -> Int64?
}

extension GiftPanelBalanceSource {
    /// 默认实现：无同步缓存 → 返 nil（caller fast-path 无 seed，但 refreshBalance 会异步补齐）
    func syncCachedBalance() -> Int64? { nil }
}

/// stub 实现：永远返 nil（本轮占位）；H+ 用真 service 替换。
struct StubBalanceSource: GiftPanelBalanceSource {
    init() {}
    func currentBalance() async -> Int64? { nil }
}
