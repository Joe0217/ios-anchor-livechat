import Foundation

/// 用户段位详情（对应 H5 `apiUserLevelInfo`，蓝本 09 §277）。
///
/// 字段全 Optional：H5 蓝本未列出参清单，先按设计稿要素（当前段位 / 当前分 / 下一档分 / 进度）占位。
/// 真机响应字段名/类型有偏差时迭代调整。
struct LevelInfo: Codable {
    let level: Int?
    let levelName: String?     // "SS" / "S" / ...
    let score: Int?            // 当前分数
    let nextScore: Int?        // 升下一级所需分
    let scoreToNextLevel: Int? // 还差多少（备用，若后端直发该字段）
    /// 段位光谱进度 0..1（若后端直发；否则由 score / nextScore 估算）
    let progress: Double?
    /// 段位变化说明（按 H5 通用字段：升降级提示）
    let tierChangeHint: String?
}
