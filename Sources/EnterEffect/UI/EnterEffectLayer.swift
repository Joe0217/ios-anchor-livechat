import SwiftUI

/// 用户进场特效层（座驾 SVGA/MP4 全屏播放）
///
/// EnterPlayerHostView 长期挂在 ZStack 里（一直存在，Player 单例复用）；
/// 通过 EnterEffectCenter.current 的 nil/非 nil 控制透明度显示，无需重建 UIView。
///
/// **与 CentralEffectLayer（GiftEffect）并存**于同一 GiftEffectRoot ZStack，
/// 通过独立 UIView host + 独立 Player Router 实例天然并行播放（用户明示需求）。
struct EnterEffectLayer: View {
    @ObservedObject var bridge: EnterEffectCurrentBridge

    var body: some View {
        ZStack {
            EnterPlayerHostView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(bridge.current == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: bridge.current?.id)
        }
    }
}
