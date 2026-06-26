import Foundation
import NIMSDK
import os

/// 云信 NIM 长连接保活，专门用来上报"主播在线"。
///
/// 后端（与 H5 / 用户端共用）通过云信 presence 判断主播是否 online——这是用户端列表/搜索
/// 看到"主播在线"的唯一来源。iOS 主播登录后必须立刻建 NIM 长连接并保持，否则即便登录成功，
/// 用户端 `apiBatchQueryYxStatByUid` / NIM `subscribeOnlineStatusEvents` 都查不到本端在线。
///
/// **H M1 重构**：内部委托给 `NIMService.shared.login` / `logout`；外部 API 不变，
/// `start(account:token:)` / `stop()` 调用点（HilyApp / SessionStore）零改动。
@MainActor
final class NIMOnlineKeeper {
    static let shared = NIMOnlineKeeper()

    @Published private(set) var isLogined: Bool = false

    /// 串行化 start/stop：快速切账号场景（token 失效自动重登）下避免 logout Task 还在跑、
    /// start Task 已并发 await login，最终 connectionState 被 logout 完成后写回 idle 覆盖新登录态。
    private var pendingTask: Task<Void, Never>?

    private init() {}

    /// 登录后调用。重复调用安全：已登录直接返回。
    func start(account: String, token: String) {
        NIMService.setupOnce()
        if NIMSDK.shared().loginManager.isLogined() {
            AppLogger.im.info("🟢 [NIMOnline] 已登录，跳过")
            isLogined = true
            return
        }
        AppLogger.im.debug("🟢 [NIMOnline] 开始登录 account=\(account, privacy: .private) tokenLen=\(token.count, privacy: .private)")
        let prior = pendingTask
        pendingTask = Task { @MainActor [weak self] in
            _ = await prior?.value
            guard let self else { return }
            do {
                try await NIMService.shared.login(account: account, token: token)
                self.isLogined = true
                AppLogger.im.info("✅ [NIMOnline] 登录成功 — 主播在线态已上报")
            } catch {
                self.isLogined = false
                AppLogger.im.error("🔴 [NIMOnline] 登录失败 \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// 登出时调用。
    func stop() {
        let prior = pendingTask
        pendingTask = Task { @MainActor [weak self] in
            _ = await prior?.value
            guard let self else { return }
            await NIMService.shared.logout()
            self.isLogined = false
            AppLogger.im.info("🟢 [NIMOnline] 已 logout")
        }
    }
}
