import Foundation

/// 面板底部余额显示数据源（spec §2.2 `BalancePolicy.visible`）。
///
/// **本轮 stub**：H+ 派对房送礼里程碑接入真 API（`apiGetBalance` 或聊天室广播推）。
/// 面板 UI 在 config.balance = `.visible(source:)` 时才调用；返 nil 时 UI 显示 `--`。
protocol GiftPanelBalanceSource {
    /// 当前余额（钻石数）；nil = 未知/未接入
    func currentBalance() async -> Int64?
}

/// stub 实现：永远返 nil（本轮占位）；H+ 用真 service 替换。
struct StubBalanceSource: GiftPanelBalanceSource {
    init() {}
    func currentBalance() async -> Int64? { nil }
}
