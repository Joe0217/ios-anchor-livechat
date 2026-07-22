import Foundation
import NIMSDK
import os

/// 云信 IM 共底座（H 里程碑 spec §2.4）。
///
/// **职责集中**：
/// - `setupOnce` 全局注册 appKey + `GenericCustomAttachmentCoder`
/// - 登录态管理（`login` / `logout` / `refreshToken`）→ `NIMOnlineKeeper` 内部走本服务
/// - 进退聊天室辅助（直播 / 派对房 共用）
/// - 系统通知监听（`onReceiveCustomSystemNotification`） + 离线补发 throttle
/// - 长连接状态 `connectionState` `@Published` 给 UI / 业务订阅
/// - `MessageRouter` 注册中心 + 主分发入口 `dispatch(attachType:payload:context:)`
/// - 错误码分流：1004 挤下线 / 1005 token 失效 → 全局 `.apiSessionInvalidated` 与 `APIClient` 一致
///
/// **范围内**（M1）：纯底座 API + sysMsg 入口 + connectionState；
/// **范围外**：直播 / 派对房 chatroom 旧 manager 继续承担各自 enter / exit（M5 / M3 才简化）。
///
/// **运行时序**（spec §6 跨里程碑改动锁定接口）：
/// 1. HilyApp.init → `NIMService.setupOnce()`（M5 后由 NIMChatroomManager 内部代理调用）
/// 2. 登录后 SessionStore → `NIMService.shared.login(account:token:)` 触发 `NIMOnlineKeeper` 走本服务
/// 3. 进房（直播 / 派对房）→ 各自旧 manager 调本服务的 `enterChatroom`
/// 4. 各业务初始化时 → 各自 router 调本服务的 `registerRouter(_:)`
/// 5. 收到自定义系统消息 → 本服务 dispatch 到所有 router；每个 router 按 attachType 自挑
@MainActor
final class NIMService: NSObject, ObservableObject {

    // MARK: - 单例

    static let shared = NIMService()

    /// nonisolated 让 setupOnce 等非 main actor 上下文也能日志输出
    nonisolated static let logger = Logger(subsystem: "com.anchor.livechat", category: "nim-service")

    private override init() {
        super.init()
    }

    // MARK: - 状态

    /// 长连接状态（UI 可订阅）
    @Published private(set) var connectionState: NIMConnectionState = .idle

    /// SDK 会话/消息 sync 是否完成（对应 `NIMLoginStep.syncOK` delegate，值 8）。
    ///
    /// **与 `connectionState` 的区别**：`connectionState=.connected` 只表示 IM 通道 login OK
    /// （步骤 5），但 SDK 还有 `syncing`(7) → `syncOK`(8) 阶段，此期间 `allRecentSessions()` 可能返空。
    ///
    /// **消费者**：`MessageSessionStore` 订阅本信号触发 fetchAll（Step 3 反悔 #1 v2 修复：
    /// 冷启动 auto-login 时 SDK login 早于 sync，若用 `connectionState=.connected` 触发 fetch
    /// 会拿到空 sessions → 用户重启后消息丢失）。
    @Published private(set) var isSessionSyncOK: Bool = false

    /// 是否已登录 IM。优先读 SDK 实时态，避免本地缓存与 SDK 状态分裂。
    var isLogined: Bool {
        NIMSDK.shared().loginManager.isLogined()
    }

    // MARK: - setupOnce（全局只执行一次）

    /// `nonisolated(unsafe)` 让旧调用点（如 NIMChatroomManager.setupOnce 非 @MainActor static func）
    /// 也能调本服务。状态变更只发生一次，由 NSLock 保护。
    private static let didSetupLock = NSLock()
    nonisolated(unsafe) private static var didSetup = false

    /// 注册 appKey + `GenericCustomAttachmentCoder` + 接管 sysMsg / login delegate。
    /// 幂等：多次调用安全。**nonisolated**：允许 NIMChatroomManager.setupOnce / 早期非 main actor 调用点直接调。
    ///
    /// **临界区涵盖完整 SDK register**：H 收尾审查 P1-4 修复。原实现把 `didSetup = true` 提前解锁后才跑
    /// `NIMSDK.register`，并发第二者会读到 `didSetup=true` 立即返回并随即调 `login`，命中 SDK 未注册
    /// appKey 窗口期 → login 静默失败。HilyApp.init / NIMChatroomManager / NIMOnlineKeeper 三处都调
    /// 本方法，并发并非小概率。
    nonisolated static func setupOnce() {
        didSetupLock.lock()
        defer { didSetupLock.unlock() }
        if didSetup { return }

        let option = NIMSDKOption(appKey: AppConfig.nimAppKey)
        NIMSDK.shared().register(with: option)
        NIMCustomObject.registerCustomDecoder(GenericCustomAttachmentCoder())
        didSetup = true

        // delegate.add 必须 main actor；register 已完成，可放心异步切换不再有窗口期。
        Task { @MainActor in
            NIMSDK.shared().systemNotificationManager.add(NIMService.shared)
            NIMSDK.shared().loginManager.add(NIMService.shared)
            let sysRouter = SystemMessageRouter.shared
            sysRouter.callStore = CallStore.shared
            sysRouter.sessionStore = SessionStore.shared
            sysRouter.robotCallStore = RobotCallStore.shared
            NIMService.shared.registerRouter(sysRouter)
            // GiftEffect Call 场景 sysMsg 通道礼物 attachType=4 router（return false 不独占，
            // 保证 SystemMessageRouter 等下游仍能处理别的 sysMsg 副作用）
            NIMService.shared.registerRouter(GiftEffectSysMsgRouter.shared)
        }

        logger.info("🟢 [NIMService] setupOnce: appKey=\(AppConfig.nimAppKey, privacy: .private)")
    }

    // MARK: - 登录态管理

    /// 登录 IM。重复登录时直接返回，不再调 SDK。
    /// - Throws: `NIMServiceError`
    func login(account: String, token: String) async throws {
        if isLogined {
            // 同步 connectionState：极少数路径下 NIMLoginManagerDelegate.onLogin(.loginOK) 早于本 helper 调用，
            // 但本地 @Published 状态仍可能在 .idle / .connecting；显式刷新避免 UI 显示分裂。
            connectionState = .connected
            // SDK auto-login 场景：进程重启时 SDK isLogined=true 但不 fire delegate → 主动设 syncOK=true
            // 假设：SDK isLogined 意味着之前 login 完整走完 → sessions 已 sync（v2 修复：MessageStore fetchAll 门 gate）
            isSessionSyncOK = true
            Self.logger.info("🟢 [NIMService] 已登录，跳过 login (isSessionSyncOK=true)")
            return
        }
        connectionState = .connecting

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            NIMSDK.shared().loginManager.login(account, token: token) { [weak self] error in
                Task { @MainActor in
                    guard let self else {
                        cont.resume()
                        return
                    }
                    if let error {
                        let mapped = NIMServiceError.from(nsError: error as NSError, fallback: .loginFailed(code: (error as NSError).code, message: error.localizedDescription))
                        self.connectionState = .disconnected
                        Self.logger.error("🔴 [NIMService] login 失败 code=\((error as NSError).code, privacy: .public)")
                        self.notifyIfSessionInvalidating(mapped)
                        cont.resume(throwing: mapped)
                    } else {
                        self.connectionState = .connected
                        // v2 修复：不在 login 成功 continuation 内设 isSessionSyncOK / openBacklogGrace，
                        // 等 SDK delegate .syncOK 触发。SDK 契约：login 成功后依次 syncing → syncOK。
                        // 早于 syncOK 触发 grace 会让 backlog push 期间的 sysMsg 被误 drop（不在 grace window 内）。
                        Self.logger.info("✅ [NIMService] login 成功 account=\(account, privacy: .private) (waiting .syncOK)")
                        cont.resume()
                    }
                }
            }
        }
    }

    /// 登出 IM。已登出时直接返回，不再调 SDK。
    func logout() async {
        guard isLogined else {
            connectionState = .idle
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            NIMSDK.shared().loginManager.logout { [weak self] error in
                Task { @MainActor in
                    if let error {
                        Self.logger.notice("⚠️ [NIMService] logout 失败 \(String(describing: error), privacy: .private)")
                    } else {
                        Self.logger.info("🟢 [NIMService] 已 logout")
                    }
                    self?.connectionState = .idle
                    cont.resume()
                }
            }
        }
    }

    /// 刷新 token：等价于 logout + login。后端 token 主动续期后调。
    func refreshToken(account: String, newToken: String) async throws {
        await logout()
        try await login(account: account, token: newToken)
    }

    // MARK: - 进退聊天室（M1 helper；M3 / M5 让派对房 / 直播 manager 内部调）

    /// 进聊天室。前置：已登录。失败抛 `NIMServiceError.chatroomEnterFailed`。
    /// - Parameter retryCount: SDK 内部最大重试次数（与 NIMChatroomEnterRequest.retryCount 一致）
    @discardableResult
    func enterChatroom(roomId: String,
                       nickname: String,
                       retryCount: Int = 3) async throws -> NIMChatroom? {
        let request = NIMChatroomEnterRequest()
        request.roomId = roomId
        request.roomNickname = nickname
        request.retryCount = retryCount

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NIMChatroom?, Error>) in
            NIMSDK.shared().chatroomManager.enterChatroom(request) { error, chatroom, _ in
                Task { @MainActor in
                    if let error {
                        let mapped = NIMServiceError.chatroomEnterFailed(code: (error as NSError).code,
                                                                          message: error.localizedDescription)
                        Self.logger.error("🔴 [NIMService] enterChatroom 失败 \(roomId, privacy: .public) code=\((error as NSError).code, privacy: .public)")
                        cont.resume(throwing: mapped)
                    } else {
                        Self.logger.info("🟢 [NIMService] enterChatroom 成功 \(roomId, privacy: .public)")
                        cont.resume(returning: chatroom)
                    }
                }
            }
        }
    }

    /// 退聊天室。即便 SDK 报错也不抛——退房路径必须保证幂等。
    func exitChatroom(roomId: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            NIMSDK.shared().chatroomManager.exitChatroom(roomId) { error in
                if let error {
                    Self.logger.notice("⚠️ [NIMService] exitChatroom \(roomId, privacy: .public) error \(String(describing: error), privacy: .private)")
                }
                cont.resume()
            }
        }
    }

    // MARK: - MessageRouter 注册中心

    private var routers: [WeakRouter] = []

    /// 注册 router。重复注册同一实例安全（按 ObjectIdentifier 去重）。
    func registerRouter(_ router: any MessageRouter) {
        let id = ObjectIdentifier(router)
        routers.removeAll { $0.router.map(ObjectIdentifier.init) == id || !$0.isAlive }
        routers.append(WeakRouter(router))
        Self.logger.debug("[NIMService] registerRouter \(String(describing: type(of: router)), privacy: .public) total=\(self.routers.count, privacy: .public)")
    }

    /// 注销指定 router。
    func unregisterRouter(_ router: any MessageRouter) {
        let id = ObjectIdentifier(router)
        routers.removeAll { ($0.router.map(ObjectIdentifier.init) == id) || !$0.isAlive }
    }

    /// 注销所有 router（测试 / 全局 teardown）。
    func unregisterAllRouters() {
        routers.removeAll()
    }

    /// 主分发入口：按注册顺序调每个 router 的 `route`，第一个返回 true 的消费链路终止（短路 return）。
    /// 死引用 router 自动跳过并清扫。
    ///
    /// **场景过滤**：dispatch 入口先过 `IMSceneGate.allows` 闸门，drop 不相关场景的 sysMsg
    /// （chatroom 通道直接放行，由 router context guard 自治）。详见 IMSceneFilter / IMSceneGate。
    func dispatch(_ attachType: AttachType,
                  payload: [String: Any],
                  context: MessageContext) {
        // 场景闸门（业务正确性 + 性能双收益）
        guard IMSceneGate.shared.allows(attachType, context: context) else {
            Self.logger.debug("[NIMService] scene-drop \(attachType.raw, privacy: .public) ctx=\(String(describing: context), privacy: .public)")
            return
        }

        var hasDead = false
        for wrap in routers {
            guard let r = wrap.router else { hasDead = true; continue }
            if r.route(attachType, payload: payload, context: context) {
                if hasDead { routers.removeAll { !$0.isAlive } }
                return  // 短路 return：第一个消费即终止
            }
        }
        if hasDead { routers.removeAll { !$0.isAlive } }
        Self.logger.debug("[NIMService] dispatch \(attachType.raw, privacy: .public) ctx=\(String(describing: context), privacy: .public) — no router consumed")
    }

    // MARK: - 系统通知 dispatch helper

    /// 把 `NIMCustomSystemNotification.content` 解析为 attachType + payload 再分发。
    private func dispatchSystemNotification(_ notification: NIMCustomSystemNotification,
                                             context: MessageContext) {
        guard let content = notification.content,
              !content.isEmpty,
              let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logger.notice("[NIMService] sysMsg content 非法 JSON，sender=\(notification.sender ?? "?", privacy: .private)")
            return
        }
        var payload = dict
        // 周任务这类没有 roomId 的 CustomNotification 仍需能拒绝跨房迟到消息并做去重。
        // notificationId/timestamp 由 SDK 提供，不信任服务端 payload 中同名业务字段。
        payload["_nimCustomNotificationId"] = notification.notificationId
        payload["_nimCustomNotificationTimestamp"] = notification.timestamp
        payload["_nimSender"] = notification.sender ?? ""
        let attachType = AttachType(raw: payload["attachType"])
        dispatch(attachType, payload: payload, context: context)
    }

    // MARK: - 错误码分流

    /// 当错误触发 1004 / 1005 时广播 `.apiSessionInvalidated` 通知，与 APIClient 一致。
    fileprivate func notifyIfSessionInvalidating(_ err: NIMServiceError) {
        guard err.triggersSessionInvalidation else { return }
        let code: String = (err == .kickedOut) ? "1004" : "1005"
        NotificationCenter.default.post(
            name: .apiSessionInvalidated,
            object: nil,
            userInfo: ["source": "nim", "code": code, "message": err.errorDescription ?? ""]
        )
    }
}

// MARK: - 长连接状态

/// IM 长连接状态。
enum NIMConnectionState: String, Equatable {
    /// 未初始化 / 已 logout
    case idle
    /// 正在登录 / 重连中
    case connecting
    /// 已登录、长连接正常
    case connected
    /// 长连接因网络异常断开，SDK 自动重连中
    case reconnecting
    /// 已断开且未自动重连
    case disconnected
}

// MARK: - NIMSystemNotificationManagerDelegate（onReceiveCustomSystemNotification）

extension NIMService: NIMSystemNotificationManagerDelegate {

    /// 在线收到自定义系统通知 + 登录后的离线 backlog 补发。
    ///
    /// iOS NIMSDK 无 fetch custom 接口：SDK 内部缓存离线 backlog 并在 `loginOK` 后**通过本
    /// delegate 逐条**推送（H5 SDK 是 `syncSysMsgs` 批量事件）。当前 router 对 backlog 与
    /// 在线推送等价处理；如需差异化（批量补发不弹 toast 等），后续在 `MessageContext`
    /// 加 `isOffline` 维度而非新增 enum case。
    nonisolated func onReceive(_ notification: NIMCustomSystemNotification) {
        Task { @MainActor in
            self.dispatchSystemNotification(notification, context: .sysMsg)
        }
    }
}

// MARK: - NIMLoginManagerDelegate（重连 / 被踢 / 登录状态）

extension NIMService: NIMLoginManagerDelegate {

    /// IM 登录状态进度（SDK 内部重连也走这里）。
    ///
    /// **backlog grace**：.loginOK 时启用 10s 全放行窗口，覆盖离线/重连后 SDK 逐条推送的累积消息——
    /// backlog 是过去事件，不能按当前 active 场景过滤（参考 IMSceneFilter §设计核心 4）。
    nonisolated func onLogin(_ step: NIMLoginStep) {
        Task { @MainActor in
            switch step {
            case .linkFailed, .loseConnection:
                self.connectionState = .disconnected
                self.isSessionSyncOK = false
            case .linking, .logining, .syncing:
                self.connectionState = .connecting
            case .loginOK:
                self.connectionState = .connected
                // .loginOK 只表示 login 通道 OK；sessions 待 .syncOK 完成 (v2 修复)
            case .syncOK:
                // Sessions/漫游消息 sync 完成 —— MessageSessionStore 订阅此信号触发 fetchAll
                // + backlog grace 也移到此处（backlog 逐条 push 在 sync 阶段进行）
                self.isSessionSyncOK = true
                IMSceneGate.shared.openBacklogGrace()
            case .logout:
                self.connectionState = .idle
                self.isSessionSyncOK = false
            default:
                break
            }
            Self.logger.info("[NIMService] onLogin step=\(step.rawValue, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) syncOK=\(self.isSessionSyncOK, privacy: .public)")
        }
    }

    /// 被其他端踢下线 / 服务端踢下线。1004 触发全局 logout。
    nonisolated func onKickout(_ result: NIMLoginKickoutResult) {
        Task { @MainActor in
            Self.logger.notice("🔴 [NIMService] onKickout reason=\(result.reasonCode.rawValue, privacy: .public)")
            self.connectionState = .disconnected
            self.notifyIfSessionInvalidating(.kickedOut)
        }
    }

    /// 自动登录失败（多数情况是 1005 token 失效）。
    nonisolated func onAutoLoginFailed(_ error: Error) {
        Task { @MainActor in
            let code = (error as NSError).code
            Self.logger.error("🔴 [NIMService] onAutoLoginFailed code=\(code, privacy: .public)")
            let mapped = NIMServiceError.from(nsError: error as NSError, fallback: .tokenInvalid)
            self.connectionState = .disconnected
            self.notifyIfSessionInvalidating(mapped)
        }
    }
}
