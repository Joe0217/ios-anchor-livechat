import Foundation

/// 主播段位判定的纯函数 (A-spec §6A.5)。
///
/// H5 `user.js:59` 用 `mineInfo?.userLevel?.includes('S')` 判 S 级 — 含 "SS" 也算，
/// 但若后端将来加 "STAR"/"SPECIAL"/"SS+" 段位会被误判。
/// iOS **白名单收紧**：精确匹配 `S` / `SS`，不用 `.contains("S")`。
///
/// trial step 3 真集成反悔：后端可能只发 `level: Int` 不发 `levelName`
/// (ProfileModels.swift:26 注释)，所以增加 `isSLevel(level:)` overload，
/// 复用 `AnchorInfoStore.tierName(forLevel:)` 的 `["D","C","NEW","B","A","S","SS"]` 映射:
/// index 5 = S, 6 = SS。
///
/// 提取为纯函数便于单测独立 (无 `AnchorInfoStore` 依赖)。
enum AnchorTierClassifier {
    /// 是否 S 级 (含 SS) 主播 — 通过 `levelName` 字符串白名单判定。
    /// 后端如新增段位需要更新本白名单。
    static func isSLevel(levelName: String?) -> Bool {
        guard let n = levelName, !n.isEmpty else { return false }
        return n == "S" || n == "SS"
    }

    /// 是否 S 级 — 通过数字 `level` 判定，复用 `AnchorInfoStore.tierName(forLevel:)` 映射。
    /// index 5 = "S"，6 = "SS"；越界返 false。
    static func isSLevel(level: Int?) -> Bool {
        guard let lvl = level else { return false }
        return lvl == 5 || lvl == 6
    }
}
