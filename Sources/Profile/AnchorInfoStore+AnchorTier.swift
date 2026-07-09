import Foundation

/// 主播段位派生属性 (trial #1, A-spec §6A.5)。
///
/// trial step 3 真集成反悔：后端 `AnchorInfo` 的 `levelName: String?` 可能 nil
/// (ProfileModels.swift:26 注释明示"若后端只发数字 level，此字段 nil")。
/// **双字段兼容**：优先 `levelName` 白名单；缺则 fallback 数字 `level` 映射。
///
/// 白名单判定的纯函数在 `AnchorTierClassifier`，便于单测独立。
extension AnchorInfoStore {
    /// 是否 S 级 (含 SS) 主播。
    /// 优先 `levelName` 白名单；缺则数字 `level` 映射（trial step 3 反悔后加固）。
    var isSLevelAnchor: Bool {
        // 优先 levelName (字符串字面量，最权威)
        if let n = (info?.levelName ?? mine?.levelName), !n.isEmpty {
            return AnchorTierClassifier.isSLevel(levelName: n)
        }
        // 兜底 level 数字 (后端只发数字时走此分支)
        return AnchorTierClassifier.isSLevel(level: info?.level ?? mine?.level)
    }

    /// 段位是否已加载完成。
    /// `levelName` 非空 或 `level` 非 nil 任一就算 loaded — 兼容后端字段二选一发的情况。
    var hasLoadedTier: Bool {
        if let n = info?.levelName, !n.isEmpty { return true }
        if let n = mine?.levelName, !n.isEmpty { return true }
        if (info?.level ?? mine?.level) != nil { return true }
        return false
    }
}
