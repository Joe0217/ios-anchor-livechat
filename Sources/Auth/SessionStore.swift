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

    /// login 成功但 userType 非 2/9（审核中/被拒）→ 携 mineInfo 让 View 层 hydrate + push Register
    /// tuple 不 Equatable，用 struct 包
    @Published var needsResubmit: PendingResubmit? = nil

    struct PendingRegister: Equatable {
        let email: String
        let password: String
    }

    struct PendingResubmit: Equatable {
        let loginResult: LoginResult
        let mineInfo: AnchorInfo
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.loginResult.userId == rhs.loginResult.userId
                && lhs.mineInfo.userId == rhs.mineInfo.userId
        }
    }

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

            // A-2 code-review Finding #1 修 2026-07-10：resubmit 路径先分流再决定是否 applyLogin
            // 原：先 applyLogin(翻 isLoggedIn=true → RootView dismantle LoginView) → 再设 needsResubmit → 无监听者 → 路径整体断
            // 修：userType 属"审核中/被拒" → **不**调 applyLogin，让 isLoggedIn 保 false 使 LoginView 存活；
            //     临时设 AuthToken.value 让 APIClient 能拉 mineInfo；LoginView.onChange 消费 needsResubmit push register；
            //     RegisterStore.submit 成功后才 applyLogin(register 接口返 result) 真登录
            // 对齐 H5 login/index.vue:75-82 else 分支语义 (userType !== 2 && !== 9 走 register)
            let isResubmitPath = (result.userType != nil && result.userType != 2 && result.userType != 9)
            //     ↑ Finding #7 修：userType nil 视为**合法登录**（H5 !== 对 undefined 也 truthy → 走 else register；
            //       iOS 保守：nil 时不算 resubmit，直接走正常登录路径避免误判把已注册用户塞进 register）

            if isResubmitPath {
                // 临时授权：让 APIClient 能带 token 拉 mineInfo；isLoggedIn 保 false 让 LoginView 存活
                AuthToken.value = token
                _ = KeychainStore.setString(password, for: KeychainKey.pendingRegisterPassword)
                await AnchorInfoStore.shared.refresh()
                if let mineInfo = AnchorInfoStore.shared.mine {
                    needsResubmit = PendingResubmit(loginResult: result, mineInfo: mineInfo)
                } else {
                    // Post-review NEW-2 修 2026-07-10：refresh 失败 mine nil → 无 needsResubmit 触发用户卡登录页无反馈
                    // 回退清临时状态 + 用通用网络错误提示（避免误导用户 email/pwd 错）
                    AuthToken.value = nil
                    _ = KeychainStore.remove(for: KeychainKey.pendingRegisterPassword)
                    errorMessage = String(format: L10n.authErrorNetworkFormat, "profile refresh failed")
                    AppLogger.auth.error("[SessionStore] resubmit path aborted: AnchorInfoStore.mine nil after refresh")
                }
                // 不 applyLogin，等 RegisterStore.submit 成功后调
                return
            }

            // 正常登录（userType == 2 已审核 / 9 代理 / nil 视为合法）
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
    /// 副作用：**不设** errorMessage（成功路径）；**不清** pendingRegister/needsResubmit（由 View 层消费清）
    /// - returns: true = 登录状态已建立；false = token 缺失，调用方决定文案
    @discardableResult
    func applyLogin(_ result: LoginResult) async -> Bool {
        guard let token = result.token, !token.isEmpty else { return false }
        user = result
        isLoggedIn = true
        save()   // 内部会 AuthToken.value = token
        AppLogger.auth.info("[LOGIN OK] userId=\(result.userId ?? -1, privacy: .private) → fire AnchorInfoStore.refresh() + AppConfigStore.activate()")
        Task { await AnchorInfoStore.shared.refresh() }
        // H-3：AppConfigStore 横断基建（视频通话权限 / 翻译 key / 回复积分 config），
        // 挂 session-scoped rule 双入口之 login refresh；一次拉 4 key 逗号 join
        Task { await AppConfigStore.shared.activate() }
        // Batch 6.1.3：全局 P2P 消息监听（充值通知 attachType=35 → 合成塞进 notification 会话）
        // 挂 session-scoped rule 双入口之 login activate；SDK 已完成 login 后 add delegate 才能收消息
        GlobalP2PMessageObserver.shared.activate()
        // sapi（vvi 派对房/背包等链路）token 主动预取，对齐 H5 login/index.vue:86 `await getBagShopToken()`
        // forceRefresh=true 保证换账号后不复用上个账号残留（虽 logout 已 clear，双保险）
        Task { try? await SapiTokenStore.shared.ensureValid(forceRefresh: true) }
        _ = token   // 消除 unused warning（token 是 guard 的语义约束，不需要真使用）
        return true
    }

    func logout() {
        // P1-6：防未来新调用路径经 logout 时残留 audit alert / 闸门
        // （当前链 confirmAuditAlert 已先手清 auditDialogShowing；这里是防御式绑生命周期）
        auditAlert = nil
        auditDialogShowing = false
        user = nil
        isLoggedIn = false
        errorMessage = ""
        KeychainStore.remove(for: storeKey)
        defaults.removeObject(forKey: legacyStoreKey)   // 清掉历史残留
        AuthToken.value = nil
        // sapi（vvi 派对房/背包等链路）的 auth_token 与主 token 是两套独立生命周期，需同步清
        SapiTokenStore.shared.clear()
        // 同步清空主播信息缓存,避免下个账号登录后看到上个号的残留
        AnchorInfoStore.shared.clear()
        // 图片缓存也清掉:上个号的头像/相册/视频缩略不应被下个号看到
        ImageCache.shared.clear()
        // IM 场景闸门清空（防 A 账号场景残留误导 B 账号过滤逻辑）
        IMSceneGate.shared.resetAll()
        // v5 F-1: P2P 会话列表 store 清空（20s task/sessions/profiles/系统入口/可见集全清 + state=.idle）
        // 未清则登出后 task 仍 401 循环，新账号登录看到旧账号残留数据（review 报告 F-1）
        MessageSessionStore.shared.clear()
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
        // Batch 6.1.3: 全局 P2P 消息 delegate 解注册（session-scoped rule 双入口之 logout deactivate）
        // 防跨账号后 B 账号仍触发 A 账号的合成路径
        GlobalP2PMessageObserver.shared.deactivate()
        // A-2: 注册表单短态 + 短期 Keychain 密码清（session-scoped rule 应用；防止 A 账号未完成注册的表单数据泄漏到 B）
        RegisterStore.shared.reset()
        _ = KeychainStore.remove(for: KeychainKey.pendingRegisterPassword)
        pendingRegister = nil
        needsResubmit = nil
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

    /// RootView `.alert(item:)` dismissButton 回调；根据 applyStatus 分流 logout / refresh。
    /// SwiftUI 会在 tap 后自动置 auditAlert=nil（`.alert(item:)` 契约），本方法不再手动置 nil 避免双写。
    func confirmAuditAlert(_ ctx: AuditAlertContext) {
        if ctx.applyStatus == 0 {
            auditDialogShowing = false
            logout()
        } else {
            // 拒绝分支：H5 走 forcePageReload() 强制重新拉 mineInfo；iOS 无 reload 概念，
            // 通过 AnchorInfoStore.refresh() 让本地 anchor 态与后端 rejected 后的 userType 对齐，
            // Publisher 驱动 UI 自动刷新（tab 顺序 / 可播按钮 enable 状态 等）。
            Task { await AnchorInfoStore.shared.refresh() }
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
            // Batch 6.1.3: 冷启动已登录 → 立即 activate 全局 P2P observer（避免走 login 路径遗漏）
            GlobalP2PMessageObserver.shared.activate()
            // H-3: 冷启动 restore 时也 activate AppConfigStore(rule session-scoped-store-refresh 双入口)
            // 否则 microsoftTranslatorKey/Area 为 nil,翻译 tap 会 toast "Translation config missing"
            Task { await AppConfigStore.shared.activate() }
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
            // Batch 6.1.3: 同步 v1 迁移路径也 activate
            GlobalP2PMessageObserver.shared.activate()
            // H-3: 同 v2 路径,冷启动 restore 后 activate AppConfigStore
            Task { await AppConfigStore.shared.activate() }
        }
    }
}
