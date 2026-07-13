import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "translate-service")

/// H-3 消息翻译服务（spec §1.3 / §4.7）。
///
/// **端点**（对齐 H5 `api/home/index.ts:48-67` 直连微软，不走 APIClient）：
/// `POST https://api.cognitive.microsofttranslator.com/translate?to={lang}&api-version=3.0`
///
/// **headers**：
/// - `Ocp-Apim-Subscription-Key: <TranslateConfigBridge.key>`（从 AppConfigStore.microsoft_translator_config 二次 parse 拿）
/// - `Ocp-Apim-Subscription-Region: <TranslateConfigBridge.area>`（v2 Major-2：H5 字段是 area，不是 region）
/// - `Content-Type: application/json`
///
/// **body**：`[{"Text": <original text>}]`（数组包装，对齐 H5）
/// **response**：`[{translations: [{text: string, to: string}], detectedLanguage?}]` —— 取 `res[0].translations[0].text`
protocol TranslateServiceProtocol: Sendable {
    func translate(text: String, targetLang: String, key: String, area: String) async throws -> String
}

/// H-3 微软翻译真实现（URLSession 直调）。
///
/// **注意**：URLSession 交互留 Step 3 真机验证（S5 spike：CORS / ATS 例外）；本层单测只测响应解析纯函数
/// `parseTranslatedText(from:)`（无网络依赖）。
struct MicrosoftTranslateService: TranslateServiceProtocol, Sendable {
    static let shared = MicrosoftTranslateService(session: .shared)

    let session: URLSession
    let endpointBase: URL = URL(string: "https://api.cognitive.microsofttranslator.com/translate")!

    func translate(text: String, targetLang: String, key: String, area: String) async throws -> String {
        guard !key.isEmpty, !area.isEmpty else {
            throw TranslateServiceError.missingConfig
        }

        // 构造 URL with query params
        var comps = URLComponents(url: endpointBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "to", value: targetLang),
            URLQueryItem(name: "api-version", value: "3.0"),
        ]
        guard let url = comps.url else {
            throw TranslateServiceError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue(area, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // body: [{"Text": text}]
        let body: [[String: String]] = [["Text": text]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8)
            // S-4:bodyStr 可能含请求文本片段(用户聊天原文),降级 .private 避免 sysdiagnose 泄漏;status 保 .public 便于定位
            logger.warning("[Translate] non-2xx status=\(http.statusCode) body=\(bodyStr ?? "nil", privacy: .private)")
            throw TranslateServiceError.httpError(status: http.statusCode, body: bodyStr)
        }

        return try Self.parseTranslatedText(from: data)
    }

    /// **响应解析纯函数**（单测覆盖点；解析层与网络层分离）。
    ///
    /// 对齐 H5 `c-translate.vue`：`emit('getTranslateRes', res[0].translations[0].text)`
    ///
    /// - Throws: `TranslateServiceError.invalidResponse` 若响应结构不符预期
    static func parseTranslatedText(from data: Data) throws -> String {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let firstItem = arr.first,
              let translations = firstItem["translations"] as? [[String: Any]],
              let firstTrans = translations.first,
              let text = firstTrans["text"] as? String
        else {
            throw TranslateServiceError.invalidResponse
        }
        return text
    }
}

enum TranslateServiceError: Error, Equatable {
    case missingConfig       // key / area 缺失（AppConfigStore 未 loaded 或 config 无值）
    case invalidURL
    case invalidResponse     // 响应结构不符预期
    case httpError(status: Int, body: String?)
}
