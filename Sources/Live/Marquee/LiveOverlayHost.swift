import SwiftUI

/// v8 直播间 3 层 overlay 挂载 ViewModifier —— 缓解 LiveRoomView.body SwiftUI type-check timeout
///
/// 3 层同时挂载（z 序自然叠加）：
/// 1. `GiftAnimationOverlay` — 中央送礼动画（最上层）
/// 2. `EnterRoomFloat` — 底部 40% 用户进场胶囊
/// 3. `DiamondGiftFloatScreen` — 顶部 10% 钻石盲盒横穿
///
/// `.allowsHitTesting(false)` 已在各子 view 内部设置，不拦截主界面触摸
struct LiveOverlayHost: ViewModifier {
    @ObservedObject var giftQueue: GiftAnimationQueue
    @ObservedObject var enterRoomQueue: EnterRoomFloatQueue
    @ObservedObject var diamondQueue: DiamondGiftFloatQueue
    /// v9 付费弹幕飘屏（可选，若父层不用可传 nil）
    @ObservedObject var paidBulletQueue: PaidBulletQueue
    /// v10 心愿达成飘屏
    @ObservedObject var wishAchievedQueue: WishAchievedQueue
    /// 主播端始终 isHost=true（对齐 H5 host-only dislike）
    let isHost: Bool

    func body(content: Content) -> some View {
        content
            .overlay { GiftAnimationOverlay(queue: giftQueue) }
            .overlay { EnterRoomFloat(queue: enterRoomQueue) }
            .overlay { DiamondGiftFloatScreen(queue: diamondQueue) }
            .overlay { PaidBulletFloat(queue: paidBulletQueue, isHost: isHost) }
            .overlay { WishAchievedFloat(queue: wishAchievedQueue) }
    }
}
