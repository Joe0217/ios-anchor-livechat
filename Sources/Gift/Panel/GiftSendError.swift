import Foundation

/// 送礼错误 sentinel（H-5 · spec §2.3 · red-team P0-2 派生）——`CommonGiftPanelStore` 用于分流 phase。
///
/// `PartyGiftSendService` 实作在抛 `PartyAPIError` / `APIError` 之前，转成此 sentinel：
/// - code `1019` / msg 含 `diamond.not.enough` → `.insufficientBalance`
/// - 其他 → `.generic(message:)`
///
/// **为什么需要独立 sentinel**：Store 侧原本 `catch let e as PartyAPIError` 依赖网络栈类型，
/// 但 HilyTests target 白名单里没有 `PartyAPIError`（在 PartyAPIClient.swift 带 CryptoUtil 依赖）。
/// 抽 sentinel 后 Store 只依赖 `GiftSendError`（无 SDK 依赖，可入白名单），保持单测独立编译。
enum GiftSendError: Error, Equatable {
    /// 余额不足（后端 code=1019 或已知 msg）
    case insufficientBalance
    /// 通用送礼失败（含 sendGift 网络错误 / 其他业务码 / 未知错误）
    case generic(message: String)
}
