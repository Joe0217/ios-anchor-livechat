import Foundation
import SwiftUI
import Combine
import UIKit
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
///    右上角 X 点关 → 保持离线，计时不重启（等下次真交互再重启）
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
    /// P1: pokeActivity 节流窗口（秒）。用户高频 tap 时避免反复 cancel + create Task。
    /// 5s 相对 15+ 分钟的 reminder 阈值误差 <0.6%，业务无感知。
    private var lastPokedAt: TimeInterval = 0
    private static let pokeThrottleSeconds: TimeInterval = 5
    /// P0: UIWindow 级 UIPanGestureRecognizer——捕获 ScrollView 滚动（RootView 的 SwiftUI DragGesture
    /// 会被 UIScrollView 的 UIPanGestureRecognizer 吸走，全局祖先 SwiftUI gesture 无法感知滚动）。
    /// cancelsTouchesInView=false + delegate simultaneous 保证纯观察不拦截下层任何 gesture。
    private var scrollActivityGR: UIPanGestureRecognizer?
    private var scrollActivityDelegate: ScrollActivityDelegate?

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
        // 首次启动或阈值变更时都要重启计时；attach detector 独立守卫（内部 scrollActivityGR == nil 幂等）
        let shouldRestart = (reminderSeconds != newSeconds)
        reminderSeconds = newSeconds
        attachScrollDetector()
        if shouldRestart {
            logger.info("[AutoOffline] started, reminderMinutes=\(reminderMinutes, privacy: .public)")
            pokeActivity(force: true)   // 启动即开始计时，绕过 5s 节流
        }
    }

    /// 登出时调用。
    func stop() {
        reminderSeconds = 0
        suspendDepth = 0
        timerTask?.cancel()
        timerTask = nil
        showDialog = false
        detachScrollDetector()
        lastPokedAt = 0
        logger.info("[AutoOffline] stopped")
    }

    /// UI 交互 / 前台恢复 / 业务活动时调，重置计时。
    /// suspend 中不重启计时（避免通话中间的伪活动信号）。
    /// P1: 5s 节流——高频 tap 只 restart 一次 Task（业务阈值 15+ 分钟，误差可忽略）。
    func pokeActivity(force: Bool = false) {
        guard reminderSeconds > 0, suspendDepth == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastPokedAt < Self.pokeThrottleSeconds { return }
        lastPokedAt = now
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
        pokeActivity(force: true)   // 用户显式操作，绕过节流强制重启计时
        logger.info("[AutoOffline] user clicked Go Online, resumed timer")
    }

    /// 弹窗右上角 X 点关闭。保持离线态，不重启计时（等下次真交互）。
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
        // P2: `Task.sleep` 用连续时钟，后台不暂停 —— 用户后台超过 reminder 时长后回前台，
        // 会出现"回前台一瞬间闪弹窗 + 误下线"的 race。scenePhase→.active 会调 pokeActivity
        // 重启计时，此处只在真前台态时才 fire。
        guard UIApplication.shared.applicationState == .active else {
            logger.info("[AutoOffline] fire skipped (app not active); scenePhase→.active 会 restart timer")
            return
        }
        logger.notice("[AutoOffline] fired: no activity for \(Int(self.reminderSeconds/60), privacy: .public) min → set offline + show dialog")
        OnlineStatusStore.shared.setUserSetOnline(false)
        showDialog = true
    }

    // MARK: - P0: UIWindow 级滚动检测

    /// 挂 UIPanGestureRecognizer 到 key window。cancelsTouchesInView=false + delegate simultaneous
    /// 保证纯观察不拦截下层任何 gesture（与已修复的 root DragGesture(minDist:0) bug 本质不同：
    /// 那是 SwiftUI arbitration 层 preempt；这里是 UIKit 层"透明" observer）。
    private func attachScrollDetector() {
        guard scrollActivityGR == nil else { return }
        if let window = keyWindow() {
            attachOn(window: window)
            return
        }
        // key window 未 ready（首次登录时），100ms 后重试一次
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self,
                  self.scrollActivityGR == nil,
                  let window = self.keyWindow() else {
                logger.warning("[AutoOffline] scroll detector attach failed: no key window after retry")
                return
            }
            self.attachOn(window: window)
        }
    }

    private func attachOn(window: UIWindow) {
        let delegate = ScrollActivityDelegate { [weak self] in
            // UIKit gesture handler 已在 main queue；用 Task hop 满足 @MainActor 隔离
            Task { @MainActor [weak self] in self?.pokeActivity() }
        }
        let gr = UIPanGestureRecognizer(target: delegate,
                                        action: #selector(ScrollActivityDelegate.handlePan(_:)))
        gr.delegate = delegate
        gr.cancelsTouchesInView = false      // 关键：不拦截下层 UIScrollView / Slider gesture
        gr.maximumNumberOfTouches = 1
        window.addGestureRecognizer(gr)
        scrollActivityDelegate = delegate
        scrollActivityGR = gr
        logger.info("[AutoOffline] scroll detector attached to key window")
    }

    private func detachScrollDetector() {
        if let gr = scrollActivityGR {
            gr.view?.removeGestureRecognizer(gr)
        }
        scrollActivityGR = nil
        scrollActivityDelegate = nil
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) }
            .first
    }
}

// MARK: - UIKit gesture delegate 兼容层

/// AutoOfflineMonitor 是 @MainActor Swift class，不继承 NSObject；用独立 NSObject 桥接
/// UIGestureRecognizer 的 target-action + delegate 协议。closure 回调 pokeActivity。
private final class ScrollActivityDelegate: NSObject, UIGestureRecognizerDelegate {
    private let onBegan: () -> Void
    init(onBegan: @escaping () -> Void) {
        self.onBegan = onBegan
        super.init()
    }

    @objc func handlePan(_ gr: UIPanGestureRecognizer) {
        // 只在 gesture 首次 recognize（.began）时 fire，avoid .changed 高频调用
        if gr.state == .began { onBegan() }
    }

    /// 允许与所有其他 gesture 并存 —— 保证 SwiftUI Slider / UIScrollView pan 不受影响
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
