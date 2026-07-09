import Foundation

/// 直播态"切后台超限强制下播"策略常量（B 里程碑增补 spec §3）。
///
/// 后续调整阈值只改本文件，不动 BackgroundMonitor 逻辑。
///
/// 触发路径：BackgroundMonitor 在 willEnterForeground 结算时判断，任一超阈值 →
/// LiveStore.forceEnd(.backgroundExceeded, subSource: "bg_...") → endType=4。
/// 单次超时也可能被 Task.sleep(120s) 直接 fire（best-effort，仅进程未冻结场景生效）。
///
/// 例外场景不计数不计时（详见 BackgroundMonitor.handleEnterBackground guard）：
/// - LiveStore.state != .living
/// - LiveStore.callState == 1（私 call 期）
/// - LiveStore.isWaitingReturnLive（returnLive 15s 期）
enum LiveBackgroundPolicy {
    // MARK: - 触发阈值（超过则强制下播 endType=4，sub 区分档位）

    /// 累计切后台次数上限（含）
    static let maxBackgroundCount: Int = 5

    /// 单次后台时长上限（秒）
    static let maxSingleBackgroundDuration: TimeInterval = 120

    /// 累计后台时长上限（秒）
    static let maxCumulativeBackgroundDuration: TimeInterval = 300

    // MARK: - 预警阈值（未达触发但接近，回前台时内嵌 toast）

    /// 次数预警阈值（含；达到时 toast，第 5 次即下播）
    static let warnBackgroundCount: Int = 4

    /// 累计时长预警阈值（秒；80%）
    static let warnCumulativeBackgroundDuration: TimeInterval = 240

    // MARK: - 本地通知（best-effort：单次超时前 20s 弹本地通知）

    /// 单次到点前 N 秒弹通知（弹通知时刻 = maxSingle - leadTime）
    static let backgroundNotificationLeadTime: TimeInterval = 20

    /// 本地通知固定 identifier（方便 removePending 幂等）
    static let notificationIdentifier: String = "live.background.warning"
}
