import Foundation

/// PartyBattle 服务层错误枚举
///
/// F-1a 首版按 spec §12 收敛需求占位；A5 startNow 错误码 / cooldownActive 服务端 code
/// 在 F-1a milestone 真机 log 抓取时按实际 response 补映射。
enum PartyBattleServiceError: Error, LocalizedError, Equatable {
    case invalidResponse
    case notAuthorized
    case notInPk
    case pkAlreadyRunning
    case cooldownActive(leftSec: Int)
    case switchTeamRejected
    case unknownServer(code: String, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "PartyBattle: invalid response"
        case .notAuthorized: return "PartyBattle: not authorized"
        case .notInPk: return "PartyBattle: not in a PK"
        case .pkAlreadyRunning: return "PartyBattle: PK already running"
        case .cooldownActive(let s): return "PartyBattle: cooldown \(s)s"
        case .switchTeamRejected: return "PartyBattle: switch team rejected"
        case .unknownServer(let c, let m): return "PartyBattle: [\(c)] \(m ?? "")"
        }
    }
}
