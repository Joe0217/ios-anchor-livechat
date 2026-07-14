import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "Party.Balance")

/// `PartyBalanceService` 默认实作 —— 走 `/sapi/weidou/v1/client/gem/getBalance`（H-5 spec §0.2 Q3 候选）。
///
/// Protocol + `PartyBalanceSource` wrapper 声明在 [PartyBalanceServiceProtocol.swift](PartyBalanceServiceProtocol.swift)。
///
/// **API 未真机验证**（对齐 `agent-recon-field-names-unverified` rule）：
/// - Response 字段名多别名 fallback：`diamonds` / `diamondNum` / `balance` / `gems`
/// - 若真机 preflight 发现走别的接口 → 只改本文件 `fetchBalance` 内部
struct DefaultPartyBalanceService: PartyBalanceService {
    init() {}

    func fetchBalance() async throws -> Int64 {
        let data = try await PartyAPIClient.shared.post(
            "/sapi/weidou/v1/client/gem/getBalance",
            body: [:]
        )
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("[PartyBalance] response not object")
            throw APIError(code: "-1", message: "balance response unparseable")
        }
        // 多字段名 fallback（对齐 agent-recon-field-names-unverified rule）
        // 优先级：diamonds → diamondNum → balance → gems
        for key in ["diamonds", "diamondNum", "balance", "gems"] {
            if let n = obj[key] as? NSNumber {
                let cType = String(cString: n.objCType)
                if cType != "c" && cType != "B" {  // 排除 Bool 桥接
                    return n.int64Value
                }
            }
            if let s = obj[key] as? String, let v = Int64(s) {
                return v
            }
        }
        logger.error("[PartyBalance] no known balance field in response; keys=\(obj.keys.joined(separator: ","), privacy: .public)")
        throw APIError(code: "-1", message: "balance field not found")
    }
}

/// PartyBalanceSource 默认构造便利（factory 层 `.partySend(balance: nil)` 兜底用）
extension PartyBalanceSource {
    init() {
        self.init(service: DefaultPartyBalanceService())
    }
}
