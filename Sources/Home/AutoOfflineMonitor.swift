import Foundation
import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "auto-offline")

/// 长时间无操作自动置离线（对齐 H5 `App.vue` useDynamicInactivityTimer）。
///
/// **触发链路**：
/// 1. 登录后 `AppConfigService.getConfigByKey("max_no_use_app_reminder_time")` 返回分钟数 `M`
/// 2. `start(reminderMinutes: M)` 启动计时（`M > 0` 才启用；服务端不开则不启用）
/// 3. UI 交互（tap / drag） / `scenePhase → .active` / WSHeartbeat 送礼等业务事件 → `pokeActivity()` 重置计时
/// 4. 无 `pokeActivity` 满 M 分钟 → `OnlineStatusStore.setUserSetOnline(false)` + `showDialog = true`
/// 5. 用户点弹窗 "Go Online" → `setUserSetOnline(true)` + 重启计时
///    背景 dim 点关 → 保持离线，计时不重启（等下次真交互再重启）
///
/// **忙碌态守卫**（对齐 H5 `isBusy = isLiving || isCalling`）：
/// - `CallStore.shared.state != .idle` → 自动 `suspend()`
/// - `LiveRoomView` / `PartyRoomView` 生命周期显式调 `suspend()` / `resume()`
/// - suspend 期间 pokeActivity 不重置计时；resume 时才重置一次
@MainActor
final class AutoOfflineMonitor: ObservableObject {
    static let shared = AutoOfflineMonitor()

    // MARK: - 对外发布态

    /// 弹窗展示态，RootView.overlay 观察
    @Published var showDialog: Bool = false

    // MARK: - 私有

    private var reminderSeconds: TimeInterval = 0     // 0 = 未启用
    private var timerTask: Task<Void, Never>?
    private var suspendDepth: Int = 0                 // suspend 引用计数（多源可能重叠）
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 订阅 CallStore 状态：非 idle → suspend，回 idle → resume。
        //
        // ⚠️ 必须先 `map { $0 == .idle }` 派生 idle 布尔 + removeDuplicates（对齐
        // .claude/rules/swiftui-keepalive-publisher-isolation.md 派生守门模式）。
        // 直接 removeDuplicates() 只去重相邻同值，通话跨越 idle→calling→connecting→connected→ended→idle
        // 5 跳全部 fire sink → suspend 4 次 + resume 1 次 → suspendDepth 卡在 3 永不归零
        // → pokeActivity 内 `guard suspendDepth == 0` 永久阻塞 → 一次通话后 Monitor 完全失效。
        // 复查报告-202607070003 必修-1。
        CallStore.shared.$state
            .map { $0 == .idle }
            .removeDuplicates()
            .sink { [weak self] isIdle in
                guard let self else { return }
                if isIdle {
                    self.resume()
                } else {
                    self.suspend()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// 登录后调用。M=0 时不启用（对齐 H5 `if (_reminderTime > 0)` 守卫）。
    /// 幂等：重复调用同值不重启计时；不同值时重启。
    func start(reminderMinutes: Int) {
        guard reminderMinutes > 0 else {
            logger.info("[AutoOffline] disabled: reminderMinutes=0 (服务端未开)")
            stop()
            return
        }
        let newSeconds = TimeInterval(reminderMinutes * 60)
        guard reminderSeconds != newSeconds else { return }
        reminderSeconds = newSeconds
        logger.info("[AutoOffline] started, reminderMinutes=\(reminderMinutes, privacy: .public)")
        pokeActivity()   // 启动即开始计时
    }

    /// 登出时调用。
    func stop() {
        reminderSeconds = 0
        suspendDepth = 0
        timerTask?.cancel()
        timerTask = nil
        showDialog = false
        logger.info("[AutoOffline] stopped")
    }

    /// UI 交互 / 前台恢复 / 业务活动时调，重置计时。
    /// suspend 中不重启计时（避免通话中间的伪活动信号）。
    func pokeActivity() {
        guard reminderSeconds > 0, suspendDepth == 0 else { return }
        restartTimer()
    }

    /// 忙碌态入口（通话 / 直播 / 派对房）暂停监测。可重入（引用计数）。
    func suspend() {
        suspendDepth += 1
        timerTask?.cancel()
        timerTask = nil
    }

    /// 与 suspend 配对。降到 0 时重启计时。
    func resume() {
        guard suspendDepth > 0 else { return }
        suspendDepth -= 1
        if suspendDepth == 0, reminderSeconds > 0 {
            restartTimer()
        }
    }

    /// 弹窗内 "Go Online" 按钮回调。
    func handleGoOnline() {
        showDialog = false
        OnlineStatusStore.shared.setUserSetOnline(true)
        pokeActivity()   // 重启计时
        logger.info("[AutoOffline] user clicked Go Online, resumed timer")
    }

    /// 弹窗背景 dim 点关闭。保持离线态，不重启计时（等下次真交互）。
    func handleDialogDismiss() {
        showDialog = false
    }

    // MARK: - 私有

    private func restartTimer() {
        timerTask?.cancel()
        let seconds = reminderSeconds
        timerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.fireAutoOffline()
        }
    }

    private func fireAutoOffline() {
        logger.notice("[AutoOffline] fired: no activity for \(Int(self.reminderSeconds/60), privacy: .public) min → set offline + show dialog")
        OnlineStatusStore.shared.setUserSetOnline(false)
        showDialog = true
    }
}
