import SwiftUI

/// GiftEffect UIWindow overlay 的 SwiftUI 根 View
///
/// - 双层 ZStack：中央大动画 + 底部微飘窗
/// - `.allowsHitTesting(false)` 双保险（UIWindow 层 isUserInteractionEnabled=false 已透传）
/// - `.ignoresSafeArea()` 全屏覆盖
///
/// 2026-07-10 E-4 修复：不再持 @ObservedObject center，两 Layer 各自订阅独立 bridge
struct GiftEffectRoot: View {
    var body: some View {
        ZStack {
            CentralEffectLayer(bridge: GiftEffectCenter.shared.currentBridge)
            MicroToastLayer(bridge: GiftEffectCenter.shared.microToastBridge)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
