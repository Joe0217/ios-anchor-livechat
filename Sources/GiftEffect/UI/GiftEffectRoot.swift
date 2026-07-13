import SwiftUI

/// GiftEffect UIWindow overlay 的 SwiftUI 根 View
///
/// - 三层 ZStack：进场特效（底层）+ 中央大动画（中层）+ 底部微飘窗（顶层）
/// - `.allowsHitTesting(false)` 双保险（UIWindow 层 isUserInteractionEnabled=false 已透传）
/// - `.ignoresSafeArea()` 全屏覆盖
///
/// 2026-07-10 E-4 修复：不再持 @ObservedObject center，各 Layer 各自订阅独立 bridge
/// 2026-07-11 v23：新增 EnterEffectLayer（座驾 SVGA/MP4 全屏），独立 Center 与 GiftEffect 并行
struct GiftEffectRoot: View {
    var body: some View {
        ZStack {
            // 底层：进场特效（用户带座驾进场，全屏 SVGA/MP4，与 GiftEffect 并行）
            EnterEffectLayer(bridge: EnterEffectCenter.shared.currentBridge)
            // 中层：礼物特效中央大动画
            CentralEffectLayer(bridge: GiftEffectCenter.shared.currentBridge)
            // 顶层：底部小飘窗（GiftEffect 无动画资源礼物）
            MicroToastLayer(bridge: GiftEffectCenter.shared.microToastBridge)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
