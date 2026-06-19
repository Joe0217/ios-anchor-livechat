import Foundation

/// 登录会话：登录 / 持久化 / 登出，并向业务接口提供 token。
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var user: LoginResult?
    @Published var isLoading = false
    @Published var errorMessage = ""

    private let storeKey = "session.user.v1"
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
                errorMessage = "登录失败：服务未返回 token"
                return
            }
            user = result
            isLoggedIn = true
            save()
        } catch let e as APIError {
            // 1005 = 账号未注册 / token 失效，直接展示后端文案
            errorMessage = e.message
        } catch {
            errorMessage = "网络错误：\(error.localizedDescription)"
        }
    }

    func logout() {
        user = nil
        isLoggedIn = false
        errorMessage = ""
        defaults.removeObject(forKey: storeKey)
        AuthToken.value = nil
    }

    // MARK: - 持久化

    private func save() {
        guard let user, let data = try? JSONEncoder().encode(user) else { return }
        defaults.set(data, forKey: storeKey)
        AuthToken.value = user.token   // 供 APIClient 自动附带
    }

    private func load() {
        guard let data = defaults.data(forKey: storeKey),
              let u = try? JSONDecoder().decode(LoginResult.self, from: data),
              let t = u.token, !t.isEmpty else { return }
        user = u
        isLoggedIn = true
        AuthToken.value = t
    }
}
