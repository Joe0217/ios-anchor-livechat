import Foundation
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "HeartbeatController")

/// 直播心跳控制器（B 里程碑 spec §3）。
///
/// 10s 间隔（对齐安卓；H5 6s 与 "10秒" 注释均废弃）。
/// 连续失败 >3 次 → store.forceEnd(.disconnected, subSource: "heartbeat_failed") → endType=4。
/// 响应码分流：1992/1006 → .banned (endType=2)；2001 → .noPermission (endType=6)。
///
/// **v5.3.2 三层防御**（与 NetworkQualityMonitor 对齐；2026-06-25 #12 回归修复）：
/// 1. **addAppLifecycleObservers**：监听 didEnterBackground / willEnterForeground
/// 2. **isInBackground flag**：后台静默 + tick 拦截，不调 API 不计 failure
/// 3. **回前台 5s 冷却 + failureCount=0**：丢弃切后台前 in-flight 请求的 timeout backlog
///
/// 回归路径（修复前）：切后台前 in-flight URLSession heartbeat 请求被系统挂起 → catch
/// `failureCount += 1`；后台累计 >3 次失败后，回前台 applicationState 切回 .active 第一拍
/// tick 立即命中 `count > 3` → forceEnd(.disconnected) → endType=4 误下播。
@MainActor
final class HeartbeatController {
    private weak var store: LiveStore?
    private var task: Task<Void, Never>?
    private var failureCount: Int = 0

    /// v5.3.2 三层防御：app 是否在后台（didEnterBackground=true / willEnterForeground=false）
    private var isInBackground: Bool = false
    /// v5.3.2 三层防御：回前台 5s 冷却结束时间。冷却期内 tick 直接 return，丢弃切后台前
    /// in-flight 请求 timeout 后回来累计的 failure backlog。
    private var foregroundCooldownUntil: Date?

    init(store: LiveStore) {
        self.store = store
        addAppLifecycleObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// LiveStore 进入 .living 态时调用。重复 start 会先 stop 再 start。
    func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // 10s 间隔（spec §3.1）
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// teardown 时调用：取消 Task + 重置失败计数。
    func stop() {
        task?.cancel()
        task = nil
        failureCount = 0
    }

    // MARK: - v5.3.2 app 生命周期监听（与 NetworkQualityMonitor 对称）

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
        Task { @MainActor [weak self] in
            self?.isInBackground = true
            logger.info("heartbeat: app entered background; tick will silently skip")
        }
    }

    @objc private func handleWillEnterForeground() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isInBackground = false
            // 真根因修复：切后台前 in-flight 请求 timeout 累计的 failure 必须清零，
            // 否则回前台第一拍 tick 命中 count > 3 → 误 forceEnd(.disconnected)
            self.failureCount = 0
            self.foregroundCooldownUntil = Date().addingTimeInterval(5)
            logger.info("heartbeat: foreground; reset failureCount=0 + 5s cooldown")
        }
    }

    private func tick() async {
        // 三层防御层 1：isInBackground flag（observer 设置；比 applicationState 同步可靠）
        if isInBackground {
            logger.debug("heartbeat tick skipped: isInBackground=true")
            return
        }
        // 三层防御层 2：5s 回前台冷却，丢弃 in-flight 请求 timeout backlog
        if let cd = foregroundCooldownUntil, Date() < cd {
            logger.debug("heartbeat tick skipped: foreground cooldown")
            return
        }
        // 三层防御层 3：applicationState 兜底（observer 漏触发时的最后一道关）
        guard UIApplication.shared.applicationState != .background else {
            logger.info("heartbeat tick skipped: applicationState=background")
            return
        }
        guard let store, let roomId = store.roomId else { return }
        do {
            try await LiveService.heartbeat(roomId: roomId, callState: store.callState)
            failureCount = 0
        } catch HeartbeatError.banned {
            await store.forceEnd(reason: .banned, subSource: "heartbeat_1992")
        } catch HeartbeatError.noPermission {
            await store.forceEnd(reason: .noPermission, subSource: "heartbeat_2001")
        } catch {
            failureCount += 1
            let count = failureCount
            logger.warning("heartbeat failed (\(count)/3): \(String(describing: error))")
            if count > 3 {
                await store.forceEnd(reason: .disconnected, subSource: "heartbeat_failed")
            }
        }
    }
}

#if DEBUG
// MARK: - 仅供单测使用的内部钩子（绕过 NotificationCenter，专注测三层防御逻辑）

extension HeartbeatController {
    /// 模拟切后台（单测用）
    func testOnly_simulateBackground() {
        isInBackground = true
    }
    /// 模拟回前台 + 清零 failureCount + 5s 冷却（单测用）
    func testOnly_simulateForeground() {
        isInBackground = false
        failureCount = 0
        foregroundCooldownUntil = Date().addingTimeInterval(5)
    }
    /// 注入 failureCount（单测用）
    func testOnly_inject(failureCount: Int) {
        self.failureCount = failureCount
    }
    /// 读取 failureCount（单测断言用）
    var testOnly_failureCount: Int { failureCount }
    /// 读取 isInBackground（单测断言用）
    var testOnly_isInBackground: Bool { isInBackground }
    /// 读取冷却期是否生效（单测断言用）
    var testOnly_isInForegroundCooldown: Bool {
        guard let cd = foregroundCooldownUntil else { return false }
        return Date() < cd
    }
}
#endif
