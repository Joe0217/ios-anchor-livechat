import Foundation
import UIKit
import os

/// sapi（vvi）链路 HTTP 客户端，与主接口 `APIClient` 并存。
///
/// 业务范围：派对房 + 背包商城 + 营销活动等"weidou 微服务"链路。
/// 路径：调用方传完整 `/sapi/...` path（与 H5 `src/utils/request/sapiIndex.ts` 风格一致），
/// 例如 `/sapi/weidou/v1/client/party/room/enter`。
///
/// 与 `APIClient` 的差异（基于 H5 sapiIndex.ts 实际行为）：
/// - baseURL：`AppConfig.sapiBaseURL`（`vvi.cphub.link`）而非主接口域
/// - 鉴权：`auth_token` 头（来自 `SapiTokenStore`）+ `loginToken/anchorToken`（主 token）**两者同时注入**
/// - 加密 key/iv：`AppConfig.sapiAesKey/IV`（dev 巧合与主接口同套；test/prod 是独立 `cbilx4v7vgz6jpw7 / dmnry3u8bhk5zq9f`）
/// - envelope：`code === '200'`（**字符串**，非数字；不同于主接口的 `'0000'`）
/// - `result` 仍是 Hex 密文（与主接口同形态，**不是**整体 body 加密）
/// - 401 拦截 → 自动调 `SapiTokenStore.ensureValid(forceRefresh: true)` 续 + retry 一次
///
/// **抽取候选点（路线图 §五）**：I 期钱包/背包接入时与 SapiTokenStore 共享 sapi 鉴权基建。
final class PartyAPIClient {
    static let shared = PartyAPIClient()
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    /// POST 请求。body 走 sapi AES key/iv 加密 → Base64 作为原始 body。
    /// 返回解密后的 result JSON（供 Codable）；非 '200' 抛 `PartyAPIError.business`。
    /// HTTP 401 自动续 token 并 retry 一次；仍 401 抛 `PartyAPIError.tokenExchangeFailed`。
    func post(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        try await send(path: path, body: body, isRetry: false)
    }

    private func send(path: String, body: [String: Any]?, isRetry: Bool) async throws -> Data {
        guard let url = URL(string: AppConfig.sapiBaseURL + path) else {
            throw PartyAPIError.invalidURL
        }

        // 确保 auth_token 有效（首次访问 / 已过期时自动 exchange；并发合并）
        let authToken: String?
        do {
            authToken = try await SapiTokenStore.shared.ensureValid()
        } catch {
            AppLogger.party.error("[PartyAPI] ensureValid failed: \(String(describing: error), privacy: .private)")
            // 续 token 失败不阻塞调用（让请求带 nil auth_token 走，让服务端返 401 走 retry 链路决定终态）
            authToken = nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        let headers = SapiTokenStore.sapiHeaders(authToken: authToken, loginToken: AuthToken.value)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        if let body = body {
            // 守护：JSONSerialization 对 NSNull / 非合法顶层对象会抛 OC 异常且 try? 不接（CLAUDE.md 已知坑）
            guard JSONSerialization.isValidJSONObject(body) else {
                throw PartyAPIError.encryptFailed
            }
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let jsonStr = String(decoding: jsonData, as: UTF8.self)
            guard let encrypted = CryptoUtil.aesEncryptToBase64(jsonStr, key: AppConfig.sapiAesKey, iv: AppConfig.sapiAesIV) else {
                throw PartyAPIError.encryptFailed
            }
            req.httpBody = Data(encrypted.utf8)
        }

        #if DEBUG
        let tk = headers["auth_token"] ?? ""
        let tkInfo = tk.isEmpty ? "empty" : "len=\(tk.count)"
        AppLogger.party.debug("POST \(path, privacy: .public) auth_token=\(tkInfo, privacy: .private) retry=\(isRetry, privacy: .public)")
        #endif

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw PartyAPIError.networkError
        }

        #if DEBUG
        let respPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary>"
        AppLogger.party.debug("RESP \(path, privacy: .public) http=\(http.statusCode, privacy: .public) body=\(String(respPreview), privacy: .private)")
        #endif

        // 401：续 token + retry 一次；二次 401 视为失败
        if http.statusCode == 401 {
            if isRetry {
                AppLogger.party.error("[PartyAPI] retry still 401, give up")
                throw PartyAPIError.tokenExchangeFailed
            }
            AppLogger.party.notice("[PartyAPI] 401 → exchange token + retry")
            do {
                _ = try await SapiTokenStore.shared.ensureValid(forceRefresh: true)
            } catch {
                throw PartyAPIError.tokenExchangeFailed
            }
            return try await send(path: path, body: body, isRetry: true)
        }

        // 其他非 200 HTTP（403/404/500 等）：直接抛网络层错误
        guard http.statusCode == 200 else {
            throw PartyAPIError.httpStatus(http.statusCode)
        }

        // envelope: { code: '200'(字符串), message, result(hex) }
        guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PartyAPIError.envelopeParseFailed
        }
        let code = env["code"] as? String ?? ""
        let message = env["message"] as? String ?? ""

        guard code == "200" else {
            throw PartyAPIError.business(code: code, message: message.isEmpty ? "请求失败(\(code))" : message)
        }

        // 解密 result（Hex 密文，sapi key/iv）
        if let hex = env["result"] as? String, !hex.isEmpty,
           let decrypted = CryptoUtil.aesDecryptFromHex(hex, key: AppConfig.sapiAesKey, iv: AppConfig.sapiAesIV),
           let out = decrypted.data(using: .utf8) {
            return out
        }
        // result 为空 / null / 非加密：仅当是合法 JSON 顶层对象时回传，否则返 "null"（避免 OC 异常崩溃，对齐 APIClient）
        if let raw = env["result"], JSONSerialization.isValidJSONObject(raw) {
            return (try? JSONSerialization.data(withJSONObject: raw)) ?? Data("null".utf8)
        }
        return Data("null".utf8)
    }
}

/// sapi 链路业务错误
enum PartyAPIError: Error, LocalizedError {
    case invalidURL
    case encryptFailed
    case networkError
    case httpStatus(Int)
    case envelopeParseFailed
    case business(code: String, message: String)
    case tokenExchangeFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "sapi: URL 非法"
        case .encryptFailed: return "sapi: 请求加密失败"
        case .networkError: return "sapi: 网络错误"
        case .httpStatus(let code): return "sapi: HTTP \(code)"
        case .envelopeParseFailed: return "sapi: 响应解析失败"
        case .business(let code, let message): return message.isEmpty ? "sapi: 业务失败 [\(code)]" : "sapi: [\(code)] \(message)"
        case .tokenExchangeFailed: return "sapi: token 续接失败"
        }
    }

    /// 业务码（供上层错误码分流，如 ROOM_SEAT_IS_OCCUPIED → 重拉对账）
    var businessCode: String? {
        if case .business(let code, _) = self { return code }
        return nil
    }
}
