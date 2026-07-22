import SwiftUI

/// PK 开始前"准备"动画覆盖层（对齐 H5 `pkBattleViewPreparingCountdownAnimation.vue` +
/// `pkBattleViewPreparingUserInfoAnimation.vue` + `pk-preparing-countdown.svga`）。
///
/// **触发**：`store.state` 转为 `.inPK` 时首次播放（`hasPlayed` 幂等 flag，同轮只播一次）。
/// SVGA 播完 fire onFinish → 视觉淡出。
///
/// **视觉**：全屏中央 SVGA 动画（3-2-1 倒计时 + 双方主播 vs 图形），loops=1 一次性播放。
///
/// **iOS 简化**：H5 双方主播头像信息（PreparingUserInfoAnimation）与倒计时（PreparingCountdown
/// Animation）是两个独立组件叠加渲染；iOS 侧 SVGA 已包含完整视觉，无需再叠头像层。
struct PKPreparingAnimation: View {
    @ObservedObject var store: PKStore
    @State private var visible: Bool = false
    @State private var hasPlayed: Bool = false
    @State private var playNonce: Int = 0

    var body: some View {
        Group {
            if visible {
                PKSVGAPlayerView(resource: "pk-preparing-countdown",
                                 loops: 1,
                                 onFinish: handleFinish)
                    .id(playNonce)
                    .frame(width: 320, height: 320)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: store.state) { newState in
            if newState == .inPK && !hasPlayed {
                hasPlayed = true
                playNonce &+= 1
                withAnimation(.easeIn(duration: 0.15)) { visible = true }
            } else if newState != .inPK {
                // 退出 inPK 时重置 hasPlayed，允许下一轮 PK 重新播放
                hasPlayed = false
                visible = false
            }
        }
    }

    private func handleFinish() {
        withAnimation(.easeOut(duration: 0.3)) { visible = false }
    }
}
