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
/// - 鉴权：`auth_token` 头（来自 `SapiTokenStore`）+ `loginToken` / `anchorToken`（主 token）
/// - 加密 key/iv：`AppConfig.sapiAesKey/IV`（由本地环境配置注入）
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

    /// POST 请求。body 走 sapi AES key/iv 加密 → Base64，再按 H5 Axios 行为封为 JSON string body。
    /// 返回解密后的 result JSON（供 Codable）；非 '200' 抛 `PartyAPIError.business`。
    /// HTTP 401 自动续 token 并 retry 一次；仍 401 抛 `PartyAPIError.tokenExchangeFailed`。
    ///
    /// - parameter suppressCodes: 业务码白名单，命中的 code 不 post 全局 banner
    ///   （用于业务侧已有独立处理的 code：如 ROOM_SEAT_IS_OCCUPIED 自动重拉对账、
    ///    ROOM_PASSWORD_WRONG 密码 sheet 内联、1019 diamond not enough 独立充值弹窗）
    func post(_ path: String, body: [String: Any]? = nil, suppressCodes: Set<String> = []) async throws -> Data {
        try await send(method: "POST", path: path, body: body, query: nil, isRetry: false, suppressCodes: suppressCodes)
    }

    /// GET 请求（F-1a 2026-07-17 加：sapi 域部分端点强制 GET，如 party/battle/templates、
    /// party/battle/applications；POST 会返 HTTP 405 "Request method POST is not supported"）。
    ///
    /// GET 无 body 加密；query 参数拼到 URL；响应 envelope 同 POST（若后端 GET 也返
    /// `{code:'200', result: hex}` 走 result 解密；否则 result 若为 JSON dict/array 直接 return）。
    func get(_ path: String, query: [String: String]? = nil, suppressCodes: Set<String> = []) async throws -> Data {
        try await send(method: "GET", path: path, body: nil, query: query, isRetry: false, suppressCodes: suppressCodes)
    }

    private func send(method: String, path: String, body: [String: Any]?, query: [String: String]?, isRetry: Bool, suppressCodes: Set<String> = []) async throws -> Data {
        // 首次冷启动前等到系统「允许使用无线数据」权限对话框通过再发请求(10s 超时兜底走原错误路径)
        await NetworkReachability.shared.waitUntilReachable()

        // GET 请求：query 参数拼 URL
        var finalPath = path
        if method == "GET", let q = query, !q.isEmpty {
            var comps = URLComponents()
            comps.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let queryStr = comps.percentEncodedQuery {
                let sep = path.contains("?") ? "&" : "?"
                finalPath = path + sep + queryStr
            }
        }
        guard let url = URL(string: AppConfig.sapiBaseURL + finalPath) else {
            throw PartyAPIError.invalidURL
        }

        // 确保 auth_token 有效（首次访问 / 已过期时自动 exchange；并发合并）
        let authToken: String?
        do {
            authToken = try await SapiTokenStore.shared.ensureValid()
        } catch {
            // Task cancel / URLError.cancelled：调用方已放弃，直接向上抛不再发请求
            if GlobalErrorBannerNotify.isCancellation(error) { throw error }
            AppLogger.party.error("[PartyAPI] ensureValid failed: \(String(describing: error), privacy: .private)")
            // 续 token 失败不阻塞调用（让请求带 nil auth_token 走，让服务端返 401 走 retry 链路决定终态）
            authToken = nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        let headers = SapiTokenStore.sapiHeaders(authToken: authToken, loginToken: AuthToken.value)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        // GET 无 body 加密，跳过下方 body 处理段
        if method == "POST", let body = body {
            // 守护：JSONSerialization 对 NSNull / 非合法顶层对象会抛 OC 异常且 try? 不接（CLAUDE.md 已知坑）
            guard JSONSerialization.isValidJSONObject(body) else {
                throw PartyAPIError.encryptFailed
            }
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let jsonStr = String(decoding: jsonData, as: UTF8.self)
            #if DEBUG
            // 加密前明文 payload —— 排查"请求参数与 H5 是否一致"用
            AppLogger.party.debug("REQ-PAYLOAD \(path, privacy: .public) body=\(jsonStr, privacy: .private)")
            #endif
            guard let encrypted = CryptoUtil.aesEncryptToBase64(jsonStr, key: AppConfig.sapiAesKey, iv: AppConfig.sapiAesIV) else {
                throw PartyAPIError.encryptFailed
            }
            // H5 `sapiIndex.ts` 先将 data 改为 Base64 string；Axios 发现 Content-Type 为
            // application/json 后通过 stringifySafely 再执行 JSON.stringify(string)。
            // 服务端对该 JSON string 的反序列化路径与裸 Base64 不同，必须保留外层引号。
            req.httpBody = try SapiTokenStore.jsonWrappedEncryptedBody(encrypted)
        }

        #if DEBUG
        let tk = headers["auth_token"] ?? ""
        let tkInfo = tk.isEmpty ? "empty" : "len=\(tk.count)"
        AppLogger.party.debug("\(method, privacy: .public) \(finalPath, privacy: .public) auth_token=\(tkInfo, privacy: .private) retry=\(isRetry, privacy: .public)")
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // Task cancel / URLError.cancelled：不弹 banner，向上抛
            if GlobalErrorBannerNotify.isCancellation(error) { throw error }
            AppLogger.party.error("[PartyAPI] session.data threw for \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            GlobalErrorBannerNotify.post(message: L10n.apiNetworkError, path: path)
            throw PartyAPIError.networkError
        }
        guard let http = response as? HTTPURLResponse else {
            GlobalErrorBannerNotify.post(message: L10n.apiNetworkError, path: path)
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
                notifySessionInvalidated(message: "SAPI request still unauthorized after token exchange")
                throw PartyAPIError.tokenExchangeFailed
            }
            AppLogger.party.notice("[PartyAPI] 401 → exchange token + retry")
            do {
                _ = try await SapiTokenStore.shared.ensureValid(forceRefresh: true)
            } catch {
                // Task cancel：直接向上抛
                if GlobalErrorBannerNotify.isCancellation(error) { throw error }
                // SAPI token 无法续接时，主会话也不再可用；复用 1004 的统一登出链路。
                notifySessionInvalidated(message: "SAPI token exchange failed")
                throw PartyAPIError.tokenExchangeFailed
            }
            return try await send(method: method, path: path, body: body, query: query, isRetry: true, suppressCodes: suppressCodes)
        }

        // 其他非 200 HTTP（403/404/500 等）：先尝试解析 envelope 拿 code；
        // 拿不到才走 HTTP status 兜底文案。
        if http.statusCode != 200 {
            if let env = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let code = env["code"] as? String, !code.isEmpty, code != "200" {
                let message = (env["message"] as? String) ?? ""
                if !suppressCodes.contains(code) {
                    let bannerMsg = message.isEmpty ? L10n.apiRequestFailedFormat(code) : message
                    GlobalErrorBannerNotify.post(message: bannerMsg, path: path, status: http.statusCode)
                }
                throw PartyAPIError.business(code: code, message: message.isEmpty ? "请求失败(\(code))" : message)
            }
            GlobalErrorBannerNotify.post(message: L10n.apiServerErrorFormat(http.statusCode), path: path, status: http.statusCode)
            throw PartyAPIError.httpStatus(http.statusCode)
        }

        // envelope: { code: '200'(字符串), message, result(hex) }
        guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            GlobalErrorBannerNotify.post(message: L10n.apiResponseParseFailed, path: path, status: http.statusCode)
            throw PartyAPIError.envelopeParseFailed
        }
        let code = env["code"] as? String ?? ""
        let message = env["message"] as? String ?? ""

        guard code == "200" else {
            // 业务码非 200：post 通用 banner；suppressCodes 里的码不弹；空 message 用 code 兜底避免落 parse-failure 文案
            if !suppressCodes.contains(code) {
                let bannerMsg = message.isEmpty ? L10n.apiRequestFailedFormat(code) : message
                GlobalErrorBannerNotify.post(message: bannerMsg, path: path, status: http.statusCode)
            }
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

    /// SAPI 401 自动续接失败与主接口 1004 共用会话失效处理：
    /// SessionStore 负责提示、审核弹窗闸门与完整登出清理。
    private func notifySessionInvalidated(message: String) {
        NotificationCenter.default.post(
            name: .apiSessionInvalidated,
            object: nil,
            userInfo: ["code": "1004", "message": message]
        )
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
        case .envelopeParseFailed: return L10n.apiResponseParseFailed
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
