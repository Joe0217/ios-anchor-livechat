import Foundation
import UIKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "BackgroundMonitor")

/// 直播态"切后台超限强制下播"监控（B 里程碑增补 spec §2）。
///
/// 三档任一超阈值 → LiveStore.forceEnd(.backgroundExceeded, subSource: "bg_...") → endType=4：
/// - 累计切后台次数 ≥ 5
/// - 单次后台时长 ≥ 2 分钟
/// - 累计后台时长 ≥ 5 分钟
///
/// **执行路径**（iOS 后台限制决定）：
/// - **主路径**：`willEnterForeground` 时结算 —— 用户回前台的那一刻判断三档并 forceEnd
/// - **best-effort**：切后台瞬间 `beginBackgroundTask` 拿 ~30s 宽限期 + `Task.sleep(120s)` 到点 fire。
///   进程被 iOS 挂起（~10s 后）Task 停摆，用户长时间不回前台则依赖服务端心跳超时兜底
/// - **提醒**：切后台 100s（= 120 - 20）后 UNNotification 本地通知提醒用户回 App
///
/// **例外场景**（不计数不计时；handleEnterBackground guard）：
/// - store.state != .living  → forceEnding/ending/ended 全部跳过
/// - store.callState == 1    → 私 call 期切后台是正常业务态
/// - store.isWaitingReturnLive → returnLive 15s 倒计时期切后台是过渡态
///
/// 计数在 attachLiving 时清零、teardown 时 stop；一次直播周期内累积不跨播。
///
/// 模仿 HeartbeatController 的 lazy 持有 + start/stop 幂等模式。
@MainActor
final class BackgroundMonitor {
    weak var store: LiveStore?

    // MARK: - 状态
    private(set) var backgroundCount: Int = 0
    private(set) var cumulativeSeconds: TimeInterval = 0
    private var currentEnterAt: Date?

    // MARK: - 系统 API 资源
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var singleTimeoutTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    // MARK: - 生命周期（模仿 HeartbeatController.start/stop 幂等）

    /// LiveStore.attachLiving 时调用。重复 start 幂等：先 stop 再启动。
    func start() {
        stop()
        backgroundCount = 0
        cumulativeSeconds = 0
        currentEnterAt = nil

        let bgObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnterBackground() }
        }
        let fgObs = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnterForeground() }
        }
        observers = [bgObs, fgObs]
        logger.info("BackgroundMonitor started")
    }

    /// LiveStore.teardown 时调用：撤 observer + 释放后台任务 + 清 pending 通知。
    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        singleTimeoutTask?.cancel()
        singleTimeoutTask = nil
        endBackgroundTask()
        cancelPendingNotification()
        currentEnterAt = nil
    }

    // MARK: - didEnterBackground 处理

    private func handleEnterBackground() {
        guard let store else { return }

        // 例外三条件：非 living / 私 call / returnLive 15s → 不计数不计时
        // 🟠-5：非 living 全跳过（forceEnding/ending/ended 期切后台不能污染下次开播计数）
        // 🟠-4：pauseForCall 已提前把 callState 置 1，闸门在 leave 之前
        guard store.state == .living else {
            logger.info("didEnterBackground: state != .living, skip (state=\(String(describing: store.state)))")
            return
        }
        guard store.callState != 1 else {
            logger.info("didEnterBackground: callState==1 (in private call), skip")
            return
        }
        guard !store.isWaitingReturnLive else {
            logger.info("didEnterBackground: isWaitingReturnLive, skip")
            return
        }

        backgroundCount += 1
        currentEnterAt = Date()
        logger.info("didEnterBackground: count=\(self.backgroundCount) cumulative=\(Int(self.cumulativeSeconds))s")

        // best-effort：拿后台宽限期（~30s，iOS 13+ 收紧），让下面的 Task/Notification 尽量能启动
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "live.bg.watchdog") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }

        // best-effort：单次超时 Task。进程未被冻结的场景下（首 30s 内）能直接 fire；
        // 超过 30s iOS 会挂起进程，Task.sleep 停摆 —— 依赖 handleEnterForeground 主路径结算。
        singleTimeoutTask = Task { @MainActor [weak self] in
            let ns = UInt64(LiveBackgroundPolicy.maxSingleBackgroundDuration) * 1_000_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            guard self.store?.state == .living else { return }
            logger.info("singleTimeoutTask fired (progress not suspended)")
            await self.store?.forceEnd(reason: .backgroundExceeded, subSource: "bg_single_2m")
        }

        // 排本地通知（120s - 20s = 100s 后弹提醒；UN 由系统在挂起进程外调度，能可靠触达）
        schedulePendingNotification()
    }

    // MARK: - willEnterForeground 主结算路径

    private func handleEnterForeground() {
        guard let store else { return }

        // 释放 best-effort 资源（无论是否触发下播都要清）
        singleTimeoutTask?.cancel()
        singleTimeoutTask = nil
        endBackgroundTask()
        cancelPendingNotification()

        // 非 living 或未记录 currentEnterAt（例外场景下 didEnterBackground 已 return）→ 不结算
        guard store.state == .living, let start = currentEnterAt else {
            currentEnterAt = nil
            return
        }

        let thisDuration = Date().timeIntervalSince(start)
        cumulativeSeconds += thisDuration
        currentEnterAt = nil
        logger.info("willEnterForeground: thisDuration=\(Int(thisDuration))s cumulative=\(Int(self.cumulativeSeconds))s count=\(self.backgroundCount)")

        // 三档累积命中（不互斥，多档命中 subSource 拼接上报）
        var hits: [String] = []
        if thisDuration >= LiveBackgroundPolicy.maxSingleBackgroundDuration {
            hits.append("single_2m")
        }
        if cumulativeSeconds >= LiveBackgroundPolicy.maxCumulativeBackgroundDuration {
            hits.append("cumulative_5m")
        }
        if backgroundCount >= LiveBackgroundPolicy.maxBackgroundCount {
            hits.append("count5")
        }

        if !hits.isEmpty {
            let sub = "bg_" + hits.joined(separator: "+")
            logger.notice("🛑 [BackgroundMonitor] backgroundExceeded HIT sub=\(sub) thisDuration=\(Int(thisDuration))s cumulative=\(Int(self.cumulativeSeconds))s count=\(self.backgroundCount) callState=\(store.callState) isWaitingReturnLive=\(store.isWaitingReturnLive) → forceEnd")
            Task { await store.forceEnd(reason: .backgroundExceeded, subSource: sub) }
            return
        }

        // 未触发下播：预警（次数优先，其次累计时长；两者互斥不叠加）
        if backgroundCount >= LiveBackgroundPolicy.warnBackgroundCount {
            store.warn(message: String(
                format: L10n.liveBackgroundCountWarningFormat,
                backgroundCount, LiveBackgroundPolicy.maxBackgroundCount
            ))
        } else if cumulativeSeconds >= LiveBackgroundPolicy.warnCumulativeBackgroundDuration {
            let minutes = Int(cumulativeSeconds / 60)
            store.warn(message: String(
                format: L10n.liveBackgroundCumulativeWarningFormat, minutes
            ))
        }
    }

    // MARK: - 系统资源管理

    private func endBackgroundTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    private func schedulePendingNotification() {
        let center = UNUserNotificationCenter.current()
        // 权限已在 LivePrepareView.onAppear 前置请求；这里静默检查授权状态
        // 未授权直接跳过，不弹权限对话框（避免直播中打断）
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = L10n.liveBackgroundNotifTitle
            content.body = L10n.liveBackgroundNotifBody
            content.sound = .default

            let leadOffset = LiveBackgroundPolicy.maxSingleBackgroundDuration - LiveBackgroundPolicy.backgroundNotificationLeadTime
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: leadOffset, repeats: false)
            let req = UNNotificationRequest(
                identifier: LiveBackgroundPolicy.notificationIdentifier,
                content: content, trigger: trigger
            )
            center.add(req) { err in
                if let err {
                    logger.error("schedulePendingNotification failed: \(String(describing: err))")
                }
            }
        }
    }

    private func cancelPendingNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [LiveBackgroundPolicy.notificationIdentifier]
        )
    }
}
