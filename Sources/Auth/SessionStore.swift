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
        logout()
        let codeSuffix = code.isEmpty ? "" : " [\(code)]"
        errorMessage = backend.isEmpty
            ? "\(L10n.authErrorSessionInvalidated)\(codeSuffix)"
            : "\(L10n.authErrorSessionInvalidated)\(codeSuffix) (\(backend))"
    }

    func login(email: String, password: String) async {
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        let pwd = CryptoUtil.loginPassword(password)
        do {
            let data = try await APIClient.shared.post(
                "/api/login/v4/login",
                body: ["email": email, "password": pwd]
            )
            let result = try JSONDecoder().decode(LoginResult.self, from: data)
            guard let token = result.token, !token.isEmpty else {
                errorMessage = L10n.authErrorNoToken
                return
            }
            user = result
            isLoggedIn = true
            save()
        } catch let e as APIError {
            // 1005 = 账号未注册 / token 失效，直接展示后端文案
            errorMessage = e.message
        } catch {
            errorMessage = String(format: L10n.authErrorNetworkFormat, error.localizedDescription)
        }
    }

    func logout() {
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
    }

    // MARK: - H M4：sysMsg 通道入口（spec §3.1 / H 校验清单 §1.1.2 A 表）

    /// sysMsg -4：被关注通知。仅累加 @Published 计数，UI 订阅做 Toast / Badge。
    func incrementFollow() {
        followIncrementCount += 1
        AppLogger.auth.info("[Session] follow incr total=\(self.followIncrementCount, privacy: .public)")
    }

    /// sysMsg 58：主播审核状态变更（applyStatus 0=通过 / 1=拒绝）。
    /// - 0 通过：H5 行为是 logOut 让主播重登；J 期产品确认后再决定是否自动 logout
    /// - 1 拒绝：UI 弹 content 提示；本方法仅落 @Published 字段
    func handleAuditStatus(applyStatus: Int, content: String) {
        lastAuditStatus = (applyStatus, content)
        AppLogger.auth.notice("[Session] audit status=\(applyStatus, privacy: .public) content=\(content, privacy: .public)")
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
        }
    }
}
