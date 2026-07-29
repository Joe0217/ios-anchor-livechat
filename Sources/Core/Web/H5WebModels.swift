import Foundation
import UIKit
import WebKit

/// 通用 H5 容器的页面描述。业务方只提供页面与上下文，不直接触碰 WKWebView。
struct H5Page: Identifiable {
    enum BridgeMode {
        /// 普通网页可在容器内打开，但不会获得 App token 或 JS Bridge。
        case disabled
        /// 仅在精确匹配的 HTTPS Origin 上注入 Bridge。
        case trusted(H5TrustedOriginPolicy)
    }

    let id: UUID
    let url: URL
    let title: String?
    let bridgeMode: BridgeMode
    let runtimeContext: H5RuntimeContext

    init(id: UUID = UUID(),
         url: URL,
         title: String? = nil,
         bridgeMode: BridgeMode = .disabled,
         runtimeContext: H5RuntimeContext) {
        self.id = id
        self.url = url
        self.title = title
        self.bridgeMode = bridgeMode
        self.runtimeContext = runtimeContext
    }

    /// 页面构造发生在 SwiftUI 主线程；在此处读取会话态，避免默认参数在非隔离调用点求值。
    @MainActor
    init(id: UUID = UUID(),
         url: URL,
         title: String? = nil,
         bridgeMode: BridgeMode = .disabled) {
        self.init(
            id: id,
            url: url,
            title: title,
            bridgeMode: bridgeMode,
            runtimeContext: .current()
        )
    }

    func allowsBridge(for url: URL) -> Bool {
        guard case .trusted(let policy) = bridgeMode else { return false }
        return policy.allows(url)
    }
}

/// Bridge 必须匹配完整 HTTPS origin，不能按后缀或任意 backend URL 放行。
struct H5TrustedOriginPolicy: Hashable {
    private let origins: Set<String>

    init(origins: Set<URL>) {
        self.origins = Set(origins.compactMap(Self.normalizedOrigin))
    }

    /// 已确认的用户协议/隐私政策站点。活动域名需在接入该业务时显式加入，不能由后端 URL 自动信任。
    static let liveHot = H5TrustedOriginPolicy(origins: [URL(string: "https://h5.livehot.site")!])
    func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let origin = Self.normalizedOrigin(url) else { return false }
        return origins.contains(origin)
    }

    private static func normalizedOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "https" else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}

/// 原生端直接复用的完整主播 H5 页面。完整 H5 使用 history 路由，不能拼 `#/...`。
enum H5EmbeddedFeature: String {
    case anchorGuide = "anchorGuide"
    case invite
    case wallet

    func url(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, rawValue].filter { !$0.isEmpty }.joined(separator: "/"))
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// H5 通过 `getAppParams` 获取的运行时参数。敏感字段只进入受信任页面的 JS 内存，绝不拼接 URL。
struct H5RuntimeContext {
    let token: String
    let apiToken: String
    let authToken: String
    let appId: String
    let acceptLanguage: String
    let deviceType: String
    let deviceId: String
    let osType: String
    let osVersion: String
    let embeddedWebFeature: Bool
    let roomId: String
    let roomType: String
    let requestParams: [String: String]
    let reportParams: [String: String]

    @MainActor
    static func current(roomId: String = "",
                        roomType: String = "",
                        embeddedWebFeature: Bool = false,
                        requestParams: [String: String] = [:],
                        reportParams: [String: String] = [:]) -> H5RuntimeContext {
        H5RuntimeContext(
            // 完整主播 H5 的常规运行时上下文。活动页不得使用这个上下文，避免把 App 主会话交给 WebView。
            token: SessionStore.shared.user?.loginUuid ?? "",
            apiToken: SessionStore.shared.user?.token ?? "",
            authToken: SapiTokenStore.shared.authToken ?? "",
            appId: AppConfig.appId,
            acceptLanguage: AppLocaleStore.shared.effectiveLanguage.rawValue,
            deviceType: "iPhone",
            deviceId: DeviceInfo.deviceId,
            osType: "iOS",
            osVersion: UIDevice.current.systemVersion,
            embeddedWebFeature: embeddedWebFeature,
            roomId: roomId,
            roomType: roomType,
            requestParams: requestParams,
            reportParams: reportParams
        )
    }

    /// 对齐活动 H5 的受限认证上下文。
    ///
    /// 活动页用 `loginUuid` 发起自身的加密请求；绝不向页面提供 App 主登录 token 或 SAPI token。
    /// `apiToken` 保留为 `loginUuid` 是对现有完整 H5 `tokenManager` 的兼容字段，不能改为主 token。
    @MainActor
    static func activity() -> H5RuntimeContext {
        let loginUuid = SessionStore.shared.user?.loginUuid ?? ""
        return H5RuntimeContext(
            token: loginUuid,
            apiToken: loginUuid,
            authToken: "",
            appId: AppConfig.appId,
            acceptLanguage: AppLocaleStore.shared.effectiveLanguage.rawValue,
            deviceType: "iPhone",
            deviceId: DeviceInfo.deviceId,
            osType: "iOS",
            osVersion: UIDevice.current.systemVersion,
            embeddedWebFeature: false,
            roomId: "",
            roomType: "",
            requestParams: [:],
            reportParams: [:]
        )
    }

    func jsonString() -> String? {
        let value: [String: Any] = [
            "type": "getAppParams",
            "token": token,
            "loginUuid": token,
            "apiToken": apiToken,
            "auth_token": authToken,
            "appId": appId,
            "clientType": "anchor",
            "platform": "ios",
            "acceptLanguage": acceptLanguage,
            "Accept-Language": acceptLanguage,
            "deviceType": deviceType,
            "deviceId": deviceId,
            "deviceNo": deviceId,
            "osType": osType,
            "osVersion": osVersion,
            "embeddedWebFeature": embeddedWebFeature,
            "roomId": roomId,
            "roomType": roomType,
            "requestParams": requestParams,
            "reportParams": reportParams,
            "debug": Self.isDebugBuild,
        ]
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

extension H5Page {
    /// 三个嵌入功能共享受信任 origin、运行时认证和服务隔离标记。
    @MainActor
    static func embeddedFeature(_ feature: H5EmbeddedFeature, title: String) -> H5Page? {
        guard let baseURL = AppConfig.webFeatureBaseURL,
              let url = feature.url(baseURL: baseURL) else {
            return nil
        }
        return H5Page(
            url: url,
            title: title,
            bridgeMode: .trusted(H5TrustedOriginPolicy(origins: [baseURL])),
            runtimeContext: .current(embeddedWebFeature: true)
        )
    }
}

enum H5WebState: Equatable {
    case loading(progress: Double)
    case loaded
    case failed(message: String)
}

enum H5ExternalURLPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "https":
            return url.host != nil
        case "tel", "mailto", "sms":
            return true
        default:
            return false
        }
    }
}

/// Core 层只定义协议动作；宿主注入处理闭包，决定如何映射到本 App 的各业务路由。
enum H5BridgeAction {
    case requestAppParams
    case close
    case setNavigationVisible(Bool)
    case report(event: String, properties: [String: String])
    case openExternal(URL)
    case jumpWallet
    case jumpRanking(pageType: String?, hideMonthTab: Bool)
    case goLive
    case goRoom(roomId: String?)
    case goProfile(userId: String?)
    case unsupported(type: String)
}

enum H5WebSession {
    private static let lock = NSLock()
    private static var pendingClearCallbacks: [() -> Void]?

    /// 登出时调用，清掉 H5 的 cookie / LocalStorage / IndexedDB，避免下一账号继承网页会话。
    static func clear() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        lock.lock()
        if pendingClearCallbacks != nil {
            lock.unlock()
            return
        }
        pendingClearCallbacks = []
        lock.unlock()

        store.removeData(ofTypes: types, modifiedSince: .distantPast) {
            finishPendingClear()
        }
    }

    /// 新 H5 页面在登出清理完成后再加载，避免快速切号时读到上一账号的 WebsiteData。
    static func runAfterPendingClear(_ action: @escaping () -> Void) {
        lock.lock()
        if pendingClearCallbacks != nil {
            pendingClearCallbacks?.append(action)
            lock.unlock()
            return
        }
        lock.unlock()
        DispatchQueue.main.async {
            action()
        }
    }

    private static func finishPendingClear() {
        lock.lock()
        let callbacks = pendingClearCallbacks ?? []
        pendingClearCallbacks = nil
        lock.unlock()

        callbacks.forEach { callback in
            DispatchQueue.main.async {
                callback()
            }
        }
    }
}
