import Foundation

/// 登录会话：登录 / 持久化 / 登出，并向业务接口提供 token。
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var user: LoginResult?
    @Published var isLoading = false
    @Published var errorMessage = ""

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

    /// 当前登录 token，供需要鉴权的接口使用
    var token: String? { user?.token }

    /// A 收尾：APIClient 抛 1004/1005 时通过 NotificationCenter 集中通知，这里挂 observer。
    /// observer 闭包持 weak self，避免循环引用；deinit 显式移除（双保险）。
    private var sessionInvalidatedObserver: NSObjectProtocol?

    init() {
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
    /// 后端原始 message 放 userInfo["message"]，非空时拼到统一文案之后供排查。
    /// 错误码拼到文案末尾 `[xxxx]` 形式，让用户/客服可区分 1004 vs 1005。
    /// 同时通过 AppLogger.auth.error 打日志，供生产排查会话失效频率/触发码。
    private func handleSessionInvalidated(userInfo: [AnyHashable: Any]?) {
        let code = (userInfo?["code"] as? String) ?? ""
        let backend = (userInfo?["message"] as? String) ?? ""
        AppLogger.auth.error("session invalidated code=\(code, privacy: .public) backend=\(backend, privacy: .private)")

        // 用户可感知反馈（GlobalErrorBanner）**独立于闸门**触发 —— 对齐 H5 `request/index.ts:96-108`：
        // showNotify 弹 toast 与 logOut() 分开调用，闸门 `reviewPassedDialogShowing` 只跳过 logOut，
        // 用户仍能看到 "session expired" 提示。
        let codeSuffix = code.isEmpty ? "" : " [\(code)]"
        errorMessage = backend.isEmpty
            ? "\(L10n.authErrorSessionInvalidated)\(codeSuffix)"
            : "\(L10n.authErrorSessionInvalidated)\(codeSuffix) (\(backend))"

        // P1-6 闸门：审核通过弹窗展示期间跳过 logout（对齐 H5 `logOut()` helper 内 return）
        // 防审核通过后旧 token 立即失效弹窗盖掉审核弹窗
        guard !auditDialogShowing else {
            AppLogger.auth.notice("[Session] logout suppressed by audit dialog; banner still shown; code=\(code, privacy: .public)")
            return
        }
        logout()
    }

    func login(email: String, password: String) async {
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        let pwd = CryptoUtil.loginPassword(password)
        do {
            let data = try await APIClient.shared.post(
                "/api/login/v4/login",
                body: ["email": email, "password": pwd],
                suppressCodes: ["1005"]                     // A-2 spec §3.2 v3 BLOCK-1：让 1005 走 catch 分流未注册跳注册，而非被 observer logout 拦截
            )
            let result = try JSONDecoder().decode(LoginResult.self, from: data)
            guard let token = result.token, !token.isEmpty else {
                errorMessage = L10n.authErrorNoToken
                return
            }

            // 2026-07-16 重构：对齐 H5 loginSuccess (`stores/modules/user.js:74-131`)——登录响应本身足以驱动
            // UI 分流,不再依赖 profile 接口拉取。userType 判定后延到 RootView 分流(userType != 2 && != 9 →
            // RestrictedTabView,由 MineRestrictedView.Resubmit 按钮才拉资料 hydrate)。
            //
            // 保留 pendingRegisterPassword Keychain 保存:MineRestrictedView.handleResubmit 拉 mineInfo 后
            // RegisterStore.hydrate 需要 cachedPassword 兜底(H5 register 提交仍要带明文密码走 MD5)。
            // logout 时清此 Keychain(既有逻辑 line 269 已实现)。
            _ = KeychainStore.setString(password, for: KeychainKey.pendingRegisterPassword)

            guard await applyLogin(result) else {
                errorMessage = L10n.authErrorNoToken
                return
            }
        } catch let e as APIError where e.code == "1005" {
            // 1005 = 账号未注册；suppressCodes 已让 APIClient 不 post 通知，此处安全设 pendingRegister 让 LoginView push 注册页
            pendingRegister = PendingRegister(email: email, password: password)
            RegisterAnalytics.report(.signUp)
        } catch let e as APIError {
            errorMessage = e.message
        } catch {
            errorMessage = String(format: L10n.authErrorNetworkFormat, error.localizedDescription)
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
    func applyLogin(_ result: LoginResult) async -> Bool {
        guard let token = result.token, !token.isEmpty else { return false }
        user = result
        isLoggedIn = true
        save()   // 内部会 AuthToken.value = token
        AnalyticsTracker.login(userId: result.userId)
        CrashReporter.setUser(userID: result.userId)
        AppLogger.auth.info("[LOGIN OK] userId=\(result.userId ?? -1, privacy: .private) → fire AnchorInfoStore.refresh() + AppConfigStore.activate()")
        // 2026-07-16：对齐 H5 `loginSuccess → setMineInfo(res)`——用登录响应直接注入 mine，
        // 不再依赖 `/api/user/getUserInfo`（后端 404）。getAnchorInfo 结果稍后由 refresh() 覆盖 info。
        AnchorInfoStore.shared.hydrateFromLogin(result)
        Task { await AnchorInfoStore.shared.refresh() }
        // H-3：AppConfigStore 横断基建（视频通话权限 / 翻译 key / 回复积分 config），
        // 挂 session-scoped rule 双入口之 login refresh；一次拉 4 key 逗号 join
        Task { await AppConfigStore.shared.activate() }
        // 107 仅保留 Party chatroom，不能因登录完成而注册 P2P delegate。这里直接按 userType
        // 同步，不能读异步装配中的 PermissionBridge（启动期仍可能是 deny-by-default）。
        synchronizeGlobalP2PObserver(for: result.userType)
        synchronizeMessageSessionStore(for: result.userType)
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
    }

    func logout() {
        // P1-6：防未来新调用路径经 logout 时残留 audit alert / 闸门
        // （当前链 confirmAuditAlert 已先手清 auditDialogShowing；这里是防御式绑生命周期）
        auditAlert = nil
        auditDialogShowing = false
        AnalyticsTracker.logout()
        CrashReporter.clearUser()
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
        user = nil
        isLoggedIn = false
        errorMessage = ""
        KeychainStore.remove(for: storeKey)
        defaults.removeObject(forKey: legacyStoreKey)   // 清掉历史残留
        AuthToken.value = nil
        // 轻量 WebView 与通用 H5 都使用默认 website data store。登出时清除，避免
        // 下一账号继承前一账号的页面缓存、LocalStorage 或 cookie。
        H5WebSession.clear()
        // sapi（vvi 派对房/背包等链路）的 auth_token 与主 token 是两套独立生命周期，需同步清
        SapiTokenStore.shared.clear()
        // 同步清空主播信息缓存,避免下个账号登录后看到上个号的残留
        AnchorInfoStore.shared.clear()
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
        // G2: 客服 yxAccId 缓存 — clear() 方法早已存在但 logout 从未调用，导致 A 客服 imId 泄漏到 B
        CustomerServiceIdStore.shared.clear()
        // G3: 在线状态 store — 未清则 A 的 forcedBusy=true / userSetOnline=false 残留到 B 首屏
        OnlineStatusStore.shared.clear()
        // H-2 v2: Flame 通道 B 关注列表 24h 缓存 — 跨账号必须清（A 关注列表泄漏到 B 会误判 Flame）
        FollowUserListService.shared.clear()
        // H-3: AppConfigStore 横断基建（session-scoped rule 双入口之 logout clear）
        // 未清则 A 账号的 achorHideButton / 微软 key 残留到 B 首屏，通话按钮显隐 / 翻译走错 key
        AppConfigStore.shared.clear()
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

    /// 2026-07-16:受限首屏进入时刷新审核态,对齐 H5 App.vue.isLogin() 每次冷启动拉 getAnchorInfo → setMineInfo 覆盖 valid/onReview/banAlways/... 字段。
    ///
    /// iOS 侧 LoginResult 是首次登录快照,若审核态在服务端变化(通过/被拒/临时封禁)本地不知情。sysMsg 58 push 只在
    /// App 在线时能收到;冷启动或长时间离线的账号必须主动拉一次审核态确认。
    ///
    /// 数据源:AnchorInfoStore.shared.refresh() 拉 getAnchorInfo → info?.userType/valid/onReview/banAlways/bannedSubType/type
    /// 同步回 self.user (LoginResult),save() 持久化到 Keychain。
    ///
    /// 失败静默:refresh 内部已 non-fatal(anchor/mine/gift 3 接口任一失败不 throw),info 可能仍为 nil;此时不覆盖 user,
    /// 保持首次登录的审核态快照(用户重新登录时会拿到新的 LoginResult 覆盖)。
    func refreshAuditStatus() async {
        await AnchorInfoStore.shared.refresh()
        guard let current = user, let info = AnchorInfoStore.shared.info else {
            AppLogger.auth.notice("[Session] refreshAuditStatus skip: user or anchorInfo nil")
            return
        }
        // 只同步审核态相关字段;其他字段(userId/token/imToken 等)保持登录响应原值
        let updated = LoginResult(
            userId: current.userId,
            token: current.token,
            loginUuid: current.loginUuid,
            yxAccid: current.yxAccid,
            imToken: current.imToken,
            // H5 `setMineInfo` 以 userType 决定 isHost；type 仅用于受限页的审核提示。
            // 审核通过后服务端通常只更新 userType，若仍用 type 覆盖会让 iOS 卡在受限模式。
            userType: info.userType ?? info.type ?? current.userType,
            nickname: info.nickname ?? current.nickname,
            icon: info.icon ?? current.icon,
            userLevel: info.userLevel ?? current.userLevel,
            chatBubble: info.chatBubble ?? current.chatBubble,
            chatBubbleGuardianLevel: info.chatBubbleGuardianLevel ?? current.chatBubbleGuardianLevel,
            valid: info.valid ?? current.valid,
            onReview: info.onReview ?? current.onReview,
            banAlways: info.banAlways ?? current.banAlways,
            bannedSubType: info.bannedSubType ?? current.bannedSubType,
            type: info.type ?? current.type
        )
        user = updated
        save()
        synchronizeGlobalP2PObserver(for: updated.userType)
        synchronizeMessageSessionStore(for: updated.userType)
        AppLogger.auth.info("[Session] refreshAuditStatus OK userType=\(updated.userType ?? -1) valid=\(updated.valid ?? -1) onReview=\(updated.onReview == true) banAlways=\(updated.banAlways == true)")
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

    private func save() {
        guard let user, let data = try? JSONEncoder().encode(user) else { return }
        KeychainStore.setData(data, for: storeKey)
        AuthToken.value = user.token   // 供 APIClient 自动附带
    }

    private func load() {
        // v2 路径：Keychain
        if let data = KeychainStore.getData(for: storeKey),
           let u = try? JSONDecoder().decode(LoginResult.self, from: data),
           let t = u.token, !t.isEmpty {
            user = u
            isLoggedIn = true
            AuthToken.value = t
            AnalyticsTracker.login(userId: u.userId)
            CrashReporter.setUser(userID: u.userId)
            // 冷启动恢复同样按账号能力决定是否注册 P2P observer，避免 107 在后台收到私聊事件。
            synchronizeGlobalP2PObserver(for: u.userType)
            synchronizeMessageSessionStore(for: u.userType)
            // H-3: 冷启动 restore 时也 activate AppConfigStore(rule session-scoped-store-refresh 双入口)
            // 否则 microsoftTranslatorKey/Area 为 nil,翻译 tap 会 toast "Translation config missing"
            Task { await AppConfigStore.shared.activate() }
            // 2026-07-17:冷启动 restore 同步注入 AnchorInfoStore.mine(对齐 applyLogin 里的 hydrateFromLogin 双入口设计)。
            // 若不注入,mine 恒 nil,派生 UI 字段(displayName/userId/iconURL 等)只能靠 info 或 SessionStore.user 兜底;
            // 未审核账号 info 拉取可能失败(non-fatal),mine 缺失会让派生链断层。
            AnchorInfoStore.shared.hydrateFromLogin(u)
            return
        }
        // v1 迁移：UserDefaults 残留 → Keychain，迁完清旧
        if let legacyData = defaults.data(forKey: legacyStoreKey),
           let u = try? JSONDecoder().decode(LoginResult.self, from: legacyData),
           let t = u.token, !t.isEmpty {
            KeychainStore.setData(legacyData, for: storeKey)
            defaults.removeObject(forKey: legacyStoreKey)
            user = u
            isLoggedIn = true
            AuthToken.value = t
            AnalyticsTracker.login(userId: u.userId)
            CrashReporter.setUser(userID: u.userId)
            // v1 迁移路径与 Keychain 恢复保持相同权限语义。
            synchronizeGlobalP2PObserver(for: u.userType)
            synchronizeMessageSessionStore(for: u.userType)
            // H-3: 同 v2 路径,冷启动 restore 后 activate AppConfigStore
            Task { await AppConfigStore.shared.activate() }
            // 2026-07-17:v1 迁移路径同步 hydrate(与 v2 分支对称)
            AnchorInfoStore.shared.hydrateFromLogin(u)
        }
    }
}
