import Foundation

/// H-3 视频通话 5s cooldown 判定（spec §2.8 步骤 3 / §4.11 / §F-55 / §R-43）。
///
/// **对齐 H5** `c-callButton.vue:60-89` `beautyStore.inited + liveStore.liveStartTime + sessionStore.getOnlineStatus`
/// 三重前置检查之一。**iOS 决策**（v3 §1.7.5）：不做 beauty init（H5 特有），保留 5s cooldown + onlineStatus。
///
/// **S9 spike 未确认起点**：先按 `LiveStore.liveStartTime`（直播/通话开始时间戳）—— 若真机验证发现应距 live/call **结束**
/// 时间 5s，改此 baseline 判定即可。
///
/// **纯静态函数**：test target 零依赖引用；`CallStore.handleVideoCallTap` 内调 `CallCooldownGuard.isCooledDown(...)`
/// 决定是否 toast "camera_busy" 拒绝发起。
enum CallCooldownGuard {

    /// 5s 硬编（H5 line 76 "Camera is busy. Please wait..."）
    static let cooldownSeconds: TimeInterval = 5

    /// - Parameters:
    ///   - liveStartTime: LiveStore.liveStartTime 记录的直播/通话开始时间（nil = 无历史 live → 通过）
    ///   - now: 当前时间（测试注入；生产传 Date()）
    /// - Returns: `true` 已过 cooldown / `false` 冷却中（view 层 toast + 阻断发起通话）
    static func isCooledDown(liveStartTime: Date?, now: Date = Date()) -> Bool {
        guard let start = liveStartTime else { return true }
        return now.timeIntervalSince(start) >= cooldownSeconds
    }
}
