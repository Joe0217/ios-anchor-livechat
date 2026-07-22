import SwiftUI

/// PK 结束前最后 5s 倒计时动画覆盖层（对齐 H5 `pkBattleViewLast5sCountdownAnimation.vue` +
/// `pk-countdown-5s.svga`）。
///
/// **触发**：`store.state == .inPK` 且 `pkRemainingSeconds` **首次进入 (0, 5]** 区间时播放。
/// 用 `hasPlayed` 幂等 flag —— 每轮 PK 只播一次；`.inPK` 退出时重置以支持下一轮。
///
/// **视觉**：中央 SVGA 5-4-3-2-1 倒计时数字动画（loops=1 播完 fire onFinish 隐藏）。
///
/// **iOS 简化**：H5 SVGA 内部已包含从 5 到 1 的完整倒计时视觉，不需要 iOS 侧同步秒数——
/// 只要在合适时机触发一次 SVGA 播放即可（后端 5s 倒计时期间与 SVGA 帧率能吻合）。
struct PKLast5sCountdownAnimation: View {
    @ObservedObject var store: PKStore
    @State private var visible: Bool = false
    @State private var hasPlayed: Bool = false
    @State private var playNonce: Int = 0

    var body: some View {
        Group {
            if visible {
                PKSVGAPlayerView(resource: "pk-countdown-5s",
                                 loops: 1,
                                 onFinish: handleFinish)
                    .id(playNonce)
                    .frame(width: 200, height: 200)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: store.pkRemainingSeconds) { newValue in
            triggerIfEnteringLast5s(remaining: newValue)
        }
        .onChange(of: store.state) { newState in
            if newState != .inPK {
                // 退出 inPK 重置，允许下一轮 PK 再触发一次
                hasPlayed = false
                visible = false
            }
        }
    }

    /// 进入 [1, 5] 区间的**第一次** trigger（remaining=5 时启动，之后随秒下降不重复触发）
    private func triggerIfEnteringLast5s(remaining: Int) {
        guard store.state == .inPK, !hasPlayed else { return }
        guard remaining > 0 && remaining <= 5 else { return }
        hasPlayed = true
        playNonce &+= 1
        withAnimation(.easeIn(duration: 0.15)) { visible = true }
    }

    private func handleFinish() {
        withAnimation(.easeOut(duration: 0.3)) { visible = false }
    }
}
