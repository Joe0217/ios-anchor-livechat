import Foundation
import AgoraRtmKit
import UIKit

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
final class RtmReconnect {
    private(set) var state: RtmConnState = .idle
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
            // 主动 leaveChannel 也会进 disconnected，但 reason==leaveChannel 时不要重连
            if reason == .changedLeaveChannel { return }
            scheduleReconnect(reason: "disconnected_reason\(reason.rawValue)")
        case .failed:
            handleFailed(reason: reason)
        @unknown default:
            print("⚠️ [RTM] 未知连接状态 \(s.rawValue) reason=\(reason.rawValue)")
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
                        print("⚠️ [RTM] tokenWillExpire renew 失败 code=\(err.errorCode.rawValue) reason=\(err.reason)")
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
            print("🚨 [RTM] 致命态 reason=\(reason.rawValue)（bannedByServer/rejectedByServer）→ \(CallTuning.sameUidLogoutDelayMs)ms 后触发 logout")
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
                _ = await self?.refreshToken?()
                self?.scheduleReconnect(reason: "token_failed_\(reason.rawValue)")
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
        print("📶 [RTM] scheduleReconnect reason=\(reason) delay=\(delay)s attempt=\(attempt + 1)")

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
            print("⚠️ [RTM] reconnect 但 token 为空 attempt=\(failedCount) reason=\(reason) → 调度下一轮")
            scheduleReconnect(reason: "\(reason)_empty_token")
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            client.login(token) { [weak self] _, err in
                guard let self else { cont.resume(); return }
                Task { @MainActor in
                    if let err {
                        print("📶 [RTM] reconnect 登录失败 attempt=\(self.failedCount) reason=\(reason) code=\(err.errorCode.rawValue) msg=\(err.reason)")
                        self.scheduleReconnect(reason: reason)
                    } else {
                        print("📶 [RTM] reconnect 登录成功 attempt=\(self.failedCount) reason=\(reason)")
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
                    print("⚠️ [RTM] proactive renewToken 失败 code=\(err.errorCode.rawValue) msg=\(err.reason)")
                }
                cont.resume()
            }
        }
        scheduleProactiveRenewal()
    }

    // MARK: - 内部：清理

    private func cancelRetry()   { retryTask?.cancel();   retryTask = nil }
    private func cancelRenewal() { renewalTask?.cancel(); renewalTask = nil }

    // MARK: - 前台恢复

    @objc private func onForeground() {
        Task { @MainActor [weak self] in
            guard let self, !self.disposed else { return }
            if self.state == .disconnected {
                print("📶 [RTM] foreground 触发立即重连")
                self.cancelRetry()
                self.failedCount = 0
                await self.runReconnectOnce(reason: "foreground_resume")
            }
        }
    }
}
