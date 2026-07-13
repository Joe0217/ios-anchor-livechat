import SwiftUI
import UIKit

/// 承载 EnterEffect 播放器 UIView 的桥（对齐 GiftPlayerHostView 但独立注册到 EnterEffectCenter）
///
/// makeUIView 时把 UIView 注册到 EnterEffectCenter；SVGA/YYEVA player 挂在这个 UIView 的 subview 上。
/// updateUIView 是 no-op（Player 由 Center 触发 play，UIView 只做容器）。
///
/// **独立于 GiftPlayerHostView**：两个 UIView 分别承接两个 Center 的 player，
/// SVGA/YYEVA 实例互不共享，天然支持并行播放。
struct EnterPlayerHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        EnterEffectCenter.shared.registerHostView(host)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // no-op
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        EnterEffectCenter.shared.unregisterHostView(uiView)
    }
}
