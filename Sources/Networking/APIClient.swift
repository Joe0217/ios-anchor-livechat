import Foundation
import UIKit
import os

/// 业务错误（非 0000）。
struct APIError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// 与 H5 对齐的 HTTP 客户端：公共头 + 请求体 AES(Base64) 加密 + 响应 result(Hex) 解密 + 错误码处理。
final class APIClient {
    static let shared = APIClient()
    private let session: URLSession

    /// 默认 init：生产 / 真机走 default config 即可。
    /// 单测从这里注入 ephemeral + URLProtocol mock 的 session，对 envelope 解码/错误码分流做断言。
    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    /// POST 请求。body 会被 JSON 序列化 → AES → Base64 作为原始 body 发送。
    /// 返回解密后的 result JSON 数据（供 Codable 解码）；非 0000 抛 APIError。
    ///
    /// - parameter suppressCodes: 对指定错误码**不** post `.apiSessionInvalidated` 通知
    ///   （对齐 A-2 spec §1.3 v3：login 挂 code=1005 用于跳注册页时须传 `["1005"]`，
    ///   否则 SessionStore observer 会先跑 logout 拦截分流；仅 login path 需传，其它场景 default []）
    func post(_ path: String, body: [String: Any]? = nil, token: String? = nil, suppressCodes: Set<String> = []) async throws -> Data {
        try await postJSON(path, jsonBody: body, token: token, suppressCodes: suppressCodes)
    }

    /// POST 请求（array body 版）。对齐 H5 `http.post(path, arrayData)` — uploadPrivateInfo 等接口用。
    /// 加密链路与 dict 版完全一致（`JSONSerialization` 对 array/dict 都是 valid JSON object）。
    func post(_ path: String, arrayBody: [Any], token: String? = nil, suppressCodes: Set<String> = []) async throws -> Data {
        try await postJSON(path, jsonBody: arrayBody, token: token, suppressCodes: suppressCodes)
    }

    /// dict / array 共用的加密 + 发送内核。
    private func postJSON(_ path: String, jsonBody: Any?, token: String?, suppressCodes: Set<String>) async throws -> Data {
        // 首次冷启动前若系统权限对话框「允许使用无线数据」尚未通过,
        // URLSession 会立即失败 —— 让请求等到网络真正可达再发出(10s 超时兜底走原错误路径)
        await NetworkReachability.shared.waitUntilReachable()
        guard let url = URL(string: AppConfig.apiBaseURL + path) else {
            throw APIError(code: "-1", message: "非法 URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        let headers = commonHeaders(token: token)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        if let body = jsonBody {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let jsonStr = String(decoding: jsonData, as: UTF8.self)
            guard let encrypted = CryptoUtil.aesEncryptToBase64(jsonStr) else {
                throw APIError(code: "-1", message: "请求加密失败")
            }
            req.httpBody = Data(encrypted.utf8)
        }

        // 诊断日志：DEBUG 包裹 + token/响应体走 .private，避免 Release 经 USB Console 泄露
        #if DEBUG
        let tk = headers["loginToken"] ?? ""
        let tkInfo = tk.isEmpty ? "empty" : "len=\(tk.count)"
        AppLogger.net.debug("POST \(path, privacy: .public) loginToken=\(tkInfo, privacy: .private) appid=\(headers["appid"] ?? "-", privacy: .public)")
        #endif

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            // Task cancel / URLError.cancelled 是用户/系统主动打断（切页、logout、二次刷新前 cancel 旧任务），
            // 不弹 banner；直接向上抛。
            if GlobalErrorBannerNotify.isCancellation(error) { throw error }
            AppLogger.net.error("network error path=\(path, privacy: .public): \(String(describing: error), privacy: .public)")
            #if !HILY_TESTS
            GlobalErrorBannerNotify.post(message: L10n.apiNetworkError, path: path)
            #endif
            throw error
        }

        #if DEBUG
        let respPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary>"
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        AppLogger.net.debug("RESP \(path, privacy: .public) status=\(statusCode, privacy: .public) len=\(data.count, privacy: .public) body=\(String(respPreview), privacy: .private)")
        #endif

        // 走公用 decodeEnvelope：内部处理 HTTP 非 2xx（先试 envelope）+ envelope-parse-fail + 业务码分流
        return try decodeEnvelope(data, path: path, httpStatus: (resp as? HTTPURLResponse)?.statusCode, suppressCodes: suppressCodes)
    }

    /// GET 请求。query 参数走 URL query string；无请求体加密（对齐 H5 `http.get(...)`）。
    /// 响应处理路径与 POST 完全一致（envelope 解析 + 1004/1005 分流 + result Hex 解密）。
    ///
    /// **接入 wishlist 后端时的诊断**：后端严格 method 校验；POST 请求会返
    /// `{"code":"1111","message":"Please check your method type, Maybe it's GET"}`。
    func get(_ path: String, query: [String: Any]? = nil, token: String? = nil, suppressCodes: Set<String> = []) async throws -> Data {
        await NetworkReachability.shared.waitUntilReachable()
        var components = URLComponents(string: AppConfig.apiBaseURL + path)
        if let query, !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        }
        guard let url = components?.url else {
            throw APIError(code: "-1", message: "非法 URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        for (k, v) in commonHeaders(token: token) { req.setValue(v, forHTTPHeaderField: k) }

        #if DEBUG
        AppLogger.net.debug("GET \(path, privacy: .public) query=\(String(describing: query), privacy: .public)")
        #endif

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            // Task cancel / URLError.cancelled：不弹 banner，向上抛
            if GlobalErrorBannerNotify.isCancellation(error) { throw error }
            AppLogger.net.error("network error path=\(path, privacy: .public): \(String(describing: error), privacy: .public)")
            #if !HILY_TESTS
            GlobalErrorBannerNotify.post(message: L10n.apiNetworkError, path: path)
            #endif
            throw error
        }

        #if DEBUG
        let respPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary>"
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        AppLogger.net.debug("RESP \(path, privacy: .public) status=\(statusCode, privacy: .public) len=\(data.count, privacy: .public) body=\(String(respPreview), privacy: .private)")
        #endif

        return try decodeEnvelope(data, path: path, httpStatus: (resp as? HTTPURLResponse)?.statusCode, suppressCodes: suppressCodes)
    }

    /// DELETE 请求。id 走 URL path（对齐 H5 `http.delete(<path>/<id>)`），无请求体，响应处理同 POST。
    /// **stage 3 接入**：wishlist `deleteWishPromiseItem(id)` 走此方法。
    func delete(_ path: String, token: String? = nil, suppressCodes: Set<String> = []) async throws -> Data {
        await NetworkReachability.shared.waitUntilReachable()
        guard let url = URL(string: AppConfig.apiBaseURL + path) else {
            throw APIError(code: "-1", message: "非法 URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 30
        for (k, v) in commonHeaders(token: token) { req.setValue(v, forHTTPHeaderField: k) }

        #if DEBUG
        AppLogger.net.debug("DELETE \(path, privacy: .public)")
        #endif

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            // Task cancel / URLError.cancelled：不弹 banner，向上抛
            if GlobalErrorBannerNotify.isCancellation(error) { throw error }
            AppLogger.net.error("network error path=\(path, privacy: .public): \(String(describing: error), privacy: .public)")
            #if !HILY_TESTS
            GlobalErrorBannerNotify.post(message: L10n.apiNetworkError, path: path)
            #endif
            throw error
        }

        #if DEBUG
        let respPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary>"
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        AppLogger.net.debug("RESP \(path, privacy: .public) status=\(statusCode, privacy: .public) len=\(data.count, privacy: .public) body=\(String(respPreview), privacy: .private)")
        #endif

        return try decodeEnvelope(data, path: path, httpStatus: (resp as? HTTPURLResponse)?.statusCode, suppressCodes: suppressCodes)
    }

    /// Envelope 解析 + 1004/1005 分流 + result Hex 解密。POST/GET/DELETE 三个 method 共用。
    /// 抽出为 private helper 避免代码重复（原 POST 内联相同逻辑保留不动，防止意外破坏稳定路径）。
    ///
    /// - parameter httpStatus: HTTP status code（可选，用于诊断日志区分"200 body 空"vs"5xx body 空"）
    /// - parameter suppressCodes: 对指定错误码不 post `.apiSessionInvalidated` 通知（A-2 spec v3 BLOCK-1）
    private func decodeEnvelope(_ data: Data, path: String, httpStatus: Int? = nil, suppressCodes: Set<String> = []) throws -> Data {
        // 先尝试 envelope 解析：即便 HTTP 非 2xx（如 401/403/500 携带 code=1004/1005 body），
        // 也要走业务码分流；解析不出才 fallback HTTP status 分支。
        let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        // envelope 完全解不出：区分 HTTP 非 2xx（server error 文案）vs 2xx 但 body 非 JSON（parse-failure 文案）
        guard let env = envelope else {
            let sc = httpStatus ?? 0
            AppLogger.net.error("envelope parse failed path=\(path, privacy: .public) status=\(sc, privacy: .public) len=\(data.count, privacy: .public)")
            let isNon2xx = !(200...299).contains(sc)
            #if !HILY_TESTS
            let bannerMsg = isNon2xx ? L10n.apiServerErrorFormat(sc) : L10n.apiResponseParseFailed
            GlobalErrorBannerNotify.post(message: bannerMsg, path: path, status: sc)
            #endif
            #if HILY_TESTS
            throw APIError(code: "-1", message: isNon2xx ? "HTTP \(sc)" : "response parse failed")
            #else
            throw APIError(code: "-1", message: isNon2xx ? "HTTP \(sc)" : L10n.apiResponseParseFailed)
            #endif
        }
        let code = env["code"] as? String ?? ""
        let message = env["message"] as? String ?? ""

        guard code == "0000" else {
            if (code == "1004" || code == "1005"), !suppressCodes.contains(code) {
                NotificationCenter.default.post(
                    name: .apiSessionInvalidated,
                    object: nil,
                    userInfo: ["code": code, "message": message]
                )
            }
            // 业务码非 0000：post 通用 banner（后端 message 优先，空则用 code 兜底避免落 parse-failure 文案）；
            // suppressCodes 里的码不弹；1004/1005 由 SessionStore observer 独立处理
            #if !HILY_TESTS
            if !suppressCodes.contains(code) && code != "1004" && code != "1005" {
                let bannerMsg = message.isEmpty ? L10n.apiRequestFailedFormat(code) : message
                GlobalErrorBannerNotify.post(message: bannerMsg, path: path, status: httpStatus ?? 0)
            }
            #endif
            throw APIError(code: code, message: message.isEmpty ? "请求失败(\(code))" : message)
        }

        if let hex = env["result"] as? String, !hex.isEmpty,
           let decrypted = CryptoUtil.aesDecryptFromHex(hex),
           let out = decrypted.data(using: .utf8) {
            return out
        }
        if let raw = env["result"], JSONSerialization.isValidJSONObject(raw) {
            return (try? JSONSerialization.data(withJSONObject: raw)) ?? Data("null".utf8)
        }
        return Data("null".utf8)
    }

    // MARK: - 公共请求头（对应 H5 请求拦截器）

    private func commonHeaders(token: String?) -> [String: String] {
        let t = token ?? AuthToken.value ?? ""
        return [
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
            "loginToken": t,
            "anchorToken": t,
        ]
    }
}

/// A 收尾：APIClient 层 1004/1005 集中分流通知名。
/// SessionStore 在 init 时挂 observer → 自动 logout + 设置 errorMessage 给 UI。
extension Notification.Name {
    static let apiSessionInvalidated = Notification.Name("APIClient.sessionInvalidated")

    /// envelope 解析失败 → 全局顶部错误 banner（GlobalErrorBannerStore observer 消费）。
    /// APIClient / PartyAPIClient / SapiTokenStore 三链路的 envelope 解析失败点共用。
    /// `userInfo["path"]` 为触发路径，便于诊断（banner 内不展示，仅供 log 关联）。
    static let apiResponseParseFailed = Notification.Name("APIClient.responseParseFailed")

    /// 通用请求失败 → 全局顶部错误 banner（GlobalErrorBannerStore observer 消费）。
    /// APIClient / PartyAPIClient / SapiTokenStore 在 network error / HTTP non-2xx /
    /// envelope 解析失败 / 业务码非成功 四类错误抛出点 post。
    /// `userInfo["message"]` (String) 为展示文案：优先后端 `message`，无则用 L10n 兜底；
    /// `userInfo["path"]` (String) / `userInfo["status"]` (Int) 供诊断日志关联。
    static let apiRequestFailed = Notification.Name("APIClient.requestFailed")
}

/// 底层统一 helper：任意 nonisolated 线程触发全局顶部 banner。
/// 3 个网络客户端 4 类错误点共用；GlobalErrorBannerStore observer 内部做 3s 合并去重。
enum GlobalErrorBannerNotify {
    /// - parameter message: 展示文案。空串走 observer 侧的 L10n 兜底。
    /// - parameter path: 触发路径（诊断用，不展示）
    /// - parameter status: HTTP status code（诊断用）
    static func post(message: String, path: String, status: Int = 0) {
        var info: [String: Any] = ["path": path, "status": status]
        if !message.isEmpty { info["message"] = message }
        NotificationCenter.default.post(name: .apiRequestFailed, object: nil, userInfo: info)
    }

    /// 判定错误是否为"用户/系统主动取消"（Task cancel / view dismiss / logout 触发的 URLSession 打断）。
    /// 三网络客户端 catch 里用此过滤，避免为用户主动 cancel 触发 banner。
    /// 覆盖 CancellationError（Swift 并发原生）+ URLError.cancelled（Foundation code -999）。
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

/// 设备标识：本地生成一次并持久化（对应 H5 deviceInfo-V2）。
///
/// **v2 起改 Keychain + ThisDeviceOnly + Synchronizable=false**（P2-9 修复）：
/// - 防 App 卸载重装换 UUID 导致后端反作弊/封号策略失效
/// - 防 iCloud 备份恢复到新设备还原老 UUID 导致跨设备同 deviceId 触发风控误判
/// - v1（UserDefaults `device.uuid.v1`）→ v2（Keychain `device.uuid.v2`）一次性迁移：
///   首次访问时若 Keychain 无值但 UserDefaults 有，搬迁到 Keychain 后清掉 UserDefaults
///
/// **性能**：用 `static let` 让 Swift runtime 保证 dispatch_once thread-safe lazy init，
/// 整个 app 进程内仅查一次 Keychain（SecItemCopyMatching ~0.5-2ms），后续访问近乎 free。
/// 没有 lock 开销。deviceId 是请求 header 高频字段（直播态每秒 4-10 次访问），
/// 不缓存的方案每秒会累积 5-20ms 系统调用 + 上下文切换。
enum DeviceInfo {
    private static let v2Key = "device.uuid.v2"
    private static let v1Key = "device.uuid.v1"

    static let deviceId: String = {
        // v2: Keychain（持久跨重装；ThisDeviceOnly 不进 iCloud 备份）
        if let v = KeychainStore.getString(for: v2Key), !v.isEmpty { return v }
        // v1 → v2 一次性迁移：必须 verify Keychain 写入成功**后**再删 v1，
        // 否则 Keychain 写失败（极端：device 未首次解锁 / Keychain 异常）会导致
        // v1 已删 + v2 未写 → 下次启动重生 UUID → 设备身份漂移触发风控误判
        if let legacy = UserDefaults.standard.string(forKey: v1Key), !legacy.isEmpty {
            if KeychainStore.setString(legacy, for: v2Key) {
                UserDefaults.standard.removeObject(forKey: v1Key)
            }
            // 即便写 Keychain 失败也返回 legacy（本次进程仍能正常用，下次启动重试迁移）
            return legacy
        }
        // 全新设备：生成 UUID 写 Keychain；写失败时本次进程使用该 UUID，
        // 下次启动再重新生成（极端 corner case，acceptable）
        let v = UUID().uuidString
        KeychainStore.setString(v, for: v2Key)
        return v
    }()
}

/// 登录 token 的持久化（Keychain，v2 起），供 APIClient 非主线程取用、自动附带到请求头。
/// 由 SessionStore 在登录/登出时写入。
/// v1（UserDefaults）→ v2（Keychain）一次性迁移：getter 命中旧键时自动搬迁后清空。
enum AuthToken {
    private static let key = "auth.token.v2"
    private static let legacyKey = "auth.token.v1"

    static var value: String? {
        get {
            if let v = KeychainStore.getString(for: key) { return v }
            // 一次性迁移：旧 UserDefaults 残留 → Keychain，迁完清旧
            if let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty {
                KeychainStore.setString(legacy, for: key)
                UserDefaults.standard.removeObject(forKey: legacyKey)
                return legacy
            }
            return nil
        }
        set {
            if let v = newValue, !v.isEmpty {
                KeychainStore.setString(v, for: key)
            } else {
                KeychainStore.remove(for: key)
            }
        }
    }
}
