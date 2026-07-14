import Foundation

/// 派对房送礼服务 protocol（H-5 spec §2.3）—— 单独文件承载 protocol 供 HilyTests 白名单可见。
///
/// **Default 实作**（`DefaultPartyGiftSendService`）在 `PartyGiftSendService.swift`（含 PartyAPI 依赖，不入 test 白名单）。
///
/// 抽出 protocol 的动机：Store 层用 mock 单测 R4/R5（余额不足 / 网络失败分支），
/// Bridge 层构造 send closure 时锁 roomId → Store 内 `.send` case 只需 `(giftId, count, yxAccids)` 三参
protocol PartyGiftSendService: Sendable {
    /// 发送礼物。
    /// - Parameters:
    ///   - giftId: 礼物 id（`GiftListData.id`，Int64）
    ///   - num: 数量（1...99）
    ///   - yxAccidList: 接受者 yxAccid 列表
    /// - Returns: `PartySendGiftResult`（含新余额 `userDiamond` 字段，走多别名兜底）
    /// - Throws: `PartyAPIError` / 业务错误码（如 1019 余额不足）由 `CommonGiftPanelStore` 分流到 `.insufficientBalance` / `.sendFailed`
    func send(giftId: Int64, num: Int, yxAccidList: [String]) async throws -> PartySendGiftResult
}
