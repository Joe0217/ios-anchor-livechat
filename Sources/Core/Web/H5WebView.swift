import SwiftUI
import UIKit
import WebKit

/// `WKWebView` 的安全承载。Bridge 只会在 `H5Page` 明确允许的 HTTPS origin 生效。
struct H5WebView: UIViewRepresentable {
    let page: H5Page
    let reloadGeneration: Int
    var allowsEdgeSwipeNavigation = false
    var navigationGestureState: H5WebNavigationGestureState? = nil
    let onAction: (H5BridgeAction) -> Void
    let onStateChange: (H5WebState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            page: page,
            reloadGeneration: reloadGeneration,
            allowsEdgeSwipeNavigation: allowsEdgeSwipeNavigation,
            navigationGestureState: navigationGestureState,
            onAction: onAction,
            onStateChange: onStateChange
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        if page.allowsBridge(for: page.url), let runtime = page.runtimeContext.jsonString() {
            contentController.addUserScript(
                WKUserScript(
                    source: Self.bridgeScript(runtimeJSON: runtime, trustedURL: page.url),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
            contentController.add(context.coordinator, name: "App")
        }

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        context.coordinator.attach(to: view)
        context.coordinator.loadInitialPage()
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.reloadGeneration != reloadGeneration {
            context.coordinator.reloadGeneration = reloadGeneration
            context.coordinator.loadInitialPage()
        }
        context.coordinator.setEdgeSwipeNavigationEnabled(allowsEdgeSwipeNavigation)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "App")
        view.configuration.userContentController.removeAllUserScripts()
        view.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let page: H5Page
        private let onAction: (H5BridgeAction) -> Void
        private let onStateChange: (H5WebState) -> Void
        private let navigationGestureState: H5WebNavigationGestureState?
        var reloadGeneration: Int
        private var allowsEdgeSwipeNavigation: Bool
        private weak var webView: WKWebView?
        private var progressObservation: NSKeyValueObservation?
        private var pendingState: H5WebState?
        private var isStateDeliveryScheduled = false
        private var loadRequestID = 0
        private var webContentTerminationReloadCount = 0

        init(page: H5Page,
             reloadGeneration: Int,
             allowsEdgeSwipeNavigation: Bool,
             navigationGestureState: H5WebNavigationGestureState?,
             onAction: @escaping (H5BridgeAction) -> Void,
             onStateChange: @escaping (H5WebState) -> Void) {
            self.page = page
            self.reloadGeneration = reloadGeneration
            self.allowsEdgeSwipeNavigation = allowsEdgeSwipeNavigation
            self.navigationGestureState = navigationGestureState
            self.onAction = onAction
            self.onStateChange = onStateChange
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            navigationGestureState?.attach(to: webView)
            configureWebViewBackGesture(in: webView)
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                guard view.isLoading else { return }
                self?.emitState(.loading(progress: view.estimatedProgress))
            }
        }

        func detach() {
            loadRequestID += 1
            progressObservation?.invalidate()
            progressObservation = nil
            pendingState = nil
            navigationGestureState?.detach()
            webView = nil
        }

        func setEdgeSwipeNavigationEnabled(_ isEnabled: Bool) {
            guard allowsEdgeSwipeNavigation != isEnabled else { return }
            allowsEdgeSwipeNavigation = isEnabled
            guard let webView else { return }
            configureWebViewBackGesture(in: webView)
        }

        func loadInitialPage() {
            loadRequestID += 1
            let requestID = loadRequestID
            H5WebSession.runAfterPendingClear { [weak self] in
                guard let self,
                      requestID == self.loadRequestID,
                      let webView = self.webView else { return }
                self.webContentTerminationReloadCount = 0
                self.emitState(.loading(progress: 0))
                AppLogger.net.debug("[H5Bridge] load feature page path=\(self.page.url.path, privacy: .public)")
                webView.load(URLRequest(url: self.page.url, cachePolicy: .reloadRevalidatingCacheData))
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            AppLogger.net.debug("[H5Bridge] navigation request path=\(url.path, privacy: .public)")
            switch url.scheme?.lowercased() {
            case "http", "https":
                decisionHandler(.allow)
            case "tel", "mailto", "sms":
                onAction(.openExternal(url))
                decisionHandler(.cancel)
            default:
                // 禁止 file/data/javascript 等本地或脚本 scheme；未知外部 scheme 也不在 WebView 内执行。
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard let url = navigationResponse.response.url,
                  url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            emitState(.loading(progress: 0))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            webContentTerminationReloadCount = 0
            AppLogger.net.debug("[H5Bridge] navigation finished path=\(webView.url?.path ?? "", privacy: .public)")
            emitState(.loaded)
            sendRuntimeContextIfTrusted(in: webView)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation?,
                     withError error: Error) {
            guard (error as? URLError)?.code != .cancelled else { return }
            emitState(.failed(message: error.localizedDescription))
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation?,
                     withError error: Error) {
            guard (error as? URLError)?.code != .cancelled else { return }
            emitState(.failed(message: error.localizedDescription))
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // target=_blank 保留在当前容器，防止创建一个未受 policy / bridge 管理的新 WebView。
            if navigationAction.targetFrame == nil, let requestURL = navigationAction.request.url {
                switch requestURL.scheme?.lowercased() {
                case "http", "https":
                    webView.load(URLRequest(url: requestURL))
                case "tel", "mailto", "sms":
                    onAction(.openExternal(requestURL))
                default:
                    break
                }
            }
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            AppLogger.net.error("[H5Bridge] web content process terminated path=\(webView.url?.path ?? "", privacy: .public)")
            guard webContentTerminationReloadCount == 0 else {
                emitState(.failed(message: L10n.commonNetworkError))
                return
            }
            webContentTerminationReloadCount += 1
            emitState(.loading(progress: 0))
            webView.reload()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "App",
                  let currentURL = webView?.url,
                  page.allowsBridge(for: currentURL),
                  let action = H5Bridge.action(from: message.body) else { return }
            if case .requestAppParams = action, let webView {
                sendRuntimeContextIfTrusted(in: webView)
                return
            }
            onAction(action)
        }

        private func sendRuntimeContextIfTrusted(in webView: WKWebView) {
            guard let currentURL = webView.url,
                  page.allowsBridge(for: currentURL),
                  let payload = page.runtimeContext.jsonString() else { return }
            AppLogger.net.debug("[H5Bridge] runtime context delivered path=\(currentURL.path, privacy: .public) embedded=\(self.page.runtimeContext.embeddedWebFeature, privacy: .public)")
            let script = "window.__hilyReceiveNativeMessage && window.__hilyReceiveNativeMessage(\(payload));"
            webView.evaluateJavaScript(script)
        }

        private func configureWebViewBackGesture(in webView: WKWebView) {
            // WKWebView 自己会在没有 history 时拒绝这条手势。原生 pop 是否接管由
            // SwipeToPopHelper 在手势开始的瞬间读取 canGoBack 决定，不能通过 @State 切换。
            webView.allowsBackForwardNavigationGestures = allowsEdgeSwipeNavigation
        }

        /// WKWebView 可以在 UIViewRepresentable 的更新周期内同步发出加载和进度事件。
        /// 合并到下一轮主队列，避免在 SwiftUI body 更新时直接改写 @State。
        private func emitState(_ state: H5WebState) {
            pendingState = state
            guard !isStateDeliveryScheduled else { return }
            isStateDeliveryScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isStateDeliveryScheduled = false
                guard let pendingState = self.pendingState else { return }
                self.pendingState = nil
                self.onStateChange(pendingState)
            }
        }
    }

    private static func bridgeScript(runtimeJSON: String, trustedURL: URL) -> String {
        guard let origin = H5TrustedOriginPolicy.normalizedOriginForScript(trustedURL) else { return "" }
        return """
        (function() {
          if (window.location.origin !== \(javaScriptString(origin))) return;
          var nativeHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.App;
          if (!nativeHandler) return;
          var runtime = \(runtimeJSON);
          var known = ['getAppParams', 'SET_NAV', 'CLOSE', 'JUMP_WALLET', 'JUMP_RANKING', 'REPORT_SHUSHU', 'GO_ROOM', 'GO_PROFILE', 'GO_LIVE'];
          function post(type, data) { nativeHandler.postMessage({ type: type, data: data || {} }); }
          window.__hilyReceiveNativeMessage = function(payload) {
            if (payload && payload.type === 'getAppParams') runtime = payload;
            window.dispatchEvent(new MessageEvent('message', { data: payload, origin: window.location.origin }));
          };
          var previousApp = window.App || {};
          window.App = Object.assign(previousApp, {
            getAppParams: function() { return runtime; },
            closePage: function() { post('CLOSE'); },
            reportShuShu: function(eventName, params) { post('REPORT_SHUSHU', { eventName: eventName, params: params || {} }); },
            openBrowser: function(params) { post('OPEN_BROWSER', params || {}); },
            jumpWallet: function() { post('JUMP_WALLET'); },
            jumpRanking: function(pageType, hideMonthTab) { post('JUMP_RANKING', { pageType: pageType, hideMonthTab: !!hideMonthTab }); },
            jumpLiveRoom: function() { post('GO_LIVE'); },
            jumpPartRoom: function(roomId) { post('GO_ROOM', { roomId: roomId }); }
          });
          var originalPostMessage = window.postMessage.bind(window);
          window.postMessage = function(message, targetOrigin, transfer) {
            if (message && typeof message === 'object' && known.indexOf(message.type) >= 0) {
              if (message.type === 'getAppParams') {
                window.__hilyReceiveNativeMessage(runtime);
                return;
              }
              post(message.type, message.data || message);
              return;
            }
            return originalPostMessage(message, targetOrigin, transfer);
          };
        })();
        """
    }

    private static func javaScriptString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

/// UIKit 手势代理读取的轻量状态。它只持有当前 WebView 的弱引用，不发布 SwiftUI 状态，
/// 因此 H5 的 history 变化不会重建或重新加载 WebView。
final class H5WebNavigationGestureState {
    private weak var webView: WKWebView?

    var canGoBack: Bool {
        webView?.canGoBack == true
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    func detach() {
        webView = nil
    }
}

private extension H5TrustedOriginPolicy {
    static func normalizedOriginForScript(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), scheme == "https" else { return nil }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }
}
