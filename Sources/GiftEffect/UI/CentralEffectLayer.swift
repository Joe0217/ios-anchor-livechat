import SwiftUI

/// 中央大动画层（SVGA / YYEVA 全屏播放）
///
/// GiftPlayerHostView 长期挂在 ZStack 里（一直存在，Player 单例复用）；
/// 通过 Center.current 的 nil/非 nil 控制透明度显示，无需重建 UIView。
struct CentralEffectLayer: View {
    @ObservedObject var center: GiftEffectCenter

    var body: some View {
        ZStack {
            GiftPlayerHostView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(center.current == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: center.current?.id)
        }
    }
}
