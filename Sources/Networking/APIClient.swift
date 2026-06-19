import Foundation
import UIKit

/// 业务错误（非 0000）。
struct APIError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// 与 H5 对齐的 HTTP 客户端：公共头 + 请求体 AES(Base64) 加密 + 响应 result(Hex) 解密 + 错误码处理。
final class APIClient {
    static let shared = APIClient()
    private let session = URLSession(configuration: .default)

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

        // 诊断日志：确认 token/appid 是否进了请求头
        let tk = headers["loginToken"] ?? ""
        print("➡️ [API] POST \(path) | loginToken=\(tk.isEmpty ? "❌空" : "len\(tk.count) 前8位=\(tk.prefix(8))…") | appid=\(headers["appid"] ?? "❌无")")

        let (data, _) = try await session.data(for: req)
        print("⬅️ [API] \(path) | 原始响应=\(String(data: data, encoding: .utf8)?.prefix(300) ?? "<非文本>")")

        guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(code: "-1", message: "响应解析失败")
        }
        let code = env["code"] as? String ?? ""
        let message = env["message"] as? String ?? ""

        guard code == "0000" else {
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

/// 登录 token 的轻量持久化（UserDefaults），供 APIClient 非主线程取用、自动附带到请求头。
/// 由 SessionStore 在登录/登出时写入。
enum AuthToken {
    private static let key = "auth.token.v1"
    static var value: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
