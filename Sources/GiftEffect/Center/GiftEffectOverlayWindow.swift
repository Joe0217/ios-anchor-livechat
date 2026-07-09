import UIKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftEffectWindow")

/// 独立 UIWindow overlay 层管理
///
/// - windowLevel = .alert - 1（在业务 view 上方、系统 alert 下方）
/// - isUserInteractionEnabled = false（全局透传点击，用户可点特效下方的按钮）
/// - 登录后 show / logout 时 hide
@MainActor
public final class GiftEffectOverlayWindow {
    public static let shared = GiftEffectOverlayWindow()
    private var window: UIWindow?

    private init() {}

    /// 登录后调用（Task 7 HilyApp）
    public func show(on scene: UIWindowScene) {
        guard window == nil else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert - 1
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        let host = UIHostingController(rootView: GiftEffectRoot())
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        w.rootViewController = host
        w.isHidden = false
        window = w
        logger.info("GiftEffectWindow shown at level=\(w.windowLevel.rawValue)")
    }

    /// logout / 内存告警手动 hide 时调
    public func hide() {
        window?.isHidden = true
        window = nil
        logger.info("GiftEffectWindow hidden")
    }
}
