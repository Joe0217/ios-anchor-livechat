import Foundation
import UIKit
import WebKit
import Combine

/// 通用 H5 容器的页面描述。业务方只提供页面与上下文，不直接触碰 WKWebView。
struct H5Page: Identifiable {
    enum BridgeMode {
        /// 普通网页可在容器内打开，但不会获得 App token 或 JS Bridge。
        case disabled
        /// 仅在精确匹配的 HTTPS Origin 上注入 Bridge。
        case trusted(H5TrustedOriginPolicy)
    }

    /// 不同 H5 业务共享同一安全容器，但协议不能互相渗透。
    /// 活动页保留 Android 兼容的命名 handler；普通主播 H5 只使用 `App`。
    enum BridgeProfile: Equatable {
        case standard
        case activity
    }

    let id: UUID
    let url: URL
    let title: String?
    let bridgeMode: BridgeMode
    let bridgeProfile: BridgeProfile
    let runtimeContext: H5RuntimeContext

    init(id: UUID = UUID(),
         url: URL,
         title: String? = nil,
         bridgeMode: BridgeMode = .disabled,
         bridgeProfile: BridgeProfile = .standard,
         runtimeContext: H5RuntimeContext) {
        self.id = id
        self.url = url
        self.title = title
        self.bridgeMode = bridgeMode
        self.bridgeProfile = bridgeProfile
        self.runtimeContext = runtimeContext
    }

    /// 页面构造发生在 SwiftUI 主线程；在此处读取会话态，避免默认参数在非隔离调用点求值。
    @MainActor
    init(id: UUID = UUID(),
         url: URL,
         title: String? = nil,
         bridgeMode: BridgeMode = .disabled,
         bridgeProfile: BridgeProfile = .standard) {
        self.init(
            id: id,
            url: url,
            title: title,
            bridgeMode: bridgeMode,
            bridgeProfile: bridgeProfile,
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
    /// `hn-activity-h5` 的受控部署域。活动链接只能携带路径和查询，不能反向把任意来源升级成可信页面。
    static let activityH5 = H5TrustedOriginPolicy(origins: [URL(string: "https://h5-activity-common.pages.dev")!])
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
    case ranking = "rank"

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
    let loginUuid: String
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
            token: SessionStore.shared.user?.token ?? "",
            loginUuid: SessionStore.shared.user?.loginUuid ?? "",
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

    /// 对齐 Android `H5NativeInterface.getAppParams()` 的活动页上下文。
    /// `token` 是活动页请求拦截器写入 `loginToken` 的真实登录 token；`loginUuid` 单独保留。
    @MainActor
    static func activity(roomId: String = "",
                         roomType: String = "",
                         requestParams: [String: String] = [:],
                         reportParams: [String: String] = [:],
                         isInLiveRoom: Bool = false,
                         isInPartyRoom: Bool = false) -> H5RuntimeContext {
        let token = SessionStore.shared.user?.token ?? ""
        var activityRequestParams = requestParams
        activityRequestParams["isInLiveRoom"] = isInLiveRoom ? "true" : "false"
        activityRequestParams["isInPartyRoom"] = isInPartyRoom ? "true" : "false"
        return H5RuntimeContext(
            token: token,
            loginUuid: SessionStore.shared.user?.loginUuid ?? "",
            apiToken: token,
            authToken: SapiTokenStore.shared.authToken ?? "",
            appId: AppConfig.appId,
            acceptLanguage: AppLocaleStore.shared.effectiveLanguage.rawValue,
            deviceType: "iPhone",
            deviceId: DeviceInfo.deviceId,
            osType: "iOS",
            osVersion: UIDevice.current.systemVersion,
            embeddedWebFeature: false,
            roomId: roomId,
            roomType: roomType,
            requestParams: activityRequestParams,
            reportParams: reportParams
        )
    }

    func jsonString() -> String? {
        var value: [String: Any] = [
            "type": "getAppParams",
            "token": token,
            "loginUuid": loginUuid,
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
            "reportParams": serializedReportParams,
            "debug": Self.isDebugBuild,
        ]
        // Android uses `HashMap.putAll(requestParams)`. Keep the nested field for backwards
        // compatibility, then expose safe values at the top level without permitting override of
        // authentication or runtime metadata.
        let reservedKeys = Set(value.keys)
        for (key, requestValue) in requestParams where !reservedKeys.contains(key) {
            value[key] = requestValue
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private var serializedReportParams: String {
        guard JSONSerialization.isValidJSONObject(reportParams),
              let data = try? JSONSerialization.data(withJSONObject: reportParams),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
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

    @MainActor
    static func embeddedRanking(pageType: String?, hideMonthTab: Bool) -> H5Page? {
        guard let baseURL = AppConfig.webFeatureBaseURL,
              var url = H5EmbeddedFeature.ranking.url(baseURL: baseURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems: [URLQueryItem] = []
        if pageType?.uppercased() == "GAME_TASK" {
            queryItems.append(URLQueryItem(name: "from", value: "gameTask"))
        }
        if hideMonthTab {
            queryItems.append(URLQueryItem(name: "hideMonthTab", value: "1"))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let resolvedURL = components.url else { return nil }
        url = resolvedURL
        return H5Page(
            url: url,
            title: nil,
            bridgeMode: .trusted(H5TrustedOriginPolicy(origins: [baseURL])),
            runtimeContext: .current(embeddedWebFeature: true)
        )
    }

    /// 活动 URL 可以来自 IM/后端，但只有已审核的活动 origin 能拿到 bridge 和会话参数。
    @MainActor
    static func activity(url: URL, runtimeContext: H5RuntimeContext) -> H5Page? {
        guard H5TrustedOriginPolicy.activityH5.allows(url) else {
            AppLogger.net.notice("[H5Bridge] rejected untrusted activity origin")
            return nil
        }
        return H5Page(
            url: url,
            bridgeMode: .trusted(.activityH5),
            bridgeProfile: .activity,
            runtimeContext: runtimeContext
        )
    }

    /// Banner URL 来自后端，但只有明确受信任的完整主播 H5 或活动 H5 可得到 bridge。
    /// Android 对所有 Banner 统一传 `reportParams.path = banner`，房间归属不能覆盖这个来源语义。
    @MainActor
    static func banner(url: URL,
                       reportPath: String = "banner",
                       roomId: String = "",
                       roomType: String = "",
                       isInLiveRoom: Bool = false,
                       isInPartyRoom: Bool = false) -> H5Page {
        let reportParams = ["path": reportPath]
        if H5TrustedOriginPolicy.activityH5.allows(url),
           let page = H5Page.activity(
               url: url,
               runtimeContext: .activity(
                   roomId: roomId,
                   roomType: roomType,
                   reportParams: reportParams,
                   isInLiveRoom: isInLiveRoom,
                   isInPartyRoom: isInPartyRoom
               )
           ) {
            return page
        }
        if let baseURL = AppConfig.webFeatureBaseURL,
           H5TrustedOriginPolicy(origins: [baseURL]).allows(url) {
            return H5Page(
                url: url,
                bridgeMode: .trusted(H5TrustedOriginPolicy(origins: [baseURL])),
                runtimeContext: .current(embeddedWebFeature: true, reportParams: reportParams)
            )
        }
        return H5Page(
            url: url,
            bridgeMode: .disabled,
            runtimeContext: .current()
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
    case commonJump(className: String)
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

/// 活动 H5 已实现 `window.__actBridge.onMessage({type: 'REFRESH_TASK'})`。
/// 原生任务、充值或奖励流程完成后调用 `refreshTask()`，当前仍展示中的活动页会立即刷新任务进度。
enum H5ActivityBridge {
    static let refreshTaskNotification = Notification.Name("H5ActivityBridge.refreshTask")

    static func refreshTask() {
        NotificationCenter.default.post(name: refreshTaskNotification, object: nil)
    }
}

/// Core 只把受信任 H5 意图转换为有限的业务目的地；主 Tab 是唯一实际执行导航的位置。
/// 这样活动 sheet、全屏 H5 和未来入口不会各自维护一套不一致的跳转协议。
final class H5NativeActionRouter {
    enum Destination: Equatable {
        case wallet
        case ranking(pageType: String?, hideMonthTab: Bool)
        case liveSettings
        case partyRoom(id: String)
        case userProfile(id: String)
    }

    static let shared = H5NativeActionRouter()

    private let subject = PassthroughSubject<Destination, Never>()
    var publisher: AnyPublisher<Destination, Never> { subject.eraseToAnyPublisher() }

    private init() {}

    /// Returns false for actions that require a page-local handler, such as `GO_PROFILE`.
    @discardableResult
    func dispatch(_ action: H5BridgeAction) -> Bool {
        let destination: Destination
        switch action {
        case .jumpWallet:
            guard SelfPermissionBridge.shared.gate(.wallet, action: "h5JumpWallet") else {
                return false
            }
            destination = .wallet
        case .jumpRanking(let pageType, let hideMonthTab):
            guard SelfPermissionBridge.shared.gate(.homeDiscovery, action: "h5JumpRanking") else {
                return false
            }
            destination = .ranking(pageType: pageType, hideMonthTab: hideMonthTab)
        case .goLive:
            guard SelfPermissionBridge.shared.gate(.live, action: "h5GoLive") else {
                return false
            }
            destination = .liveSettings
        case .goRoom(let roomId):
            guard SelfPermissionBridge.shared.gate(.party, action: "h5GoRoom") else {
                return false
            }
            guard let roomId = roomId?.trimmingCharacters(in: .whitespacesAndNewlines), !roomId.isEmpty else {
                return false
            }
            destination = .partyRoom(id: roomId)
        case .goProfile(let userId):
            guard SelfPermissionBridge.shared.gate(.profileViewing, action: "h5GoProfile") else {
                return false
            }
            guard let userId = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty else {
                return false
            }
            destination = .userProfile(id: userId)
        case .commonJump(let className):
            // `hn-activity-h5` 当前唯一的 Android className 是开播设置页；未知类名绝不反射或拼 URL。
            guard className == "com.gzxkwl.livehot.page.activity.LiveSettingActivity" else {
                AppLogger.net.notice("[H5Bridge] rejected unsupported commonJump")
                return false
            }
            guard SelfPermissionBridge.shared.gate(.live, action: "h5CommonJumpLiveSettings") else {
                return false
            }
            destination = .liveSettings
        default:
            return false
        }

        // WKScriptMessage can arrive during a SwiftUI presentation transaction. Deferring one
        // run-loop lets the source sheet finish dismissing before a tab/path mutation begins.
        DispatchQueue.main.async { [weak self] in
            self?.subject.send(destination)
        }
        return true
    }
}
