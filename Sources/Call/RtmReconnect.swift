import Foundation
import AgoraRtmKit
import UIKit
import os

/// RTM 连接状态机（对应 H5 RTM_RECONNECT_STATE V2.1 精简版）。
/// 注：H5 老版有 `.suspended`（network offline/page hidden）；V2.1 已精简掉，iOS 同步移除。
enum RtmConnState: String {
    case idle, connecting, connected, reconnecting, disconnected
}

/// RTM 重连大脑（对齐 H5 useRtmReconnect.js V2.1 简化版）。
///
/// 责任：
/// - 快重试 3 次（1s/2s/4s 累计 7s），覆盖瞬时抖动；用尽后转后台慢重试 5s/次
/// - 主动 token 续期：(TTL - 30s) 触发一次 renewToken；被动监听 tokenPrivilegeWillExpire 兜底
/// - 被动监听 connection state 变化：FAILED + bannedByServer = SAME_UID 致命态 → 延迟 500ms 触发 logout
/// - iOS 前台恢复（willEnterForeground）触发 reset + 立即重连
///
/// 注意：本类**不弹窗、不挂电话**。业务层（CallStore）自行根据 state 决定 UI 表现。
@MainActor
final class RtmReconnect: ObservableObject {
    /// RTM 真实连接状态，跟 SDK connectionChangedToState 实时联动。
    /// 业务层通过 CallSignaling.rtmStatePublisher 订阅，驱动 UI"重连中/断连"指示。
    @Published private(set) var state: RtmConnState = .idle
    private(set) var failedCount = 0

    // 由 CallSignaling 注入，避免循环引用
    private weak var client: AgoraRtmClientKit?
    private var refreshToken: (() async -> String?)?
    private var onSameUidLogin: (() -> Void)?

    private var retryTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var disposed = false

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - 绑定 / 销毁

    func bind(client: AgoraRtmClientKit,
              refreshToken: @escaping () async -> String?,
              onSameUidLogin: @escaping () -> Void) {
        guard self.client == nil else { return }
        self.client = client
        self.refreshToken = refreshToken
        self.onSameUidLogin = onSameUidLogin
        state = .connected
        scheduleProactiveRenewal()
    }

    func dispose() {
        if disposed { return }
        disposed = true
        cancelRetry()
        cancelRenewal()
        client = nil
    }

    // MARK: - 外部触发（信令 publish 失败时调用）

    /// 显式触发一次重连（不在 reconnecting 态时才生效）
    func triggerReconnect(reason: String) {
        guard !disposed, client != nil else { return }
        if state == .reconnecting { return }
        scheduleReconnect(reason: reason)
    }

    /// 复位失败计数 + 状态归零（成功登录后调用）
    func reset() {
        cancelRetry()
        failedCount = 0
        state = client != nil ? .connected : .idle
    }

    // MARK: - SDK 事件回调（由 CallSignaling 转发）

    func handleConnectionChange(state s: AgoraRtmClientConnectionState,
                                reason: AgoraRtmClientConnectionChangeReason) {
        guard !disposed else { return }
        switch s {
        case .connected:
            cancelRetry()
            failedCount = 0
            state = .connected
            scheduleProactiveRenewal()
        case .reconnecting:
            state = .reconnecting
        case .connecting:
            state = .connecting
        case .disconnected:
            // 主动 leaveChannel / logout 进 disconnected 时不要重连。
            // .changedLogout 防御性过滤：dispose 守卫一般已挡住后续回调，但万一回调时序早于
            // dispose 标志置位（例如 client.logout(nil) 内部立即派发），避免无意义 reconnect 调度。
            if reason == .changedLeaveChannel || reason == .changedLogout { return }
            scheduleReconnect(reason: "disconnected_reason\(reason.rawValue)")
        case .failed:
            handleFailed(reason: reason)
        @unknown default:
            AppLogger.rtm.notice("⚠️ [RTM] 未知连接状态 \(s.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        }
    }

    func handleTokenPrivilegeWillExpire() {
        guard !disposed else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let new = await self.refreshToken?() ?? ""
            guard !new.isEmpty, let client = self.client else { return }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                client.renewToken(new) { _, err in
                    if let err {
                        AppLogger.rtm.notice("⚠️ [RTM] tokenWillExpire renew 失败 code=\(err.errorCode.rawValue, privacy: .public) reason=\(err.reason, privacy: .private)")
                    }
                    cont.resume()
                }
            }
            self.scheduleProactiveRenewal()
        }
    }

    // MARK: - 内部：调度 / 执行

    private func handleFailed(reason: AgoraRtmClientConnectionChangeReason) {
        // SAME_UID 致命态：账号在别处登录 / 被服务端封禁。延迟 500ms 后触发外部 logout，
        // 给前一段日志/埋点一个 flush 窗口（与 H5 一致）。
        if reason == .changedBannedByServer || reason == .changedRejectedByServer {
            AppLogger.rtm.error("🚨 [RTM] 致命态 reason=\(reason.rawValue, privacy: .public)（bannedByServer/rejectedByServer）→ \(CallTuning.sameUidLogoutDelayMs, privacy: .public)ms 后触发 logout")
            cancelRetry()
            cancelRenewal()
            state = .idle
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(CallTuning.sameUidLogoutDelayMs) * 1_000_000)
                self?.onSameUidLogin?()
            }
            return
        }
        // token 类失败：先续 token 再重连
        if reason == .changedTokenExpired || reason == .changedInvalidToken {
            Task { @MainActor [weak self] in
                // dispose 后避免无意义的 token 续期网络请求（handleFailed 触发的瞬间 disposed 一定 false，
                // 但 Task body 异步跑起来时可能已 dispose）
                guard let self, !self.disposed else { return }
                _ = await self.refreshToken?()
                self.scheduleReconnect(reason: "token_failed_\(reason.rawValue)")
            }
            return
        }
        scheduleReconnect(reason: "failed_reason\(reason.rawValue)")
    }

    private func scheduleReconnect(reason: String) {
        guard !disposed, client != nil else { return }
        cancelRetry()

        let attempt = failedCount
        let delay: TimeInterval
        if attempt < CallTuning.rtmQuickRetryDelays.count {
            delay = CallTuning.rtmQuickRetryDelays[attempt]
            state = .reconnecting
        } else {
            delay = CallTuning.rtmSlowRetryInterval
            state = .disconnected
        }
        AppLogger.rtm.debug("📶 [RTM] scheduleReconnect reason=\(reason, privacy: .public) delay=\(delay, privacy: .public)s attempt=\(attempt + 1, privacy: .public)")

        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.runReconnectOnce(reason: reason)
        }
    }

    private func runReconnectOnce(reason: String) async {
        guard !disposed, let client else { return }
        failedCount += 1
        let token = await refreshToken?() ?? ""
        if token.isEmpty {
            AppLogger.rtm.notice("⚠️ [RTM] reconnect 但 token 为空 attempt=\(self.failedCount, privacy: .public) reason=\(reason, privacy: .public) → 调度下一轮")
            scheduleReconnect(reason: "\(reason)_empty_token")
            return
        }
        // TODO(理论防御): 如果 Agora SDK 在 destroy 期间 / 边界 case 下未调用 login completion，
        // continuation 会永挂导致 retryTask 内存泄漏 + state 卡 .reconnecting。当前依赖 SDK 文档
        // "completion 必调"保证。如未来真机出现卡 .reconnecting 不流转的现象，考虑用双 task race +
        // continuation box 状态机加 10s 超时。
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            client.login(token) { [weak self] _, err in
                guard let self else { cont.resume(); return }
                Task { @MainActor in
                    if let err {
                        AppLogger.rtm.notice("📶 [RTM] reconnect 登录失败 attempt=\(self.failedCount, privacy: .public) reason=\(reason, privacy: .public) code=\(err.errorCode.rawValue, privacy: .public) msg=\(err.reason, privacy: .private)")
                        self.scheduleReconnect(reason: reason)
                    } else {
                        AppLogger.rtm.debug("📶 [RTM] reconnect 登录成功 attempt=\(self.failedCount, privacy: .public) reason=\(reason, privacy: .public)")
                        // state 会由 connectionChange .connected 回调统一回写
                    }
                    cont.resume()
                }
            }
        }
    }

    // MARK: - 内部：主动 token 续期（保险层）

    private func scheduleProactiveRenewal() {
        cancelRenewal()
        guard !disposed else { return }
        let lead = CallTuning.rtmTokenTTL - CallTuning.rtmTokenRenewAhead
        guard lead > 0 else { return }
        renewalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lead * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.performProactiveRenewal()
        }
    }

    private func performProactiveRenewal() async {
        guard !disposed, let client else { return }
        let token = await refreshToken?() ?? ""
        guard !token.isEmpty else {
            scheduleProactiveRenewal()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            client.renewToken(token) { _, err in
                if let err {
                    AppLogger.rtm.notice("⚠️ [RTM] proactive renewToken 失败 code=\(err.errorCode.rawValue, privacy: .public) msg=\(err.reason, privacy: .private)")
                }
                cont.resume()
            }
        }
        scheduleProactiveRenewal()
    }

    // MARK: - 内部：清理

    private func cancelRetry()   { retryTask?.cancel();   retryTask = nil }
    private func cancelRenewal() { renewalTask?.cancel(); renewalTask = nil }

    // MARK: - 网络恢复立即重连

    /// 网络恢复 / 外部环境变好时调用。对齐 H5 useRtmReconnect.js 的 'online' 事件处理。
    /// 仅在 .disconnected（慢重试 5s 节奏中段）时跳过 schedule 立即触发；.reconnecting
    /// （快重试 1s/2s/4s 中）让原节奏自然收敛，避免与正在 sleep 的 retryTask 双跑 login。
    ///
    /// guard 同步执行：函数本身已在 @MainActor，无需 Task hop；避免 hop 之间 state 再次变化
    /// （如 .disconnected → .reconnecting）导致进入了 Task 体却条件已失效。仅在真要 runReconnectOnce
    /// 时才 Task 提供 async 上下文。
    func forceImmediateReconnect(reason: String) {
        guard !disposed, client != nil, state == .disconnected else { return }
        AppLogger.rtm.debug("📶 [RTM] network 触发立即重连 reason=\(reason, privacy: .public)")
        cancelRetry()
        failedCount = 0
        Task { @MainActor [weak self] in
            await self?.runReconnectOnce(reason: reason)
        }
    }

    // MARK: - 前台恢复

    @objc private func onForeground() {
        Task { @MainActor [weak self] in
            guard let self, !self.disposed else { return }
            if self.state == .disconnected {
                AppLogger.rtm.debug("📶 [RTM] foreground 触发立即重连")
                self.cancelRetry()
                self.failedCount = 0
                await self.runReconnectOnce(reason: "foreground_resume")
            }
        }
    }
}
