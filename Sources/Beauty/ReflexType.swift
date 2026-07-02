import Foundation

/// 反射映射（对齐 H5 beautyTools.reflexMap，K spec §4.1）：UI 滑块值 ↔ 相芯 SDK 原始值双向映射。
///
/// **必须 1:1 复刻**，不简化为通用数学公式——H5 三类映射对不同参数有不同斜率，混用会误映射。
enum ReflexType: Int, Sendable, CaseIterable {
    /// UI 0~100 ↔ SDK 0~1（大部分美肤/美型参数）
    case type1 = 1
    /// UI -50~50 ↔ SDK 0~1（下巴/额头/嘴型等中性形变类，UI=0 → raw=0.5 是中性起点非"无效果"）
    case type2 = 2
    /// UI 0~100 ↔ SDK 0~6（磨皮专用）
    case type3 = 3

    /// UI → SDK 原始值
    func toRaw(_ uiValue: Double) -> Double {
        switch self {
        case .type1: return uiValue / 100.0
        case .type2: return (uiValue + 50.0) / 100.0
        case .type3: return uiValue * 6.0 / 100.0
        }
    }

    /// SDK 原始值 → UI
    func toUI(_ rawValue: Double) -> Double {
        switch self {
        case .type1: return 100.0 * rawValue
        case .type2: return 100.0 * rawValue - 50.0
        case .type3: return 100.0 * rawValue / 6.0
        }
    }
}
