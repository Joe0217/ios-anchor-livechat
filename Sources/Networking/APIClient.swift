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
    func post(_ path: String, body: [String: Any]? = nil, token: String? = nil) async throws -> Data {
        guard let url = URL(string: AppConfig.apiBaseURL + path) else {
            throw APIError(code: "-1", message: "非法 URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        let headers = commonHeaders(token: token)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        if let body = body {
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

        let (data, _) = try await session.data(for: req)

        #if DEBUG
        let respPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary>"
        AppLogger.net.debug("RESP \(path, privacy: .public) body=\(String(respPreview), privacy: .private)")
        #endif

        guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(code: "-1", message: "响应解析失败")
        }
        let code = env["code"] as? String ?? ""
        let message = env["message"] as? String ?? ""

        guard code == "0000" else {
            // A 收尾：1004 挤下线 / 1005 token 失效集中分流。
            // 单点 throw 前 post 通知，SessionStore 监听后统一 logout + 弹 UI 提示，
            // 业务层 catch APIError 仍可拿到原始 code/message（兼容现有错误处理代码）。
            if code == "1004" || code == "1005" {
                NotificationCenter.default.post(
                    name: .apiSessionInvalidated,
                    object: nil,
                    userInfo: ["code": code, "message": message]
                )
            }
            throw APIError(code: code, message: message.isEmpty ? "请求失败(\(code))" : message)
        }

        // 解密 result（Hex 密文）
        if let hex = env["result"] as? String, !hex.isEmpty,
           let decrypted = CryptoUtil.aesDecryptFromHex(hex),
           let out = decrypted.data(using: .utf8) {
            return out
        }
        // result 为空/非加密：仅当是合法 JSON 顶层对象（数组/字典）时回传，
        // 否则（null / 字符串 / 数字等）当作无数据，避免 JSONSerialization 抛 OC 异常崩溃
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
}

/// 设备标识：本地生成一次并持久化（对应 H5 deviceInfo-V2）。
enum DeviceInfo {
    static var deviceId: String {
        let key = "device.uuid.v1"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }
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
