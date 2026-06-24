import Foundation
import AgoraRtcKit
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "NetworkMonitor")

/// 网络质量分层（G 里程碑 spec §3.5）：
/// - `normal` 正常态，无降级
/// - `weakWarning` 连续 ≥10 次坏质量（已 toast + 编码 30→15fps）
/// - `weakSevere` 连续 ≥30 次坏质量（默认行为下 forceEnd 直播；PK 期 PKStore 监听本值拦截 forceEnd 改为切 .pkLow）
enum NetworkQualityLevel: String {
    case normal
    case weakWarning
    case weakSevere
}

/// 调试用：网络监控实时计数（v5.1 显示到 LiveRoomView 调试面板）。
struct NetworkDebugInfo: Equatable {
    var status: String = "normal"           // normal / degraded / ended
    var bad: Int = 0                         // consecutiveBadCount
    var good: Int = 0                        // consecutiveGoodCount
    var lastTx: Int = 0                      // 最近一次 tx 质量 0-6
    var lastRx: Int = 0                      // 最近一次 rx 质量 0-6
    var lastWorst: Int = 0                   // max(tx, rx)
    var total: Int = 0                       // 累计 report 次数
    var agoraFps: Int = 30                   // AgoraManager 当前编码档位 fps
    var cameraFps: Int = 30                  // CameraManager.targetFPS 节流值
}

/// 网络调试信息独立 store：把高频（2s/次）@Published 写从 LiveStore 隔离出来，
/// 避免 LiveRoomView 因 networkDebugInfo 变化触发整树 body re-eval。
/// 仅 DebugNetworkPanel 订阅本类，LiveRoomView 不读 info 字段。
@MainActor
final class NetworkDebugStore: ObservableObject {
    @Published private(set) var info = NetworkDebugInfo()

    func update(_ block: (inout NetworkDebugInfo) -> Void) {
        var next = info
        block(&next)
        info = next
    }
}

/// 直播网络质量监控（B 里程碑 spec §4 v5 分层版）。
///
/// **三阈值分层**（声网 networkQuality 回调 2s 一次）：
/// - **连续** ≥10 次质量 5/6（≈20s）→ **降级**：toast + 编码 fps 30→15
/// - **连续** ≥30 次（≈60s，中间任一次质量 ≤4 即清零重计）→ **强制下播**：endType=7（v5 修订；原 spec ≥10 次对齐安卓被反悔）
/// - 降级期间**连续** ≥5 次质量 ≤4（≈10s）→ **恢复**：清 toast + 编码 fps 15→30
///
/// PK 期间（G 里程碑）使用 pause/resume，保留计数。
@MainActor
final class NetworkQualityMonitor: ObservableObject {
    private enum Status: String { case normal, degraded, ended }

    /// G 里程碑 spec §3.5：PKStore enter inPK 时订阅本值，监听到 .weakSevere 时拦截 forceEnd 改切 .pkLow；
    /// exit endingPK 时解除订阅。非 PK 期间保持 NQM 自身 forceEnd 行为不变。
    @Published private(set) var currentLevel: NetworkQualityLevel = .normal

    /// 触发降级（toast + fps 30→15）的连续坏质量次数
    private let warnThreshold = 10
    /// 触发强制下播的连续坏质量次数（v5：30 次约 60s）
    private let endThreshold = 30
    /// 降级期恢复正常（清 toast + fps 15→30）的连续好质量次数
    private let recoverThreshold = 5

    private weak var store: LiveStore?
    weak var agora: AgoraManager?
    /// v5.1 弱网降级时同时节流 CameraManager 推帧（避免相机 30fps 推但编码器只要 15fps 导致堆积卡顿）
    weak var camera: CameraManager?

    private(set) var isRunning: Bool = false
    private var status: Status = .normal
    private var consecutiveBadCount: Int = 0
    private var consecutiveGoodCount: Int = 0
    private var totalReports: Int = 0

    /// v5.3.2：回前台后冷却结束时间。声网 SDK 在后台仍发 networkQuality 回调（自己线程），
    /// 回调 dispatch 到 @MainActor 但 main 在后台挂起 → 大量 report 排队在 main runloop；
    /// 回前台瞬间一次性串行执行，consecutiveBadCount 飞速到 30 → 误触发 forceEnd(.weakNetwork)。
    /// 冷却 5s 内的 report 全部丢弃 + 计数已在 willEnterForeground 时清零。
    private var foregroundCooldownUntil: Date?
    /// app 是否在后台（didEnterBackground=true / willEnterForeground=false）
    private var isInBackground: Bool = false

    init(store: LiveStore) {
        self.store = store
        addAppLifecycleObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - app 生命周期（v5.3.2 修复后台→前台 report backlog 误触发 forceEnd）

    private func addAppLifecycleObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleWillEnterForeground),
                       name: UIApplication.willEnterForegroundNotification,
                       object: nil)
    }

    @objc private func handleDidEnterBackground() {
        isInBackground = true
        logger.info("app entered background; network monitor will ignore reports until 5s after foreground")
    }

    @objc private func handleWillEnterForeground() {
        isInBackground = false
        // 立即清零计数 + 设 5s 冷却，丢弃声网 SDK 在后台累积的 networkQuality backlog
        consecutiveBadCount = 0
        consecutiveGoodCount = 0
        foregroundCooldownUntil = Date().addingTimeInterval(5)
        logger.info("app will enter foreground; reset counts + 5s cooldown to drop SDK backlog")
    }

    /// LiveStore 进入 .living 时调用。
    /// v5 review 防御：start() 时强制把 agora 档位对齐 normal（防 agora 引擎 reuse 时档位残留 low）
    func start() {
        isRunning = true
        status = .normal
        currentLevel = .normal
        consecutiveBadCount = 0
        consecutiveGoodCount = 0
        agora?.applyEncoderQuality(.normal)
    }

    /// teardown 时调用。
    func stop() {
        isRunning = false
    }

    /// PK 期间（G 里程碑）使用：保留计数 + 暂停反馈
    func pause() { isRunning = false }
    func resume() { isRunning = true }

    func reset() {
        consecutiveBadCount = 0
        consecutiveGoodCount = 0
    }

    /// AgoraManager 收到 networkQuality 回调转发本入口。
    func report(tx: AgoraNetworkQuality, rx: AgoraNetworkQuality) {
        // v5.1：即使 ended/stop 也累计 totalReports + 写 debug，便于 UI 调试
        totalReports += 1
        let txRaw = Int(tx.rawValue)
        let rxRaw = Int(rx.rawValue)
        let worst = max(txRaw, rxRaw)

        // v5.3.2：后台 + 回前台 5s 冷却期内全部丢弃（防 backlog 误触发 forceEnd）
        if isInBackground {
            logger.debug("report ignored: in background")
            syncDebug(tx: txRaw, rx: rxRaw, worst: worst)
            return
        }
        if let cooldown = foregroundCooldownUntil, Date() < cooldown {
            logger.debug("report ignored: foreground cooldown")
            syncDebug(tx: txRaw, rx: rxRaw, worst: worst)
            return
        }

        guard isRunning, status != .ended else {
            syncDebug(tx: txRaw, rx: rxRaw, worst: worst)
            return
        }

        if worst >= 5 {
            // 5=vBad, 6=Down
            consecutiveGoodCount = 0
            consecutiveBadCount += 1
            logger.debug("bad++ count=\(self.consecutiveBadCount) status=\(self.status.rawValue)")
            if status == .normal, consecutiveBadCount >= warnThreshold {
                status = .degraded
                degrade()
            }
            if consecutiveBadCount >= endThreshold {
                status = .ended
                endLive()
            }
        } else {
            consecutiveBadCount = 0
            if status == .degraded {
                consecutiveGoodCount += 1
                logger.debug("good++ count=\(self.consecutiveGoodCount) status=\(self.status.rawValue)")
                if consecutiveGoodCount >= recoverThreshold {
                    consecutiveGoodCount = 0
                    status = .normal
                    recover()
                }
            }
        }
        syncDebug(tx: txRaw, rx: rxRaw, worst: worst)
    }

    /// v5.1 写 LiveStore.networkDebugInfo 供 LiveRoomView 调试面板读取。
    private func syncDebug(tx: Int, rx: Int, worst: Int) {
        let st = self.status.rawValue
        let bad = self.consecutiveBadCount
        let good = self.consecutiveGoodCount
        let total = self.totalReports
        let agoraFps = (agora?.currentQuality == .low) ? 15 : 30
        let cameraFps = camera?.targetFPS ?? 30
        store?.updateNetworkDebug { info in
            info.status = st
            info.bad = bad
            info.good = good
            info.lastTx = tx
            info.lastRx = rx
            info.lastWorst = worst
            info.total = total
            info.agoraFps = agoraFps
            info.cameraFps = cameraFps
        }
    }

    // MARK: - 事件

    private func degrade() {
        logger.warning("network degraded (≥\(self.warnThreshold) bad) → low fps + 600kbps + camera throttle 15fps + toast")
        currentLevel = .weakWarning
        agora?.applyEncoderQuality(.low)
        camera?.targetFPS = 15                    // v5.1：相机推帧同步降到 15fps 防堆积
        store?.setNetworkWarning(L10n.networkWarning)
    }

    private func recover() {
        logger.info("network recovered (≥\(self.recoverThreshold) good) → normal fps + auto bitrate + camera 30fps + clear toast")
        currentLevel = .normal
        agora?.applyEncoderQuality(.normal)
        camera?.targetFPS = 30                    // v5.1：相机推帧恢复 30fps
        store?.setNetworkWarning(nil)
    }

    private func endLive() {
        logger.error("network bad ≥\(self.endThreshold) → forceEnd weakNetwork")
        currentLevel = .weakSevere
        // TODO: ThinkingData 接入后真实埋点 c_log_networkBad（J 里程碑）
        Task { [weak self] in
            await self?.store?.forceEnd(reason: .weakNetwork, subSource: "network_bad_30")
        }
    }
}
