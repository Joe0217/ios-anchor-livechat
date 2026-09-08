import Foundation
import AgoraRtcKit
import os

private let logger = Logger(subsystem: "com.hilly.anchor", category: "NetworkQualityTracker")

/// 通用网络质量监控器（用于 Party 房和通话场景）。
///
/// **与直播 NetworkQualityMonitor 的区别**：
/// - **不强制下播/下麦/挂断**：仅上报埋点，不触发业务中断
/// - **更轻量**：无降级 fps 等复杂逻辑
/// - **通用场景**：通过 `scene` 参数区分
///   - "party"：Party 房
///   - "direct_call"：直接拨打通话
///   - "match_call"：匹配通话
///   - "live_call"：直播间私 call
///   - "party_call"：Party 房私 call
///   - "bot_call"：机器人通话
///
/// **监控维度**：
/// - **RTC 质量**：声网 SDK 的 networkQuality 回调（端到端质量）
/// - **系统网络**：iOS 系统的网络连接状态（WiFi/4G、信号强度等）
///
/// **上报策略**：
/// - 连续坏质量每 10 次上报一次埋点（避免过于频繁）
/// - 从坏质量恢复到好质量时上报一次恢复埋点
///
/// **阈值**：
/// - 坏质量定义：quality >= 5（vBad / Down）
/// - 好质量定义：quality <= 4
/// - 恢复阈值：连续 ≥5 次好质量
@MainActor
final class NetworkQualityTracker {
    private let scene: String  // "party" / "direct_call" / "match_call" / "live_call" / "party_call" / "bot_call"
    private let roomIdProvider: (() -> String?)?  // Party 房提供 roomId

    /// 系统级网络监控器
    private let systemMonitor = SystemNetworkMonitor()

    private var consecutiveBadCount = 0
    private var consecutiveGoodCount = 0
    private var totalReports = 0
    private var lastTxQuality = 0
    private var lastRxQuality = 0

    /// 上行/下行独立计数
    private var consecutiveTxBadCount = 0
    private var consecutiveRxBadCount = 0

    /// 上报埋点的间隔（每 N 次坏质量上报一次）
    private let reportInterval = 10
    /// 恢复阈值（连续 N 次好质量认为网络恢复）
    private let recoverThreshold = 5

    /// 初始化网络质量监控器
    /// - Parameters:
    ///   - scene: 场景标识（"party" / "direct_call" / "match_call" / "live_call" / "party_call" / "bot_call"）
    ///   - roomIdProvider: Party 房场景需提供 roomId（通话场景传 nil）
    init(scene: String, roomIdProvider: (() -> String?)? = nil) {
        self.scene = scene
        self.roomIdProvider = roomIdProvider
    }

    /// 上报网络质量（由 AgoraRtcEngineDelegate.networkQuality 回调触发）
    /// - Parameters:
    ///   - tx: 发送质量
    ///   - rx: 接收质量
    func report(tx: AgoraNetworkQuality, rx: AgoraNetworkQuality) {
        totalReports += 1
        lastTxQuality = Int(tx.rawValue)
        lastRxQuality = Int(rx.rawValue)
        let worst = max(lastTxQuality, lastRxQuality)

        if worst >= 5 {
            // 坏质量（5=vBad, 6=Down）
            consecutiveGoodCount = 0
            consecutiveBadCount += 1

            logger.debug("[\(self.scene)] network bad++ count=\(self.consecutiveBadCount) tx=\(self.lastTxQuality) rx=\(self.lastRxQuality) system=\(self.systemMonitor.getNetworkSummary())")

            // 每 10 次坏质量上报一次埋点
            if consecutiveBadCount % reportInterval == 0 {
                trackNetworkBad()
            }
        } else {
            // 好质量
            if consecutiveBadCount > 0 {
                consecutiveGoodCount += 1
                logger.debug("[\(self.scene)] network good++ count=\(self.consecutiveGoodCount)")

                // 连续 5 次好质量认为网络恢复
                if consecutiveGoodCount >= recoverThreshold {
                    trackNetworkRecover()
                    consecutiveBadCount = 0
                    consecutiveGoodCount = 0
                }
            }
        }
    }

    /// 重置计数（用于场景切换或停止监控）
    func reset() {
        consecutiveBadCount = 0
        consecutiveGoodCount = 0
        totalReports = 0
    }

    // MARK: - 埋点上报

    private func trackNetworkBad() {
        var properties: [String: Any] = [
            "scene": scene,
            "consecutive_bad_count": consecutiveBadCount,
            "tx_quality": lastTxQuality,
            "rx_quality": lastRxQuality,
            "total_reports": totalReports,
            "action": "warn"
        ]

        // 补充系统网络信息
        properties.merge(systemMonitor.getNetworkProperties()) { (_, new) in new }

        // Party 房补充 roomId
        if let roomId = roomIdProvider?(), !roomId.isEmpty {
            properties["roomid"] = roomId
            properties["room_id"] = roomId
        }

        AnalyticsTracker.trackBehavior("网络质量差", properties: properties, immediately: false)
        logger.info("[\(self.scene)] tracked network bad: count=\(self.consecutiveBadCount) system=\(self.systemMonitor.getNetworkSummary())")
    }

    private func trackNetworkRecover() {
        var properties: [String: Any] = [
            "scene": scene,
            "previous_bad_count": consecutiveBadCount,
            "total_reports": totalReports
        ]

        // 补充系统网络信息
        properties.merge(systemMonitor.getNetworkProperties()) { (_, new) in new }

        // Party 房补充 roomId
        if let roomId = roomIdProvider?(), !roomId.isEmpty {
            properties["roomid"] = roomId
            properties["room_id"] = roomId
        }

        AnalyticsTracker.trackBehavior("网络恢复", properties: properties, immediately: false)
        logger.info("[\(self.scene)] tracked network recover: previous_bad=\(self.consecutiveBadCount) system=\(self.systemMonitor.getNetworkSummary())")
    }
}
