import Foundation

/// A-2 spec §1.1 三业务接口封装。加解密走 APIClient.post 现有链路（AES-128-CBC/PKCS7 → Base64 上行 / Hex 下行）。
///
/// ⚠️ Method 信源纪律（对齐 .claude/rules/api-http-method-strict.md，Finding #15 修 2026-07-10）：
/// - **api/user/index.ts 只提供 path**（`getCountryList` L20 / `hostRegisterV2` L122 / `hostReSubmitView` L124）
/// - **method 必须追 stores/modules/user.js + views/register/index.vue 实际 .then 调用点验证**——不能只信 `api/*/index.ts` 第一个导出（wishlist 已因此反悔踩过 code=1111 'Maybe it\'s GET'）
/// - 已核对 H5 register/index.vue L56 `hostReSubmitView({ ...formData })` + L73 `hostRegisterV2({ ...formData })` 及 CountryPickerSheet.fetch 调用点均 `.then` 走 http.post → iOS 用 `.post()` 对齐
/// - T1c.8 e2e 真接口若返 `code=1111`（method 错）或 `code!='0000'`（body 字段错）→ 立即回查 H5 store 层调用
enum RegisterService {

    /// A1: 国家列表（H5 `api/user/index.ts:20` `/api/index/getCountryList`）
    static func fetchCountryList() async throws -> [Country] {
        let data = try await APIClient.shared.post("/api/index/getCountryList", body: nil)
        return try JSONDecoder().decode([Country].self, from: data)
    }

    /// A2: 首次注册（H5 `api/user/index.ts:122` `/api/login/register`）
    static func registerV2(body: RegisterSubmitBody) async throws -> LoginResult {
        let data = try await APIClient.shared.post("/api/login/register", body: body.toDict())
        return try JSONDecoder().decode(LoginResult.self, from: data)
    }

    /// A3: 被拒重录（H5 `api/user/index.ts:124` `/api/login/reSubmitView`）
    static func reSubmitView(body: RegisterSubmitBody) async throws -> LoginResult {
        let data = try await APIClient.shared.post("/api/login/reSubmitView", body: body.toDict())
        return try JSONDecoder().decode(LoginResult.self, from: data)
    }

    /// 本地模拟删除账号完成资料流程后，直接恢复原服务端账号登录，不重复创建账号。
    static func loginDeletedAccount(email: String, password: String) async throws -> LoginResult {
        let data = try await APIClient.shared.post(
            "/api/login/v4/login",
            body: [
                "email": email,
                "password": CryptoUtil.loginPassword(password),
            ],
            suppressCodes: ["1005"]
        )
        return try JSONDecoder().decode(LoginResult.self, from: data)
    }
}
