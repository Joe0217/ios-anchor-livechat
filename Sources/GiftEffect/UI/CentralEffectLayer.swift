import SwiftUI

/// 中央大动画层（SVGA / YYEVA 全屏播放）
///
/// GiftPlayerHostView 长期挂在 ZStack 里（一直存在，Player 单例复用）；
/// 通过 Center.current 的 nil/非 nil 控制透明度显示，无需重建 UIView。
///
/// 2026-07-10 E-4 修复：只订阅 CurrentBridge，microToasts 变化不再触发本层重算
struct CentralEffectLayer: View {
    @ObservedObject var bridge: GiftEffectCurrentBridge

    var body: some View {
        ZStack {
            GiftPlayerHostView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(bridge.current == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: bridge.current?.id)
        }
    }
}
