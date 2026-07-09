import SwiftUI
import UIKit

/// 承载 SVGAPlayer / YYEVAPlayer 的 UIView 桥
///
/// makeUIView 时把 UIView 注册到 Center；SVGA/YYEVA player 挂在这个 UIView 的 subview 上。
/// updateUIView 是 no-op（Player 由 Center 触发 play，UIView 只做容器）。
struct GiftPlayerHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        GiftEffectCenter.shared.registerHostView(host)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // no-op
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        GiftEffectCenter.shared.unregisterHostView(uiView)
    }
}
