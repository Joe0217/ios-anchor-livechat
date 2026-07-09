import Foundation

/// 私密消息解锁状态（H-3 spec §2.2 / §1.1.6）。
///
/// **来源**：`checkPrivateInfo({userId, privateIds})` 服务端下发的 `lockStatus`（0/1）。
///
/// **主播端 UI 分支**（H-3 spec §2.2 / §F-4）：
/// - `.locked` (0) → 图片正常显示 + 左下角 `locked.png` icon（对齐 H5 `msgItem.vue:236`）
/// - `.unlocked` (1) → 图片正常显示 + 左下角 `unlocked.png` icon
/// - `.unknown` → **不显 icon**（避免 dead-state；rule async-state-fallback）
///
/// `.unknown` 出现场景：
/// - 进页首次 checkPrivateInfo 尚未返回
/// - checkPrivateInfo API 失败
/// - 新增私密消息批次节流窗口内未 merge
enum PrivateLockStatus: Equatable, Hashable {
    case locked      // 0
    case unlocked    // 1
    case unknown

    /// 从后端 `lockStatus: Int?` 派生。nil / 未知值 → `.unknown`。
    init(rawInt: Int?) {
        switch rawInt {
        case 0: self = .locked
        case 1: self = .unlocked
        default: self = .unknown
        }
    }
}
