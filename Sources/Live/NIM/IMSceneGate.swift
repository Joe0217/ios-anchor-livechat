import Foundation
import os

/// IM 场景过滤的**副作用层**：维护 active 场景集 + grace 窗口 + pending exit task。
///
/// 决策纯函数在 [IMSceneFilter](IMSceneFilter.swift)。
///
/// **三类对外接口**：
/// 1. **wiring 入口**（store didSet 调用）：`enter(_:)` / `exit(_:delay:)`
/// 2. **dispatch 入口**（NIMService 调用）：`allows(_:context:)`
/// 3. **生命周期入口**：`openBacklogGrace(seconds:)` / `resetAll()`
@MainActor
final class IMSceneGate {

    static let shared = IMSceneGate()

    nonisolated static let logger = Logger(subsystem: "com.anchor.livechat", category: "im-scene-gate")

    /// 当前活跃场景集。调试可观察用。
    private(set) var active: IMSceneFilter.ActiveScenes = []

    /// backlog grace 窗口结束时刻。`< Date()` 时窗口已关。
    private(set) var graceUntil: Date = .distantPast

    /// 每个场景一个 pending exit task。
    /// CallStore 8s grace 退出场景；新呼叫到达 enter(.call) 时取消防误退。
    private var pendingExitTasks: [Int: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - wiring 入口（store didSet）

    /// 进入场景。取消同场景的 pending exit task（处理快速 enter→exit→enter 边界）。
    func enter(_ scene: IMSceneFilter.ActiveScenes) {
        cancelPendingExit(for: scene)
        let before = active
        active.insert(scene)
        if before != active {
            Self.logger.debug("[IMSceneGate] enter \(scene.rawValue, privacy: .public) active=\(self.active.rawValue, privacy: .public)")
        }
    }

    /// 退出场景。`delay > 0` 时延迟切换（用于 CallStore .idle 后 8s grace 接收尾消息）。
    ///
    /// 同场景 pending exit task 存在时先取消旧的，避免叠加多个 timer 错乱。
    func exit(_ scene: IMSceneFilter.ActiveScenes, delay: TimeInterval = 0) {
        cancelPendingExit(for: scene)

        guard delay > 0 else {
            let before = active
            active.remove(scene)
            if before != active {
                Self.logger.debug("[IMSceneGate] exit \(scene.rawValue, privacy: .public) active=\(self.active.rawValue, privacy: .public)")
            }
            return
        }

        // Task 显式 @MainActor：与 CallStore 11/11 Task 工程约定一致 + 防 Swift 6 严格并发升级
        // 时 Task 闭包不再继承 enclosing actor 而编译报错（当前 Swift 5 默认模式下 build/tests 已过）。
        pendingExitTasks[scene.rawValue] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.active.remove(scene)
            self.pendingExitTasks[scene.rawValue] = nil
            Self.logger.debug("[IMSceneGate] exit \(scene.rawValue, privacy: .public) (delayed \(delay, privacy: .public)s) active=\(self.active.rawValue, privacy: .public)")
        }
    }

    private func cancelPendingExit(for scene: IMSceneFilter.ActiveScenes) {
        if let prior = pendingExitTasks.removeValue(forKey: scene.rawValue) {
            prior.cancel()
        }
    }

    // MARK: - 生命周期入口

    /// 开启 backlog grace 窗口。NIMService 在 onLogin .loginOK 触发。
    ///
    /// 默认 10s 覆盖典型离线 backlog 推送时长（onReceive 逐条推送，不是批量）。
    func openBacklogGrace(seconds: TimeInterval = 10) {
        graceUntil = Date().addingTimeInterval(seconds)
        Self.logger.info("[IMSceneGate] backlog grace opened \(seconds, privacy: .public)s")
    }

    /// 登出 / 账号切换时调用。SessionStore.logout / handleSessionInvalidated 末尾。
    func resetAll() {
        pendingExitTasks.values.forEach { $0.cancel() }
        pendingExitTasks.removeAll()
        active = []
        graceUntil = .distantPast
        Self.logger.info("[IMSceneGate] resetAll")
    }

    // MARK: - dispatch 入口

    /// NIMService.dispatch 入口调用。委托纯函数 IMSceneFilter.allows。
    func allows(_ attachType: AttachType, context: MessageContext) -> Bool {
        IMSceneFilter.allows(
            attachType: attachType,
            context: context,
            active: active,
            graceUntil: graceUntil,
            now: Date()
        )
    }
}
