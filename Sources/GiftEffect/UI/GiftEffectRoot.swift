import SwiftUI

/// GiftEffect UIWindow overlay 的 SwiftUI 根 View
///
/// - 双层 ZStack：中央大动画 + 底部微飘窗
/// - `.allowsHitTesting(false)` 双保险（UIWindow 层 isUserInteractionEnabled=false 已透传）
/// - `.ignoresSafeArea()` 全屏覆盖
struct GiftEffectRoot: View {
    @ObservedObject private var center = GiftEffectCenter.shared

    var body: some View {
        ZStack {
            CentralEffectLayer(center: center)
            MicroToastLayer(toasts: center.microToasts)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
