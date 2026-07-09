import Foundation

/// 直播状态机（B 里程碑 spec §2.1）。
/// 七态：idle → preparing → starting → living → (forceEnding|ending) → ended
enum LiveState: Equatable {
    case idle
    case preparing
    case starting
    case living
    case forceEnding(reason: ForceEndReason)
    case ending
    case ended
}

/// 强制下播原因（B 里程碑 spec §2.1 + §11）。
/// 数字编码对齐安卓。H5 字符串码 '3'/'4'/'5'/'99' 语义演进为数字码 2/4/5/6/7；
/// endType '3'（后台管理员/系统强制）保留服务端语义，客户端切后台超限归入 endType=4。
enum ForceEndReason: Equatable {
    case banned             // endType=2  心跳 1992/1006 / NIM attachType=62
    case disconnected       // endType=4  心跳 >3 / NIM attachType=44 / 公屏重连 >3 / 声网 token 续期失败
    case backgroundExceeded // endType=4  切后台超限（次数/单次/累计三档，sub 区分；LiveBackgroundPolicy）
    case cameraFailure      // endType=5  CameraManager 持续失败 >20s
    case noPermission       // endType=6  心跳 2001
    case weakNetwork        // endType=7  NetworkQualityMonitor v5 分层（连续语义）：连续 ≥10 降级 15fps / 连续 ≥30 下播 / 连续 ≥5 恢复

    /// endType 数字码（对齐安卓；用户主动下播 endType=1 不入本枚举）
    /// backgroundExceeded 与 disconnected 共享 code=4：后台超限本质是"App 挂起 → 心跳停 → 断连"。
    /// 客户端保留独立 case 以便 priority 仲裁 / UI 文案 / 日志区分。
    var code: Int {
        switch self {
        case .banned:              return 2
        case .disconnected:        return 4
        case .backgroundExceeded:  return 4
        case .cameraFailure:       return 5
        case .noPermission:        return 6
        case .weakNetwork:         return 7
        }
    }

    /// 多源 forceEnd 优先级仲裁（spec §2.5b）。
    /// 数值越大优先级越高；同时到达时本地 state.reason 与 endType 升级为最高优先级。
    /// backgroundExceeded=2 与 weakNetwork 同级；并发丢失的档位信息通过 ThinkingData 埋点补足。
    var priority: Int {
        switch self {
        case .banned:              return 5
        case .noPermission:        return 4
        case .cameraFailure:       return 3
        case .weakNetwork:         return 2
        case .backgroundExceeded:  return 2
        case .disconnected:        return 1
        }
    }
}
