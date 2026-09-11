import Foundation

/// 登录会话：登录 / 持久化 / 登出，并向业务接口提供 token。
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var user: LoginResult? {
        didSet {
            Self.updatePermissionSessionSnapshot(
                PermissionSessionState(
                    userType: UserTypeExperience.effectiveUserType(userInfo: user),
                    isAuthenticated: user != nil
                )
            )
        }
    }
    /// 每次建立或结束认证会话都会变化。View-owned 的账号数据 Store 用它隔离 SwiftUI
    /// keep-alive / identity 复用，不能仅凭相同 userId 判断仍是同一次登录。
    @Published private(set) var sessionGeneration = UUID()
    private(set) var authenticatedEmail: String?
    @Published var isLoading = false
    @Published var errorMessage = ""
    /// 本机最近成功登录的账号，最新记录在前，最多保留 5 条。
    @Published private(set) var recentLoginAccounts: [String] = []
    /// 登出后的 RTC/RTM/房间本地清理事务。下一次认证建立前必须等待它完成，避免旧账号
    /// 的延迟 leave/destroy 覆盖新账号刚启动的共享 Agora/NIM 状态。
    private var runtimeCleanupTask: Task<Void, Never>?
    private var runtimeCleanupGeneration: UInt64 = 0
    private var lastReportedAccountMode: Int?

    // MARK: - H M4：sysMsg 通道字段（C/J 期 UI 绑订）

    /// sysMsg -4 被关注通知累计计数（J 期 UI Toast / Badge 订阅）
    @Published private(set) var followIncrementCount: Int = 0
    /// sysMsg 58 主播审核状态变更最近一次 payload（applyStatus + content）
    @Published private(set) var lastAuditStatus: (applyStatus: Int, content: String)?

    // MARK: - P1-6（2026-07-14）主播审核弹窗

    /// 审核结果弹窗上下文（Identifiable → RootView 挂 .alert(item:)）。
    /// **多条 58 时**：SwiftUI `.alert(item:)` 契约新 item 覆盖旧 item —— iOS 主动简化"只保留最后一条"；
    /// H5 是 Vant showDialog 队列化按序展示。产品认可"最后一条已足够传达最新审核态"，不做队列化对齐。
    struct AuditAlertContext: Identifiable, Equatable {
        let id = UUID()
        let applyStatus: Int   // 0=passed, other=rejected
        let content: String    // passed 用固定 L10n，rejected 用后端 content 或 fallback
    }

    /// UI 层订阅；nil = 无弹窗，非 nil = 展示 alert
    @Published var auditAlert: AuditAlertContext?
    /// **仅 passed 分支**置 true → handleSessionInvalidated 顶部闸门吞 1004/1005
    /// （对齐 H5 `reviewPassedDialogShowing`：防审核通过后旧 token 立即失效弹窗盖掉审核弹窗）
    /// 拒绝分支 H5 无闸门（`reviewPassedDialogShowing` 只在 applyStatus=0 置 true），iOS 同步。
    @Published private(set) var auditDialogShowing: Bool = false

    // MARK: - A-2 新主播注册流程（spec §3.2 v3）

    /// login catch 1005 时携入；LoginView.onChange 消费 → push Register + reset
    @Published var pendingRegister: PendingRegister? = nil

    struct PendingRegister: Equatable {
        let email: String
        let password: String
    }

    /// 2026-07-16 重构：`PendingResubmit` / `needsResubmit` 已删除。原设计"未审核账号 login 时同步拉 mineInfo
    /// hydrate 后 push Register"违反 H5 蓝本(H5 未审核账号进 restricted 首屏,Resubmit 按钮才拉资料重填);
    /// 且未审核账号 `/api/user/getUserInfo` 后端返 404 让整条链失败。新设计:登录成功直接 applyLogin → RootView
    /// 按 `userType` 分流到 RestrictedTabView,MineRestrictedView.handleResubmit 才调 getAnchorInfo hydrate。

    /// v2 起 user 整体（含 token / imToken / loginUuid 等敏感字段）存 Keychain。
    /// v1（UserDefaults）→ v2 一次性迁移：load() 命中旧键时搬到 Keychain 并清旧。
    private let storeKey = "session.user.v2"
    private let legacyStoreKey = "session.user.v1"
    private let defaults = UserDefaults.standard
    private static let recentLoginAccountLimit = 5

    private nonisolated static let effectiveUserTypeSnapshotLock = NSLock()
    /// 启动时尚未建立 SessionStore.user，也必须先按 107 处理。登录用户写入后由 didSet
    /// 原子替换为该用户的实际派生模式；登出写回 107。
    private nonisolated(unsafe) static var storedPermissionSessionSnapshot = PermissionSessionState.loggedOut

    /// 非 UI 权限判定使用的线程安全模式快照。值已由登录响应中的资料视频解析为 107 / 2，
    /// 无用户时保持 107，不能再读取服务端原始 userType 代替该条件。
    nonisolated static var effectiveUserTypeSnapshot: Int? {
        effectiveUserTypeSnapshotLock.lock()
        defer { effectiveUserTypeSnapshotLock.unlock() }
        return storedPermissionSessionSnapshot.isAuthenticated
            ? storedPermissionSessionSnapshot.userType
            : 107
    }

    /// 权限桥的冷启动初值。它不访问 `SessionStore.shared`，因此可在 SessionStore 自身
    /// 初始化期间安全读取，避免两个 static singleton 互相初始化。
    nonisolated static var permissionSessionSnapshot: PermissionSessionState {
        effectiveUserTypeSnapshotLock.lock()
        defer { effectiveUserTypeSnapshotLock.unlock() }
        return storedPermissionSessionSnapshot
    }

    private nonisolated static func updatePermissionSessionSnapshot(_ session: PermissionSessionState) {
        effectiveUserTypeSnapshotLock.lock()
        storedPermissionSessionSnapshot = session
        effectiveUserTypeSnapshotLock.unlock()
    }

    /// 当前登录 token，供需要鉴权的接口使用
    var token: String? { user?.token }

    /// 新版本登录会直接保存邮箱；升级前已存在的登录态则从本人资料缓存回填一次。
    func emailForAccountDeletion() -> String? {
        let candidate = authenticatedEmail
            ?? AnchorInfoStore.shared.info?.email
            ?? AnchorInfoStore.shared.mine?.email
        guard let candidate else { return nil }
        let normalizedEmail = DeletedAccountRegistry.normalize(candidate)
        guard !normalizedEmail.isEmpty else { return nil }
        authenticatedEmail = normalizedEmail
        _ = KeychainStore.setString(normalizedEmail, for: KeychainKey.authenticatedEmail)
        return normalizedEmail
    }

    /// A 收尾：APIClient 抛 1004/1005 时通过 NotificationCenter 集中通知，这里挂 observer。
    /// observer 闭包持 weak self，避免循环引用；deinit 显式移除（双保险）。
    private var sessionInvalidatedObserver: NSObjectProtocol?

    init() {
        recentLoginAccounts = loadRecentLoginAccounts()
        load()
        sessionInvalidatedObserver = NotificationCenter.default.addObserver(
            forName: .apiSessionInvalidated,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleSessionInvalidated(userInfo: note.userInfo)
            }
        }
    }

    deinit {
        if let obs = sessionInvalidatedObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// 1004 挤下线 / 1005 token 失效：清会话 + UI 统一提示。
    /// 后端原始 message 和错误码只写隐私日志，不进入用户可见文案。
    private func handleSessionInvalidated(userInfo: [AnyHashable: Any]?) {
        let code = (userInfo?["code"] as? String) ?? ""
        let backend = (userInfo?["message"] as? String) ?? ""

        // HTTP/SAPI 使用主 token、NIM 使用 IM account 标记请求/回调来源。即使账号恰好在
        // 通知投递前完成切换，A 的迟到 1004/1005 也不能把 B 登出。
        if let originToken = userInfo?["originToken"] as? String,
           originToken != user?.token {
            AppLogger.auth.notice("[Session] stale invalidation ignored code=\(code, privacy: .public)")
            return
        }
        if let originNIMAccount = userInfo?["originNIMAccount"] as? String,
           originNIMAccount != user?.yxAccid {
            AppLogger.auth.notice("[Session] stale NIM invalidation ignored code=\(code, privacy: .public)")
            return
        }
        AppLogger.auth.error("session invalidated code=\(code, privacy: .public) backend=\(backend, privacy: .private)")

        // 用户可感知反馈（GlobalErrorBanner）**独立于闸门**触发 —— 对齐 H5 `request/index.ts:96-108`：
        // showNotify 弹 toast 与 logOut() 分开调用，闸门 `reviewPassedDialogShowing` 只跳过 logOut，
        // 用户仍能看到 "session expired" 提示。
        errorMessage = L10n.authErrorSessionInvalidated

        // P1-6 闸门：审核通过弹窗展示期间跳过 logout（对齐 H5 `logOut()` helper 内 return）
        // 防审核通过后旧 token 立即失效弹窗盖掉审核弹窗
        guard !auditDialogShowing else {
            AppLogger.auth.notice("[Session] logout suppressed by audit dialog; banner still shown; code=\(code, privacy: .public)")
            return
        }
        logout()
    }

    func login(email: String, password: String) async {
        guard !isLoading else { return }
        let email = EmailAccountRules.normalized(email)
        guard EmailAccountRules.validEmail(email) else { errorMessage = L10n.Email.text("invalidEmail"); return }
        guard EmailAccountRules.validLoginPassword(password) else { errorMessage = L10n.Email.text("loginPasswordRule"); return }
        let generation = sessionGeneration
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        await waitForRuntimeCleanup()

        let pwd = CryptoUtil.loginPassword(password)
        do {
            let data = try await APIClient.shared.post(
                "/api/user/v5/login",
                body: ["email": email, "password": pwd],
                token: "",
                suppressCodes: EmailAccountRules.handledCodes.union(["1005"])
            )
            guard sessionGeneration == generation else { return }
            if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
                errorMessage = L10n.Email.text("startRegister")
                pendingRegister = PendingRegister(email: email, password: "")
                RegisterAnalytics.report(.signUp)
                return
            }
            let result = try LoginResult.decodeNetworkResponse(from: data, source: "login")
            guard result.userType != 9 else { errorMessage = L10n.Email.text("agentBlocked"); return }
            guard let token = result.token, !token.isEmpty else {
                errorMessage = L10n.authErrorNoToken
                return
            }

            // 登录接口本次返回的媒体是最高优先级输入；字段缺失时，读取同一 userId
            // 的版本化模式缓存。两者都缺失时保守进入 107。
            //
            // 保留 pendingRegisterPassword Keychain 保存:MineRestrictedView.handleResubmit 拉 mineInfo 后
            // RegisterStore.hydrate 需要 cachedPassword 兜底(H5 register 提交仍要带明文密码走 MD5)。
            // logout 时清此 Keychain(既有逻辑 line 269 已实现)。
            _ = KeychainStore.setString(password, for: KeychainKey.pendingRegisterPassword)

            guard await applyLogin(result, email: email) else {
                errorMessage = L10n.authErrorNoToken
                return
            }
            reportLoginOutcome(account: email, outcome: "进入应用")
        } catch let e as APIError {
            AppLogger.auth.error("login APIError code=\(e.code, privacy: .public) message=\(e.message, privacy: .private)")
            guard sessionGeneration == generation else { return }
            errorMessage = e.code == "1005" ? L10n.Email.text("invalidLogin") : L10n.Email.error(e)
        } catch {
            guard sessionGeneration == generation, !GlobalErrorBannerNotify.isCancellation(error) else { return }
            errorMessage = L10n.Email.error(error)
        }
    }

    private func reportLoginOutcome(account: String, outcome: String) {
        let normalized = DeletedAccountRegistry.normalize(account)
        AnalyticsTracker.trackBehavior("登录行为", properties: [
            "account": normalized,
            "login_status": outcome
        ])
    }

    /// 为新会话准备首帧权限模式。完整登录/注册媒体优先；媒体缺失时读取同 userId
    /// 的双向模式缓存。无可信缓存时 fail-closed 到 107。
    private func resolvingInitialPermissionMode(
        for result: LoginResult
    ) -> (user: LoginResult, source: String) {
        let cachedPermissionVideoURLs = AnchorInfoStore.shared.cachedPermissionVideoURLs(
            for: result.userId
        )
        let cachedPlaceholderMatched = ReviewAccountModeRegistry.placeholderMatched(
            for: result.userId
        )
        #if DEBUG
        let profileCacheDescription = cachedPermissionVideoURLs.map {
            "present(\($0.count))"
        } ?? "missing"
        let modeCacheDescription = cachedPlaceholderMatched.map(String.init(describing:))
            ?? "missing"
        AppLogger.auth.info(
            "[PermissionModeLookup] userId=\(result.userId ?? -1, privacy: .private) sessionResolved=\(result.resolvedReviewPlaceholderMatch != nil, privacy: .public) profileCache=\(profileCacheDescription, privacy: .public) modeCache=\(modeCacheDescription, privacy: .public)"
        )
        #endif
        let resolved = result.resolvingInitialPermissionMode(
            cachedPermissionVideoURLs: cachedPermissionVideoURLs,
            cachedPlaceholderMatched: cachedPlaceholderMatched
        )
        if let matched = resolved.user.resolvedReviewPlaceholderMatch {
            let stored = ReviewAccountModeRegistry.record(
                userID: resolved.user.userId,
                placeholderMatched: matched
            )
            if !stored {
                AppLogger.auth.error("[PermissionModeCache] write failed source=\(resolved.source, privacy: .public)")
            }
            #if DEBUG
            AppLogger.auth.info("[PermissionModeCache] source=\(resolved.source, privacy: .public) placeholder=\(matched, privacy: .public) stored=\(stored, privacy: .public)")
            #endif
        }
        return resolved
    }

    /// 全新安装或该账号首次在本机登录时，登录响应可能不带 `picList/videos`，本机也没有
    /// 模式缓存。此时必须在发布登录态前用本次 token 拉取本人资料，否则首帧会按 107
    /// 构建，并一直保持到下一次启动。请求失败、owner 不匹配或媒体字段不可信时继续
    /// fail-closed 到 107，绝不使用服务端原始 userType 猜测模式。
    private func resolvingInteractivePermissionMode(
        for result: LoginResult,
        token: String
    ) async -> (user: LoginResult, source: String) {
        let initial = resolvingInitialPermissionMode(for: result)
        guard initial.source == "unresolved",
              let expectedUserID = result.userId,
              expectedUserID > 0 else {
            return initial
        }

        do {
            let profile = try await ProfileService.getAnchorInfo(token: token)
            guard profile.userId == expectedUserID else {
                AppLogger.auth.error(
                    "[PermissionModePrelogin] owner mismatch expected=\(expectedUserID, privacy: .private) actual=\(profile.userId ?? -1, privacy: .private); defaulting to 107"
                )
                return initial
            }
            guard let permissionVideoURLs = profile.permissionVideoEvidence else {
                AppLogger.auth.notice(
                    "[PermissionModePrelogin] media unresolved userId=\(expectedUserID, privacy: .private); defaulting to 107"
                )
                return initial
            }

            let resolved = initial.user.applyingFreshProfilePermissionEvidence(
                permissionVideoURLs
            )
            let placeholderMatched = resolved.resolvedReviewPlaceholderMatch == true
            let stored = ReviewAccountModeRegistry.record(
                userID: expectedUserID,
                placeholderMatched: placeholderMatched
            )
            if !stored {
                AppLogger.auth.error("[PermissionModePrelogin] cache write failed")
            }
            #if DEBUG
            AppLogger.auth.info(
                "[PermissionModePrelogin] resolved userId=\(expectedUserID, privacy: .private) mediaCount=\(permissionVideoURLs.count, privacy: .public) placeholder=\(placeholderMatched, privacy: .public) stored=\(stored, privacy: .public)"
            )
            #endif
            return (
                resolved,
                placeholderMatched ? "prelogin-profile-review" : "prelogin-profile-full"
            )
        } catch {
            AppLogger.auth.notice(
                "[PermissionModePrelogin] request failed userId=\(expectedUserID, privacy: .private); defaulting to 107 error=\(String(describing: error), privacy: .private)"
            )
            return initial
        }
    }

    /// 登录 / 注册成功后的公共副作用链——单一入口，避免 login() 与 register.submit() 分岔重复。
    ///
    /// A-2 spec §3.3 v3 MAJOR-4 抽出：
    /// 0. token 空守卫（`result.token` 空/nil 返 false，调用方展示错误文案，不落地任何 state）
    /// 1. user = result；isLoggedIn = true；save()（Keychain 落 v2 store + 内部设 AuthToken.value）
    /// 2. Fire AnchorInfoStore.shared.refresh()（session-scoped rule 双入口之 login refresh）
    /// 3. Fire AppConfigStore.shared.activate()（同）
    /// 4. 打日志 [LOGIN OK]
    ///
    /// 副作用：**不设** errorMessage（成功路径）；**不清** pendingRegister（由 View 层消费清）
    /// - returns: true = 登录状态已建立；false = token 缺失，调用方决定文案
    @discardableResult
    func applyLogin(_ result: LoginResult, email: String) async -> Bool {
        let expectedGeneration = sessionGeneration
        await waitForRuntimeCleanup()
        guard sessionGeneration == expectedGeneration else { return false }
        guard let token = result.token, !token.isEmpty else { return false }
        let normalizedEmail = DeletedAccountRegistry.normalize(email)
        guard !normalizedEmail.isEmpty else { return false }
        // 每次交互式登录都重新计算：本次响应优先，缺失时只读取当前 userId 的模式缓存；
        // 全新账号连缓存也没有时，在发布登录态前补拉本人资料，避免先展示 107 再热切。
        let initialMode = await resolvingInteractivePermissionMode(for: result, token: token)
        guard sessionGeneration == expectedGeneration else { return false }
        let sessionResult = initialMode.user
        // 先失效上一账号的资料请求，再发布当前登录用户。
        AnchorInfoStore.shared.hydrateFromLogin(sessionResult)
        user = sessionResult
        let effectiveUserType = UserTypeExperience.effectiveUserType(userInfo: sessionResult)
        SelfPermissionBridge.shared.synchronizeImmediately(PermissionSessionState(
            userType: effectiveUserType,
            isAuthenticated: true
        ))
        // 会话代际必须在 user + 权限快照就绪后发布，避免 View 用上一账号模式重建。
        let loginGeneration = UUID()
        sessionGeneration = loginGeneration
        authenticatedEmail = normalizedEmail
        _ = KeychainStore.setString(normalizedEmail, for: KeychainKey.authenticatedEmail)
        isLoggedIn = true
        reportAccountModeIfNeeded(effectiveUserType)
        save()   // 内部会 AuthToken.value = token
        recordRecentLoginAccount(normalizedEmail)
        AnalyticsTracker.login(userId: sessionResult.userId)
        CrashReporter.setUser(userID: sessionResult.userId)
        #if DEBUG
        AppLogger.auth.info("[LOGIN OK] userId=\(sessionResult.userId ?? -1, privacy: .private) modeSource=\(initialMode.source, privacy: .public) modeResolved=\(sessionResult.isReviewModeResolved, privacy: .public) placeholder=\(sessionResult.resolvedReviewPlaceholderMatch == true, privacy: .public) permissionMedia=\(sessionResult.permissionModeMediaURLs.count, privacy: .public) effectiveUserType=\(effectiveUserType ?? -1, privacy: .public) → fire profile/config refresh")
        #else
        AppLogger.auth.info("[LOGIN OK] userId=\(sessionResult.userId ?? -1, privacy: .private) → fire profile/config refresh")
        #endif
        // 2026-07-16：对齐 H5 `loginSuccess → setMineInfo(res)`——用登录响应直接注入 mine，
        // 不再依赖 `/api/user/getUserInfo`（后端 404）。getAnchorInfo 结果稍后由 refresh() 覆盖 info。
        Task {
            await self.refreshAuditStatus(
                expectedGeneration: loginGeneration,
                expectedUserID: sessionResult.userId
            )
        }
        // H-3：AppConfigStore 横断基建（视频通话权限 / 翻译 key / 回复积分 config），
        // 挂 session-scoped rule 双入口之 login refresh；一次拉 4 key 逗号 join
        Task { await AppConfigStore.shared.activate() }
        synchronizePermissionScopedServices()
        // sapi（vvi 派对房/背包等链路）token 主动预取，对齐 H5 login/index.vue:86 `await getBagShopToken()`
        // forceRefresh=true 保证换账号后不复用上个账号残留（虽 logout 已 clear，双保险）
        Task { try? await SapiTokenStore.shared.ensureValid(forceRefresh: true) }
        _ = token   // 消除 unused warning（token 是 guard 的语义约束，不需要真使用）
        return true
    }

    /// 全局 P2P delegate 是会话级资源。107 禁用 P2P 后必须在 SDK 层解除注册，而不只是
    /// 在回调里丢弃消息；普通账号仍沿用既有登录和冷启动恢复行为。
    private func synchronizeGlobalP2PObserver(for userType: Int?) {
        if UserPermissionMapping.blocked(for: userType).contains(.directMessages) {
            GlobalP2PMessageObserver.shared.deactivate()
        } else {
            GlobalP2PMessageObserver.shared.activate()
        }
    }

    /// MessageSessionStore 是懒加载单例；这里只通知已经创建的实例，不能让 107 冷启动因为
    /// 权限同步而创建 NIMSessionAdapter。登录、冷启动和审核角色切换共用这一入口。
    private func synchronizeMessageSessionStore(for userType: Int?) {
        let isAllowed = !UserPermissionMapping.blocked(for: userType).contains(.directMessages)
        MessageSessionStore.updateSharedDirectMessagesCapability(isAllowed: isAllowed)
        if !isAllowed {
            ReplyPointsStore.shared.clear()
        }
    }

    /// 按当前有效账号模式同步非 UI 资源；DEBUG 覆盖与真实账号共用同一权限结果。
    func synchronizePermissionScopedServices() {
        guard let user else { return }
        // SessionStore.user 是本次认证的权威来源。权限桥可能仍处在上一账号的 UI 发布帧，
        // 会话副作用不能优先读取该旧快照。
        let userType = UserTypeExperience.effectiveUserType(userInfo: user)
        synchronizeGlobalP2PObserver(for: userType)
        synchronizeMessageSessionStore(for: userType)
        let blocked = UserPermissionMapping.blocked(for: userType)
        if blocked.contains(.giftSending) || blocked.contains(.virtualItems) {
            GiftCatalogCache.shared.clear()
        }
        preloadPublicAssetsIfNeeded(for: userType)
    }

    /// 登录或冷启动恢复后后台预拉取 CDN 应用资源。
    /// 下载不阻塞登录；107 不拉取无权限的运营图片接口，但同样缓存其 CDN 基础资源。
    private func preloadPublicAssetsIfNeeded(for userType: Int?) {
        Task { @MainActor in
            if userType == 107 {
                AppPictureStore.shared.clear()
            } else {
                await AppPictureStore.shared.preloadPublicAssets()
            }
            await URLDiskCache.prefetch(
                urls: CDNAssetURL.publicAssetURLs(isPartyOnly: userType == 107)
            )
        }
    }

    func logout() {
        // P1-6：防未来新调用路径经 logout 时残留 audit alert / 闸门
        // （当前链 confirmAuditAlert 已先手清 auditDialogShowing；这里是防御式绑生命周期）
        auditAlert = nil
        auditDialogShowing = false
        followIncrementCount = 0
        lastAuditStatus = nil
        AnalyticsTracker.logout()
        CrashReporter.clearUser()
        MatchStore.shared.resetForLogout()
        MatchPopupCoordinator.shared.resetForLogout()
        // Phase C：任务中心页折叠态 per-user 清理(session-scoped rule 双入口之 logout clear)
        // 必须在 user = nil 之前调 —— 需要 userId 定位 UserDefaults key
        // 直接内联删除 UserDefaults key(避免跨 module 依赖 —— TaskCenterCollapseStore 是新 module,
        // pbxproj 未登记时会 fail;内联安全兼容首次 build)
        if let uid = user?.userId {
            let uidStr = String(uid)
            for cycle in ["DAILY", "WEEKLY"] {
                UserDefaults.standard.removeObject(forKey: "taskCenter.collapse.\(cycle).\(uidStr)")
            }
            for section in ["tycoon", "points"] {
                UserDefaults.standard.removeObject(forKey: "taskCenter.weeklySection.\(section).\(uidStr)")
            }
        }
        let logoutUser = user
        AppLogger.auth.info("[PermissionModeSession] event=logout userId=\(logoutUser?.userId ?? -1, privacy: .private) oldMode=\(UserTypeExperience.effectiveUserType(userInfo: logoutUser) ?? -1, privacy: .public) nextDefaultMode=107")
        user = nil
        isLoggedIn = false
        SelfPermissionBridge.shared.synchronizeImmediately(.loggedOut)
        // 先撤销认证用户和权限，再让仍被 SwiftUI keep-alive 的账号级 View Store 换代。
        sessionGeneration = UUID()
        authenticatedEmail = nil
        errorMessage = ""
        KeychainStore.remove(for: storeKey)
        KeychainStore.remove(for: KeychainKey.authenticatedEmail)
        defaults.removeObject(forKey: legacyStoreKey)   // 清掉历史残留
        AuthToken.value = nil
        // 轻量 WebView 与通用 H5 都使用默认 website data store。登出时清除，避免
        // 下一账号继承前一账号的页面缓存、LocalStorage 或 cookie。
        H5WebSession.clear()
        // sapi（vvi 派对房/背包等链路）的 auth_token 与主 token 是两套独立生命周期，需同步清
        SapiTokenStore.shared.clear()
        // 同步清空主播信息缓存,避免下个账号登录后看到上个号的残留
        AnchorInfoStore.shared.clear()
        // 账号级共享 Store 必须与认证生命周期一起失效；View dismount 不是可靠清理边界。
        WishSettingSharedStore.shared.reset()
        ReplyPointsStore.shared.clear()
        GiftMarqueeStore.shared.clear()
        AnchorInfoConsumerBridge.shared.clear()
        // 图片缓存也清掉:上个号的头像/相册/视频缩略不应被下个号看到
        ImageCache.shared.clear()
        // IM 场景闸门清空（防 A 账号场景残留误导 B 账号过滤逻辑）
        IMSceneGate.shared.resetAll()
        // P2P 会话列表只停已创建的 shared Store，避免 107 从未打开消息页时登出反而初始化 NIM adapter。
        // 暂停同时取消 20s 轮询并阻止后续 connection 回调重拉旧会话。
        MessageSessionStore.updateSharedDirectMessagesCapability(isAllowed: false)
        // v5.4 缓存审计补漏（logout 清理漏斗完整性）：
        // G1: station 已读态跨账号串扰 — 若 A 已读 mail id=X，B 收到同 id 会误判已读永远漏红点
        UserDefaults.standard.removeObject(forKey: "hily.station.lastReadId")
        // 启动弹窗使用独立已读键；同样必须按会话清理，避免下一账号继承上一账号的已读状态。
        UserDefaults.standard.removeObject(forKey: "hily.station.launchPopup.readId")
        // G2: 客服 yxAccId 缓存 — clear() 方法早已存在但 logout 从未调用，导致 A 客服 imId 泄漏到 B
        CustomerServiceIdStore.shared.clear()
        // G3: 在线状态 store — 未清则 A 的 forcedBusy=true / userSetOnline=false 残留到 B 首屏
        OnlineStatusStore.shared.clear()
        // H-2 v2: Flame 通道 B 关注列表 24h 缓存 — 跨账号必须清（A 关注列表泄漏到 B 会误判 Flame）
        FollowUserListService.shared.clear()
        // H-3: AppConfigStore 横断基建（session-scoped rule 双入口之 logout clear）
        // 未清则 A 账号的 achorHideButton / 微软 key 残留到 B 首屏，通话按钮显隐 / 翻译走错 key
        AppConfigStore.shared.clear()
        // 运营图片本身是公共文件缓存，但接口配置需按新账号重新拉取。
        AppPictureStore.shared.clear()
        // H-5 v2: 礼物列表 in-memory 缓存（跨场景 party/live/call）— session-scoped rule 应用
        // 未清则 A 账号的礼物架数据/余额残留到 B 首屏面板（余额值尤其敏感 · session 隔离要求）
        GiftCatalogCache.shared.clear()
        // v24（B1 · .claude/rules/session-scoped-store-refresh.md 双入口之 logout clear）：
        // 活跃大 R 进房 Toast 去重集清空，防同账号短时 logout+relogin 后当天已提示的大 R 不再提示
        ActiveTycoonToastCenter.shared.clear()
        // Batch 6.1.3: 全局 P2P 消息 delegate 解注册（session-scoped rule 双入口之 logout deactivate）
        // 防跨账号后 B 账号仍触发 A 账号的合成路径
        GlobalP2PMessageObserver.shared.deactivate()
        // Invite 103/104 卡片队列与当前账号绑定，防止下一账号收到前一账号的邀请引导。
        InviteMessageCenter.shared.clear()
        // A-2: 注册表单短态 + 短期 Keychain 密码清（session-scoped rule 应用；防止 A 账号未完成注册的表单数据泄漏到 B）
        RegisterStore.shared.reset()
        _ = KeychainStore.remove(for: KeychainKey.pendingRegisterPassword)
        pendingRegister = nil
        // Bug fix 2026-07-10：注册完成后 logout 会跳回注册页而非登录页 —— NavigationStack path 残留 [.basicInfo, .required, ...]，
        // RootView 分流回 LoginView 时 LoginView 顶层 NavigationStack 用 pathHolder.path 恢复到最后一次的注册栈。
        // 修：logout 时清 path 让下次进 LoginView 从根开始
        RegisterPathHolder.shared.reset()
        beginRuntimeCleanup()
    }

    /// RootView 的登出分支与下一次登录共用同一清理事务，禁止各自启动一套 SDK teardown。
    func waitForRuntimeCleanup() async {
        guard let task = runtimeCleanupTask else { return }
        let generation = runtimeCleanupGeneration
        await task.value
        if runtimeCleanupGeneration == generation {
            runtimeCleanupTask = nil
        }
    }

    private func beginRuntimeCleanup() {
        guard runtimeCleanupTask == nil else { return }
        runtimeCleanupGeneration &+= 1
        let generation = runtimeCleanupGeneration

        // 在首个 await 前同步撤销所有新启动资格。
        WSHeartbeat.shared.stop()
        AutoOfflineMonitor.shared.stop()
        NIMOnlineKeeper.shared.stop()
        CallStore.shared.invalidatePendingStart()
        MatchStore.shared.stopForSessionEnd()

        let task = Task { @MainActor in
            await LiveSessionRegistry.shared.stopForSessionEnd()
            await RobotCallStore.shared.resetForSessionEnd()
            await PartyStore.shared.resetForSessionEnd()
            PartyStore.shared.detachChatRouter()
            await CallStore.shared.stop(destroySharedAgoraEngine: true)
        }
        runtimeCleanupTask = task

        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.runtimeCleanupGeneration == generation else { return }
            self.runtimeCleanupTask = nil
            AppLogger.auth.info("[Session] runtime cleanup completed generation=\(generation, privacy: .public)")
        }
    }

    /// 模拟删除成功后的本地收口必须与退出登录完全一致，避免残留账号缓存或认证信息。
    func completeLocalAccountDeletion() {
        logout()
    }

    // MARK: - H M4：sysMsg 通道入口（spec §3.1 / H 校验清单 §1.1.2 A 表）

    /// sysMsg -4：被关注通知。仅累加 @Published 计数，UI 订阅做 Toast / Badge。
    func incrementFollow() {
        followIncrementCount += 1
        AppLogger.auth.info("[Session] follow incr total=\(self.followIncrementCount, privacy: .public)")
    }

    /// sysMsg 58：主播审核状态变更（applyStatus 0=通过 / 非 0=拒绝 / -1=payload 缺失）。
    /// - **0 通过**：弹固定英文 alert → 用户 tap Confirm → logout 回登录页；期间闸门吞 1004/1005
    /// - **非 0 拒绝**：弹 payload.content（空则 fallback）→ 用户 tap Confirm → 仅 dismiss 无 side effect
    ///   （H5 是 `isHost=true + forcePageReload`；iOS 无 reload 概念，主播态由 isLoggedIn 已维持）
    /// - **-1 缺失**：warning log return，不弹
    ///
    /// P1-6（2026-07-14）从原"仅落 @Published 字段"扩展为 UI 联动 + logout 联动。
    func handleAuditStatus(applyStatus: Int, content: String) {
        guard !UserTypeExperience.isPartyOnly(
            UserTypeExperience.effectiveUserType(userInfo: user)
        ) else {
            AppLogger.auth.notice("[Session] audit status ignored in Party-only mode")
            return
        }
        lastAuditStatus = (applyStatus, content)
        AppLogger.auth.notice("[Session] audit status=\(applyStatus, privacy: .public) content=\(content, privacy: .public)")

        if applyStatus == -1 {
            AppLogger.auth.notice("[Session] audit payload missing applyStatus; skip alert")
            return
        }

        if applyStatus == 0 {
            auditAlert = AuditAlertContext(applyStatus: 0, content: L10n.auditPassedMessage)
            auditDialogShowing = true
        } else {
            let msg = content.isEmpty ? L10n.auditRejectedFallback : content
            auditAlert = AuditAlertContext(applyStatus: applyStatus, content: msg)
        }
    }

    /// 已登录冷启动 / 受限首屏刷新用户信息，对齐 H5 App.vue.isLogin()
    /// 每次启动拉 getAnchorInfo → setMineInfo 覆盖用户资料及 valid/onReview/banAlways/... 字段。
    ///
    /// iOS 侧 LoginResult 是首次登录快照,若审核态在服务端变化(通过/被拒/临时封禁)本地不知情。sysMsg 58 push 只在
    /// App 在线时能收到;冷启动或长时间离线的账号必须主动拉一次审核态确认。
    ///
    /// 数据源:AnchorInfoStore.shared.refresh() 拉 getAnchorInfo → info?.userType/valid/onReview/banAlways/bannedSubType/type
    /// 同步回 self.user (LoginResult),save() 持久化到 Keychain。
    ///
    /// 失败静默:refresh 内部 non-fatal，且会为 UI 保留旧 info。资料媒体只更新该账号
    /// 下次认证所用的模式缓存；本次会话权限由认证建立时的登录响应/同账号缓存固定，
    /// 不因异步资料回包再次切换界面能力。
    func refreshAuditStatus(
        expectedGeneration: UUID? = nil,
        expectedUserID: Int? = nil
    ) async {
        let requestGeneration = expectedGeneration ?? sessionGeneration
        let requestUserID = expectedUserID ?? user?.userId
        guard let requestUserID else {
            AppLogger.auth.notice("[Session] refreshAuditStatus skip: no expected user")
            return
        }

        await AnchorInfoStore.shared.refresh()
        guard isLoggedIn,
              sessionGeneration == requestGeneration,
              let current = user,
              current.userId == requestUserID else {
            AppLogger.auth.notice("[Session] profile refresh discarded: stale session")
            return
        }
        guard let info = AnchorInfoStore.shared.freshAnchorInfo(for: requestUserID) else {
            AppLogger.auth.notice("[Session] profile refresh skipped: no fresh owner data userId=\(requestUserID, privacy: .private)")
            return
        }
        // 只同步审核提示字段；角色与权限模式都由认证建立时的登录响应/同账号缓存固定。
        // 避免资料接口中的 userType 或媒体在本次会话内改变 Root 路由与能力集合。
        let refreshed = LoginResult(
            userId: current.userId,
            token: current.token,
            loginUuid: current.loginUuid,
            yxAccid: current.yxAccid,
            imToken: current.imToken,
            userType: current.userType,
            nickname: info.nickname ?? current.nickname,
            icon: info.icon ?? current.icon,
            userLevel: info.userLevel ?? current.userLevel,
            chatBubble: info.chatBubble ?? current.chatBubble,
            chatBubbleGuardianLevel: info.chatBubbleGuardianLevel ?? current.chatBubbleGuardianLevel,
            valid: info.valid ?? current.valid,
            onReview: info.onReview ?? current.onReview,
            banAlways: info.banAlways ?? current.banAlways,
            bannedSubType: info.bannedSubType ?? current.bannedSubType,
            type: info.type ?? current.type,
            // 保留认证建立时的媒体证据，确保资料刷新不会热切本次会话权限。
            picList: current.picList,
            videos: current.videos,
            reviewPlaceholderVideoMatched: current.reviewPlaceholderVideoMatched,
            reviewModeResolved: current.reviewModeResolved,
            reviewModeEvidenceVersion: current.reviewModeEvidenceVersion
        )

        user = refreshed
        reportAccountModeIfNeeded(UserTypeExperience.effectiveUserType(userInfo: refreshed))
        save()
        AppLogger.auth.info("[Session] refreshAuditStatus OK userType=\(refreshed.userType ?? -1) valid=\(refreshed.valid ?? -1) onReview=\(refreshed.onReview == true) banAlways=\(refreshed.banAlways == true)")
    }

    /// 账号权限模式切换（例如全开放主播 ↔ 107 Party-only）。这不是 Party 房间模板切换。
    private func reportAccountModeIfNeeded(_ mode: Int?) {
        guard let mode, mode != lastReportedAccountMode else { return }
        lastReportedAccountMode = mode
        AnalyticsTracker.trackBehavior("账号模式切换", properties: ["model": mode])
    }

    /// RootView `.alert(item:)` dismissButton 回调；根据 applyStatus 分流 logout / refresh。
    /// SwiftUI 会在 tap 后自动置 auditAlert=nil（`.alert(item:)` 契约），本方法不再手动置 nil 避免双写。
    func confirmAuditAlert(_ ctx: AuditAlertContext) {
        if ctx.applyStatus == 0 {
            auditDialogShowing = false
            logout()
        } else {
            // 2026-07-17 修:拒绝分支改调 refreshAuditStatus(而非 AnchorInfoStore.refresh)。
            // 对齐 H5 forcePageReload() 语义(强制重新拉 mineInfo 覆盖 valid/onReview/type 字段)——
            // 只调 AnchorInfoStore.refresh() 仅刷新 info 字段,**不会更新 SessionStore.user (LoginResult)** 里的
            // 审核字段;banner 派生源是 session.user (RootView.isRestricted / RestrictedStatusBanner 都读它),
            // 不同步就永远看不到新审核态。refreshAuditStatus 内部 anchorStore.refresh + 同步字段到 user + save。
            Task { await refreshAuditStatus() }
        }
    }

    // MARK: - 持久化

    /// Refresh authentication in place: do not restart IM/RTC or change account permissions.
    func applyEmailRebind(token: String, email: String, password: String, expectedGeneration: UUID) throws {
        guard sessionGeneration == expectedGeneration, var updated = user,
              let userID = updated.userId, !token.isEmpty else { throw CancellationError() }
        updated.token = token
        let data = try JSONEncoder().encode(updated)
        let persisted = KeychainStore.setData(data, for: storeKey)
        // The server already invalidated the old token: always replace the in-memory identity.
        user = updated
        let tokenSaved = AuthToken.update(token)
        authenticatedEmail = EmailAccountRules.normalized(email)
        let emailSaved = KeychainStore.setString(authenticatedEmail ?? "", for: KeychainKey.authenticatedEmail)
        let passwordSaved = KeychainStore.setString(password, for: KeychainKey.pendingRegisterPassword)
        recordRecentLoginAccount(authenticatedEmail ?? "")
        AnchorInfoStore.shared.updateVerifiedEmail(authenticatedEmail ?? "", userID: userID)
        if !persisted || !tokenSaved || !emailSaved || !passwordSaved {
            // Keep the working new session but tell the user that automatic restoration is unavailable.
            GlobalErrorBannerNotify.post(message: L10n.Email.text("storageWarning"), path: "/api/anchor/email/rebind/submit")
        }
    }

    private func save() {
        guard let user, let data = try? JSONEncoder().encode(user) else { return }
        KeychainStore.setData(data, for: storeKey)
        AuthToken.value = user.token   // 供 APIClient 自动附带
    }

    func removeRecentLoginAccount(_ account: String) {
        let normalizedAccount = DeletedAccountRegistry.normalize(account)
        guard !normalizedAccount.isEmpty else { return }

        let updated = recentLoginAccounts.filter { $0 != normalizedAccount }
        guard updated.count != recentLoginAccounts.count else { return }
        recentLoginAccounts = updated
        persistRecentLoginAccounts()
    }

    private func recordRecentLoginAccount(_ account: String) {
        let normalizedAccount = DeletedAccountRegistry.normalize(account)
        guard !normalizedAccount.isEmpty else { return }

        recentLoginAccounts = (
            [normalizedAccount]
                + recentLoginAccounts.filter { $0 != normalizedAccount }
        )
        .prefix(Self.recentLoginAccountLimit)
        .map { $0 }
        persistRecentLoginAccounts()
    }

    private func loadRecentLoginAccounts() -> [String] {
        guard let data = KeychainStore.getData(for: KeychainKey.recentLoginAccounts) else {
            return []
        }
        guard let storedAccounts = try? JSONDecoder().decode([String].self, from: data) else {
            AppLogger.auth.error("[RecentLogin] unable to decode local account list")
            return []
        }

        var seen = Set<String>()
        return storedAccounts.compactMap { account in
            let normalizedAccount = DeletedAccountRegistry.normalize(account)
            guard !normalizedAccount.isEmpty, seen.insert(normalizedAccount).inserted else {
                return nil
            }
            return normalizedAccount
        }
        .prefix(Self.recentLoginAccountLimit)
        .map { $0 }
    }

    private func persistRecentLoginAccounts() {
        guard !recentLoginAccounts.isEmpty else {
            _ = KeychainStore.remove(for: KeychainKey.recentLoginAccounts)
            return
        }
        guard let data = try? JSONEncoder().encode(recentLoginAccounts) else { return }
        if !KeychainStore.setData(data, for: KeychainKey.recentLoginAccounts) {
            AppLogger.auth.error("[RecentLogin] unable to save local account list")
        }
    }

    private func load() {
        authenticatedEmail = KeychainStore.getString(for: KeychainKey.authenticatedEmail)
            .map(DeletedAccountRegistry.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
        // v2 路径：Keychain
        if let data = KeychainStore.getData(for: storeKey),
           let u = try? JSONDecoder().decode(LoginResult.self, from: data),
           let t = u.token, !t.isEmpty {
            let initialMode = resolvingInitialPermissionMode(for: u)
            let restoredUser = initialMode.user
            AnchorInfoStore.shared.hydrateFromLogin(restoredUser, preserveCachedSnapshot: true)
            user = restoredUser
            isLoggedIn = true
            reportAccountModeIfNeeded(UserTypeExperience.effectiveUserType(userInfo: restoredUser))
            save()
            AnalyticsTracker.login(userId: restoredUser.userId)
            CrashReporter.setUser(userID: restoredUser.userId)
            // 冷启动恢复同样按账号能力决定是否注册 P2P observer，避免 107 在后台收到私聊事件。
            synchronizePermissionScopedServices()
            // H-3: 冷启动 restore 时也 activate AppConfigStore(rule session-scoped-store-refresh 双入口)
            // 否则 microsoftTranslatorKey/Area 为 nil,翻译 tap 会 toast "Translation config missing"
            Task { await AppConfigStore.shared.activate() }
            #if DEBUG
            AppLogger.auth.info("[SESSION RESTORE] store=v2 userId=\(restoredUser.userId ?? -1, privacy: .private) modeSource=\(initialMode.source, privacy: .public) modeResolved=\(restoredUser.isReviewModeResolved, privacy: .public) placeholder=\(restoredUser.resolvedReviewPlaceholderMatch == true, privacy: .public) permissionMedia=\(restoredUser.permissionModeMediaURLs.count, privacy: .public) effectiveUserType=\(UserTypeExperience.effectiveUserType(userInfo: restoredUser) ?? -1, privacy: .public)")
            #endif
            // 后台刷新资料和审核状态，但不改写本次恢复时已经确定的权限模式。
            let restoreGeneration = sessionGeneration
            Task {
                await self.refreshAuditStatus(
                    expectedGeneration: restoreGeneration,
                    expectedUserID: restoredUser.userId
                )
            }
            return
        }
        // v1 迁移：UserDefaults 残留 → Keychain，迁完清旧
        if let legacyData = defaults.data(forKey: legacyStoreKey),
           let u = try? JSONDecoder().decode(LoginResult.self, from: legacyData),
           let t = u.token, !t.isEmpty {
            defaults.removeObject(forKey: legacyStoreKey)
            let initialMode = resolvingInitialPermissionMode(for: u)
            let restoredUser = initialMode.user
            AnchorInfoStore.shared.hydrateFromLogin(restoredUser, preserveCachedSnapshot: true)
            user = restoredUser
            isLoggedIn = true
            reportAccountModeIfNeeded(UserTypeExperience.effectiveUserType(userInfo: restoredUser))
            save()
            AnalyticsTracker.login(userId: restoredUser.userId)
            CrashReporter.setUser(userID: restoredUser.userId)
            // v1 迁移路径与 Keychain 恢复保持相同权限语义。
            synchronizePermissionScopedServices()
            // H-3: 同 v2 路径,冷启动 restore 后 activate AppConfigStore
            Task { await AppConfigStore.shared.activate() }
            #if DEBUG
            AppLogger.auth.info("[SESSION RESTORE] store=v1 userId=\(restoredUser.userId ?? -1, privacy: .private) modeSource=\(initialMode.source, privacy: .public) modeResolved=\(restoredUser.isReviewModeResolved, privacy: .public) placeholder=\(restoredUser.resolvedReviewPlaceholderMatch == true, privacy: .public) permissionMedia=\(restoredUser.permissionModeMediaURLs.count, privacy: .public) effectiveUserType=\(UserTypeExperience.effectiveUserType(userInfo: restoredUser) ?? -1, privacy: .public)")
            #endif
            // v1 迁移与 v2 一致：恢复首帧模式后仅后台刷新资料和审核状态。
            let restoreGeneration = sessionGeneration
            Task {
                await self.refreshAuditStatus(
                    expectedGeneration: restoreGeneration,
                    expectedUserID: restoredUser.userId
                )
            }
        }
    }
}
