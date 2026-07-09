import Foundation

/// H5 `useUserLevelHooks` + `setLevelStyle` 对齐：
/// - tier = level / 10 向下取整
/// - 若 tier >= 10 → 截断为 10（最高档）
/// - 若 level < 0 → 0（防御）
enum LevelTierResolver {
    static func tier(for level: Int) -> Int {
        guard level >= 0 else { return 0 }
        let raw = level / 10
        return min(raw, 10)
    }
}
