import Foundation

/// G 里程碑 spec §2.5：PK 倒计时统一管理（三个独立计时器互不干扰）。
///
/// - **invite**：邀请态 60s（spec 默认 PK_TIME.INVITE_TIMEOUT）
/// - **inPK**：基于 `endTime` 绝对时间戳（H5 livePk.js:721 同行为：`(endTime - Date.now())/1000`）
///   前后台切换不漂移，因为不是基于 `Task.sleep(60s)` 累积时间，而是每秒回查绝对时间。
/// - **punish**：惩罚态 120s（spec 默认 PK_TIME.PUNISHMENT_DURATION）
///
/// 设计要点：
/// - 每个 timer 是独立 `Task` + `Task.sleep` 1s 步进；cancel 后下一秒 sleep 抛出立即返回
/// - `scheduleX` 重复调用会先 cancel 上一个再起新（幂等）
/// - `cancelAll` 用于 teardown / state→ended
@MainActor
final class PKCountdownController {
    private var inviteTask: Task<Void, Never>?
    private var inPKTask: Task<Void, Never>?
    private var punishTask: Task<Void, Never>?

    // MARK: - schedule

    /// 邀请态倒计时 N 秒（默认 60）。
    /// `onTick(remainingSeconds)` 每秒回调一次，从 N 递减到 0；`onExpire` 倒数到 0 时调一次后任务结束。
    func scheduleInvite(seconds: Int,
                        onTick: @escaping @MainActor (Int) -> Void,
                        onExpire: @escaping @MainActor () -> Void) {
        cancelInvite()
        inviteTask = Task { [weak self] in
            await PKCountdownController.run(total: seconds, onTick: onTick, onExpire: onExpire)
            await MainActor.run { self?.inviteTask = nil }
        }
    }

    /// 基于绝对时间戳的 inPK 倒计时。
    /// `endTime` 是本地自算的 PK 结束时刻；每秒按 `(endTime - now)` 回查 remainingSeconds。
    /// 前后台切换不漂移（依赖 `Date()` 当前时间而非累积 sleep）。
    func scheduleInPK(endAt: Date,
                      onTick: @escaping @MainActor (Int) -> Void,
                      onExpire: @escaping @MainActor () -> Void) {
        cancelInPK()
        inPKTask = Task { [weak self] in
            await PKCountdownController.runUntil(endAt: endAt, onTick: onTick, onExpire: onExpire)
            await MainActor.run { self?.inPKTask = nil }
        }
    }

    /// 惩罚态倒计时 N 秒（默认 120）。
    func schedulePunish(seconds: Int,
                        onTick: @escaping @MainActor (Int) -> Void,
                        onExpire: @escaping @MainActor () -> Void) {
        cancelPunish()
        punishTask = Task { [weak self] in
            await PKCountdownController.run(total: seconds, onTick: onTick, onExpire: onExpire)
            await MainActor.run { self?.punishTask = nil }
        }
    }

    // MARK: - cancel

    func cancelInvite() {
        inviteTask?.cancel()
        inviteTask = nil
    }

    func cancelInPK() {
        inPKTask?.cancel()
        inPKTask = nil
    }

    func cancelPunish() {
        punishTask?.cancel()
        punishTask = nil
    }

    func cancelAll() {
        cancelInvite()
        cancelInPK()
        cancelPunish()
    }

    // MARK: - 状态查询（单测/UI 用）

    var hasInviteTimer: Bool { inviteTask != nil }
    var hasInPKTimer: Bool { inPKTask != nil }
    var hasPunishTimer: Bool { punishTask != nil }

    // MARK: - 内部 runner

    /// 固定 N 秒 onTick 递减 + onExpire。
    /// sleep 完成后必须显式 `Task.isCancelled` 守卫——race window：cancel 与 sleep 完成同时发生时
    /// try-catch 不触发，避免后续多吐一次 tick。
    private static func run(total: Int,
                            onTick: @escaping @MainActor (Int) -> Void,
                            onExpire: @escaping @MainActor () -> Void) async {
        var remaining = total
        await MainActor.run { onTick(remaining) }
        while remaining > 0 {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return                                   // 被 cancel
            }
            if Task.isCancelled { return }               // race 兜底：sleep 已完成时 cancel 不会抛
            remaining -= 1
            await MainActor.run { onTick(remaining) }
        }
        if Task.isCancelled { return }
        await MainActor.run { onExpire() }
    }

    /// 基于绝对 endAt 的 runner（前后台不漂移）。
    private static func runUntil(endAt: Date,
                                 onTick: @escaping @MainActor (Int) -> Void,
                                 onExpire: @escaping @MainActor () -> Void) async {
        await MainActor.run {
            onTick(max(0, Int(endAt.timeIntervalSinceNow)))
        }
        while true {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }
            let remaining = max(0, Int(endAt.timeIntervalSinceNow))
            await MainActor.run { onTick(remaining) }
            if remaining <= 0 {
                if Task.isCancelled { return }
                await MainActor.run { onExpire() }
                return
            }
        }
    }
}
