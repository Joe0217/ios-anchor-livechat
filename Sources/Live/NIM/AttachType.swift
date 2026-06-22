import Foundation

/// 云信 IM 自定义消息 attachType 业务枚举（B 里程碑 spec §5.2）。
///
/// 双形态解析：H5 既用字符串 'SEND_GIFT' 也用数字 1/4/15/18；安卓统一为数字。
/// `init(raw:)` 先尝试 Int，再尝试 String，未匹配归入 `.unknown` 仅 logger 留痕不影响业务。
///
/// 重要：50/61/63 经 H5+安卓双端二次校验**不是礼物**（详见 B-spec-H5安卓代码二次校验 §1.1）：
/// - 50：双端均无 file:line 证据，B 阶段不识别
/// - 61：合规警告（仅 toast 不下播）
/// - 62：封禁下播
/// - 63：进折扣池 BoostingExposure（非礼物）
enum AttachType: Equatable {
    // 合规/强制（B 里程碑必须识别）
    case forceEndLive       // 44 — 强制下播
    case complianceWarning  // 61 — 合规警告 toast
    case banned             // 62 — 封禁下播
    case boostingExposure   // 63 — 进折扣池

    // 礼物（B 阶段解析占位，H 接动画队列）
    case sendGift           // 'SEND_GIFT' 字符串 / 数字 1
    case liveCallGift       // 4 — 通话/直播礼物
    case backpackGift       // 15 — 背包礼物
    case privilegeGift      // 18 — 特权礼物

    case unknown(raw: String)

    var raw: String {
        switch self {
        case .forceEndLive:       return "44"
        case .complianceWarning:  return "61"
        case .banned:             return "62"
        case .boostingExposure:   return "63"
        case .sendGift:           return "SEND_GIFT"
        case .liveCallGift:       return "4"
        case .backpackGift:       return "15"
        case .privilegeGift:      return "18"
        case .unknown(let raw):   return raw
        }
    }

    init(raw: Any?) {
        // 先 Int，后 String，最后 unknown 兜底
        if let n = (raw as? NSNumber)?.intValue {
            switch n {
            case 1:  self = .sendGift
            case 4:  self = .liveCallGift
            case 15: self = .backpackGift
            case 18: self = .privilegeGift
            case 44: self = .forceEndLive
            case 61: self = .complianceWarning
            case 62: self = .banned
            case 63: self = .boostingExposure
            default: self = .unknown(raw: "\(n)")
            }
            return
        }
        if let s = raw as? String {
            switch s {
            case "SEND_GIFT": self = .sendGift
            default:          self = .unknown(raw: s)
            }
            return
        }
        self = .unknown(raw: "nil")
    }
}
