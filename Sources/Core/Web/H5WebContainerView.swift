import SwiftUI
import UIKit

/// 全屏 H5 push 宿主。业务路由通过 `onAction` 注入，Core 不依赖业务模块。
struct H5WebContainerView: View {
    let page: H5Page
    var showsNativeNavigation = true
    var allowsInteractivePop = true
    var allowsWebViewEdgeSwipeNavigation = false
    var onAction: (H5BridgeAction) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var state: H5WebState = .loading(progress: 0)
    @State private var navigationVisible = true
    @State private var reloadGeneration = 0
    @State private var webNavigationGestureState = H5WebNavigationGestureState()

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            H5WebView(
                page: page,
                reloadGeneration: reloadGeneration,
                allowsEdgeSwipeNavigation: allowsWebViewEdgeSwipeNavigation,
                navigationGestureState: webNavigationGestureState,
                onAction: handle,
                onStateChange: { state = $0 }
            )

            if case .loading(let progress) = state {
                ProgressView(value: progress)
                    .tint(.white)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }

            if case .failed(let message) = state {
                VStack(spacing: 14) {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button(L10n.commonRetry) {
                        state = .loading(progress: 0)
                        reloadGeneration += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(Theme.Palette.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(24)
            }
        }
        .navigationTitle(page.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsNativeNavigation && navigationVisible ? .visible : .hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(!showsNativeNavigation || !navigationVisible)
        .modifier(
            H5InteractivePopModifier(
                isEnabled: allowsInteractivePop,
                shouldAllowPop: allowsWebViewEdgeSwipeNavigation
                    ? { !webNavigationGestureState.canGoBack }
                    : nil
            )
        )
    }

    private func handle(_ action: H5BridgeAction) {
        switch action {
        case .close:
            dismiss()
        case .setNavigationVisible(let visible):
            navigationVisible = visible
        case .report(let event, let properties):
            AnalyticsTracker.track(event, properties: properties)
        case .openExternal(let url):
            openAllowedExternalURL(url)
        case .unsupported(let type):
            AppLogger.net.notice("[H5Bridge] unsupported action type=\(type, privacy: .public)")
        default:
            onAction(action)
        }
    }
}

/// 原生 Work 页面复用完整主播 H5 的三个现有页面，不实现新的业务页面或新的接口协议。
struct H5EmbeddedFeatureContainerView: View {
    let feature: H5EmbeddedFeature
    let title: String

    var body: some View {
        if let page = H5Page.embeddedFeature(feature, title: title) {
            H5WebContainerView(
                page: page,
                showsNativeNavigation: false,
                allowsInteractivePop: true,
                allowsWebViewEdgeSwipeNavigation: true
            )
        } else {
            ZStack {
                Theme.Palette.screenBackground.ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(L10n.commonNoContent)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .onAppear { AppLogger.net.error("[H5Bridge] HilyWebFeatureBaseURL missing or invalid") }
        }
    }
}

private struct H5InteractivePopModifier: ViewModifier {
    let isEnabled: Bool
    let shouldAllowPop: (() -> Bool)?

    func body(content: Content) -> some View {
        // H5 history 的变化只在 UIKit 手势启动时读取，不能回写 SwiftUI @State，
        // 否则会让 WKWebView 在 history 路由过程中重建并重新加载入口页。
        content.background(
            SwipeToPopHelper(isEnabled: isEnabled, shouldAllowPop: shouldAllowPop)
                .frame(width: 0, height: 0)
        )
    }
}

private func openAllowedExternalURL(_ url: URL) {
    guard H5ExternalURLPolicy.allows(url) else {
        AppLogger.net.notice("[H5Bridge] blocked external url scheme=\(url.scheme ?? "", privacy: .public)")
        return
    }
    UIApplication.shared.open(url)
}

/// 半屏 H5 内容宿主。调用方负责 presentationDetents；CLOSE 只关闭自己的 sheet 实例。
struct H5WebSheetView: View {
    let page: H5Page
    var onAction: (H5BridgeAction) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var state: H5WebState = .loading(progress: 0)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.Palette.screenBackground.ignoresSafeArea()
            H5WebView(page: page, reloadGeneration: 0, onAction: handle, onStateChange: { state = $0 })

            if case .loading(let progress) = state {
                ProgressView(value: progress)
                    .tint(.white)
                    .padding(.horizontal, 48)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9), .black.opacity(0.45))
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.commonClose)
        }
    }

    private func handle(_ action: H5BridgeAction) {
        switch action {
        case .close:
            dismiss()
        case .report(let event, let properties):
            AnalyticsTracker.track(event, properties: properties)
        case .openExternal(let url):
            openAllowedExternalURL(url)
        case .unsupported(let type):
            AppLogger.net.notice("[H5Bridge] unsupported action type=\(type, privacy: .public)")
        default:
            onAction(action)
        }
    }
}
