import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "Party.Balance")

/// 派对房余额服务 protocol（H-5 spec §2.3）—— 单独文件承载 protocol + `PartyBalanceSource` wrapper 供 HilyTests 白名单可见。
///
/// **Default 实作**（`DefaultPartyBalanceService`）在 `PartyBalanceService.swift`（含 PartyAPIClient 依赖，不入 test 白名单）。
///
/// **API 未真机验证**（对齐 `agent-recon-field-names-unverified` rule）：
/// - 默认候选路径 `/sapi/weidou/v1/client/gem/getBalance`（H5 `apiGetUserDiamondsAndGemsBalance`，安卓派对房强候选）
/// - Response 字段名多别名 fallback 见 default 实作
protocol PartyBalanceService: Sendable {
    func fetchBalance() async throws -> Int64
}

/// `GiftPanelBalanceSource` 派对房实作（Bridge：PartyBalanceService → GiftPanelBalanceSource protocol）。
///
/// `currentBalance()` 用 try? 吞异常（返 nil = 未拉/失败）—— 对齐 spec R6：余额失败显 `--` 不阻塞 send。
struct PartyBalanceSource: GiftPanelBalanceSource {
    private let service: PartyBalanceService

    init(service: PartyBalanceService) {
        self.service = service
    }

    func currentBalance() async -> Int64? {
        do {
            return try await service.fetchBalance()
        } catch {
            logger.error("[PartyBalance] fetch failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}
