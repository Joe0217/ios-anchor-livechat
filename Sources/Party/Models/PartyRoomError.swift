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
        case .enterFailed(let msg): return "进房失败: \(msg)"
        case .exitFailed(let msg): return "退房失败: \(msg)"
        case .seatOccupied: return "麦位已被占用"
        case .seatEmpty: return "麦位为空"
        case .banned: return "已被封禁"
        case .levelInsufficient: return "等级不足"
        case .networkLost: return "网络连接已断开"
        case .kicked: return "已被房主踢出"
        case .passwordWrong: return "进房密码错误"
        case .mediaSwitchFailed: return "麦克风/摄像头切换失败"
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
        case "ROOM_PASSWORD_WRONG", "PASSWORD_ERROR":
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
