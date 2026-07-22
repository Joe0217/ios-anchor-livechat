import Foundation

/// 派对房业务错误（spec §1.4.8 + §1.5 #6 房主默认 RoleType 待 implement 期对照）。
///
/// 上层 PartyStore 在调用 PartyAPI 失败时捕获 PartyAPIError，按 `businessCode` 映射到本枚举；
/// `seatOccupied / seatEmpty` 自动触发 `loadMikeList()` 全量重拉对账（spec §1.4.8）。
enum PartyRoomError: Error, LocalizedError {
    case enterFailed(underlying: String)
    case exitFailed(underlying: String)
    case seatOccupied            // ROOM_SEAT_IS_OCCUPIED → 自动重拉对账
    case seatEmpty               // ROOM_SEAT_EMPTY → 自动重拉对账
    case banned                  // 被封禁
    case levelInsufficient       // 等级不足
    case networkLost
    case kicked
    case passwordWrong           // 进房密码错
    case mediaSwitchFailed
    case underlying(PartyAPIError)

    var errorDescription: String? {
        switch self {
        case .enterFailed(let msg): return String(format: L10n.Party.errorEnterFailedFormat, msg)
        case .exitFailed(let msg): return String(format: L10n.Party.errorExitFailedFormat, msg)
        case .seatOccupied: return L10n.Party.errorSeatOccupied
        case .seatEmpty: return L10n.Party.errorSeatEmpty
        case .banned: return L10n.Party.errorBanned
        case .levelInsufficient: return L10n.Party.errorLevelInsufficient
        case .networkLost: return L10n.Party.errorNetworkLost
        case .kicked: return L10n.Party.errorKicked
        case .passwordWrong: return L10n.Party.errorPasswordWrong
        case .mediaSwitchFailed: return L10n.Party.errorMediaSwitchFailed
        case .underlying(let api): return api.errorDescription
        }
    }
}

/// 业务码（字符串）→ PartyRoomError 映射。
/// 真实码值待 implement 期与后端对齐；目前用占位 token，调用方按需扩展 case。
/// 接口参考文档 + `02-04 §5` 边界异常列表是已知码源。
enum PartyRoomErrorMapper {
    static func map(_ apiError: PartyAPIError) -> PartyRoomError {
        guard let code = apiError.businessCode else {
            return .underlying(apiError)
        }
        // 占位映射；M2/M3/M4 真机抓到真实码后逐条补全。
        // 后端码值可能是字符串常量（"ROOM_SEAT_IS_OCCUPIED"）或数字（"10001"）。
        switch code.uppercased() {
        case "ROOM_SEAT_IS_OCCUPIED":
            return .seatOccupied
        case "ROOM_SEAT_EMPTY":
            return .seatEmpty
        // H5 `apiGetPartyRoomEnter` 的密码错误业务码为 10006；不同环境仍可能返回语义字符串。
        case "10006", "ROOM_PASSWORD_WRONG", "PASSWORD_ERROR":
            return .passwordWrong
        case "USER_BANNED", "LIVING_BE_BANNED":
            return .banned
        case "LEVEL_INSUFFICIENT":
            return .levelInsufficient
        default:
            return .underlying(apiError)
        }
    }
}
