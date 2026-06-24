import Foundation
import UIKit
import os

/// sapi（vvi 域名）链路鉴权 token 管理。
///
/// 业务范围：派对房 + 背包商城 + 营销活动等"weidou 微服务"链路。
/// 鉴权：HTTP 头 `auth_token`，过期或缺失时调 `/sapi/auth/v1/client/auth/exchangeToken`
/// （入参 `{ token: loginUuid }`）续接。
///
/// 对应 H5：`src/utils/token.js getBagShopToken` + `src/utils/request/sapiIndex.ts` 401 拦截。
///
/// 设计要点：
/// - Keychain 字段独立命名空间（`sapi.auth_token.v1` / `sapi.token_expire_at.v1`），不覆盖主接口 token
/// - 并发续接合并：多次 401 同时触发，只跑一次 exchange，其他 await 同一 Task
/// - exchange 请求绕过 PartyAPIClient 防 401 递归——内部用 URLSession + CryptoUtil
/// - **抽取候选点（路线图 §五）**：I 期钱包/背包接入时与 PartyAPIClient 共享 sapi 鉴权基建
@MainActor
final class SapiTokenStore {
    static let shared = SapiTokenStore()

    private static let tokenKey = "sapi.auth_token.v1"
    private static let expireKey = "sapi.token_expire_at.v1"   // 毫秒 epoch（String 形式存）

    /// 续接进行中的 Task（用于合并并发 401）
    private var inflightExchange: Task<String, Error>?

    private init() {}

    /// 当前持久化的 auth_token；初始 / 登出后 nil
    var authToken: String? { KeychainStore.getString(for: Self.tokenKey) }

    /// 过期时间（毫秒 epoch）；nil 视为已过期
    var tokenExpireAtMs: Int64? {
        guard let s = KeychainStore.getString(for: Self.expireKey), let v = Int64(s) else { return nil }
        return v
    }

    /// 已过期（含 nil 情况）
    var isExpired: Bool {
        guard let exp = tokenExpireAtMs else { return true }
        return Int64(Date().timeIntervalSince1970 * 1000) >= exp
    }

    /// 获取有效 auth_token；过期或未取过则自动调 exchangeToken 续接（合并并发）。
    /// PartyAPIClient 401 retry 时传 forceRefresh=true 强制走一次 exchange。
    @discardableResult
    func ensureValid(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = authToken, !t.isEmpty, !isExpired { return t }
        return try await runExchange()
    }

    /// 登出时清（SessionStore.logout 内调用）
    func clear() {
        inflightExchange?.cancel()
        inflightExchange = nil
        KeychainStore.remove(for: Self.tokenKey)
        KeychainStore.remove(for: Self.expireKey)
    }

    // MARK: - exchange 并发合并

    private func runExchange() async throws -> String {
        if let task = inflightExchange {
            return try await task.value
        }
        let task = Task { try await self.performExchange() }
        inflightExchange = task
        defer { inflightExchange = nil }
        return try await task.value
    }

    // MARK: - exchangeToken 接口调用（独立 URLSession，绕过 PartyAPIClient）

    private func performExchange() async throws -> String {
        guard let loginUuid = SessionStore.shared.user?.loginUuid, !loginUuid.isEmpty else {
            throw SapiTokenError.missingLoginUuid
        }
        AppLogger.party.info("[SapiTokenStore] exchange begin")

        guard let url = URL(string: AppConfig.sapiBaseURL + "/sapi/auth/v1/client/auth/exchangeToken") else {
            throw SapiTokenError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30

        // 头：与 PartyAPIClient.sapiHeaders 保持一致，authToken=nil（exchange 接口本身不带 auth_token），
        //     loginToken 仍带（H5 sapiIndex.ts 拦截器无条件注入主 token）
        let headers = Self.sapiHeaders(authToken: nil, loginToken: AuthToken.value)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        // body: { token: loginUuid } → AES(sapi key/iv) → Base64
        let bodyJson = try JSONSerialization.data(withJSONObject: ["token": loginUuid])
        let bodyStr = String(decoding: bodyJson, as: UTF8.self)
        guard let encrypted = CryptoUtil.aesEncryptToBase64(bodyStr, key: AppConfig.sapiAesKey, iv: AppConfig.sapiAesIV) else {
            throw SapiTokenError.encryptFailed
        }
        req.httpBody = Data(encrypted.utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SapiTokenError.networkError }
        guard http.statusCode == 200 else {
            AppLogger.party.error("[SapiTokenStore] exchange HTTP \(http.statusCode, privacy: .public)")
            throw SapiTokenError.httpStatus(http.statusCode)
        }

        // envelope: { code: '200'(字符串), message, result(hex) }
        guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SapiTokenError.envelopeParseFailed
        }
        let code = env["code"] as? String ?? ""
        guard code == "200" else {
            let msg = env["message"] as? String ?? ""
            AppLogger.party.error("[SapiTokenStore] exchange biz code=\(code, privacy: .public) msg=\(msg, privacy: .private)")
            throw SapiTokenError.businessFailed(code: code, message: msg)
        }
        guard let hex = env["result"] as? String, !hex.isEmpty,
              let decrypted = CryptoUtil.aesDecryptFromHex(hex, key: AppConfig.sapiAesKey, iv: AppConfig.sapiAesIV),
              let resultData = decrypted.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            throw SapiTokenError.resultDecryptFailed
        }

        // result: { tokenValue: String, tokenTimeout: Int(秒) }
        guard let tokenValue = result["tokenValue"] as? String, !tokenValue.isEmpty else {
            throw SapiTokenError.tokenValueMissing
        }
        let tokenTimeoutSec = (result["tokenTimeout"] as? Int) ?? 3600  // 兜底 1 小时
        let expireAtMs = Int64(Date().timeIntervalSince1970 * 1000) + Int64(tokenTimeoutSec) * 1000

        KeychainStore.setString(tokenValue, for: Self.tokenKey)
        KeychainStore.setString(String(expireAtMs), for: Self.expireKey)

        AppLogger.party.info("[SapiTokenStore] exchange success expireAtMs=\(expireAtMs, privacy: .public) timeoutSec=\(tokenTimeoutSec, privacy: .public)")
        return tokenValue
    }

    // MARK: - sapi 公共头（PartyAPIClient 共用）

    /// 与 H5 `src/utils/request/sapiIndex.ts` 拦截器对齐：
    /// - `loginToken` / `anchorToken` 始终注入主 token（即使是 exchangeToken 接口）
    /// - `auth_token` 仅在 nil 时省略（exchangeToken 接口本身不带）
    /// - 其他公共头与主接口 `APIClient.commonHeaders` 一致
    /// nonisolated 让 PartyAPIClient 非 @MainActor 调用不必 await
    nonisolated static func sapiHeaders(authToken: String?, loginToken: String?) -> [String: String] {
        var h: [String: String] = [
            "Accept": "application/json, text/plain",
            "Content-Type": "application/json;charset=UTF-8",
            "Accept-Language": "en",
            "Ocp-Apim-Subscription-Key": AppConfig.ocpApimKey,
            "isProxy": "false",
            "deviceType": "iPhone",
            "deviceId": DeviceInfo.deviceId,
            "deviceNo": DeviceInfo.deviceId,
            "osType": "iOS",
            "osVersion": UIDevice.current.systemVersion,
            "appVersion": AppConfig.appVersion,
            "version": AppConfig.appVersion,
            "appid": AppConfig.appId,
        ]
        if let t = loginToken, !t.isEmpty {
            h["loginToken"] = t
            h["anchorToken"] = t   // 与主接口对齐
        }
        if let a = authToken, !a.isEmpty {
            h["auth_token"] = a
        }
        return h
    }
}

/// sapi 鉴权链路错误（exchangeToken / 401 续接 / token 解析）
enum SapiTokenError: Error, LocalizedError {
    case missingLoginUuid
    case invalidURL
    case encryptFailed
    case networkError
    case httpStatus(Int)
    case envelopeParseFailed
    case businessFailed(code: String, message: String)
    case resultDecryptFailed
    case tokenValueMissing

    var errorDescription: String? {
        switch self {
        case .missingLoginUuid: return "sapi: 未登录或 loginUuid 缺失"
        case .invalidURL: return "sapi: URL 非法"
        case .encryptFailed: return "sapi: 请求加密失败"
        case .networkError: return "sapi: 网络错误"
        case .httpStatus(let code): return "sapi: HTTP \(code)"
        case .envelopeParseFailed: return "sapi: 响应解析失败"
        case .businessFailed(let code, let message): return "sapi: 业务失败 [\(code)] \(message)"
        case .resultDecryptFailed: return "sapi: 响应解密失败"
        case .tokenValueMissing: return "sapi: tokenValue 缺失"
        }
    }
}
