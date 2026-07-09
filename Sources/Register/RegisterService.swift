import Foundation

/// A-2 spec §1.1 三业务接口封装。加解密走 APIClient.post 现有链路（AES-128-CBC/PKCS7 → Base64 上行 / Hex 下行）。
///
/// ⚠️ 精确 body/response 字段名以 T1c.8 e2e 真接口调用错误信息为准（当前基于 H5 `api/user/index.ts` L122-124 + `views/register/index.vue` formData 字面推）
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
}
