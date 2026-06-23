import Foundation

/// 登录会话：登录 / 持久化 / 登出，并向业务接口提供 token。
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var user: LoginResult?
    @Published var isLoading = false
    @Published var errorMessage = ""

    /// v2 起 user 整体（含 token / imToken / loginUuid 等敏感字段）存 Keychain。
    /// v1（UserDefaults）→ v2 一次性迁移：load() 命中旧键时搬到 Keychain 并清旧。
    private let storeKey = "session.user.v2"
    private let legacyStoreKey = "session.user.v1"
    private let defaults = UserDefaults.standard

    /// 当前登录 token，供需要鉴权的接口使用
    var token: String? { user?.token }

    init() { load() }

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
        // 同步清空主播信息缓存，避免下个账号登录后看到上个号的残留
        AnchorInfoStore.shared.clear()
        // 图片缓存也清掉：上个号的头像/相册/视频缩略不应被下个号看到
        ImageCache.shared.clear()
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
