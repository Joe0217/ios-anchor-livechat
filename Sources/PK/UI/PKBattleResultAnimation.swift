import SwiftUI

/// B-8 · PK 结果动画覆盖层（对齐 H5 `pkBattleViewResultAnimation.vue` + `pk-result-{win,loss,draw}.svga`）。
///
/// **触发**：`store.state` 转为 `.punishing` 时首次播放（`hasPlayed` 幂等 flag）。
/// 播完 SVGA 或超时 → `visible=false` 淡出隐藏。同一轮 PK 只播一次。
///
/// **视觉**（2026-07-11 从 SwiftUI scale/opacity 弹跳改造为真 SVGA）：
/// - 300×300 中央 SVGA 动画（win/loss/draw 三个资源按胜负分派）
/// - `loops=1` 播完 fire onFinish 触发淡出
///
/// **胜负判定**：我方 `pkCounter` vs 对方 `oppositePkCounter`
/// - my > opp → win / my < opp → lose / my == opp → draw
struct PKBattleResultAnimation: View {
    @ObservedObject var store: PKStore
    @State private var visible: Bool = false
    @State private var hasPlayed: Bool = false
    /// 播完后的 nonce（换 resource 也换 nonce 让 SwiftUI 重建 UIView）
    @State private var playNonce: Int = 0

    private var result: Result {
        let my = store.scores?.pkCounter ?? 0
        let opp = store.scores?.oppositePkCounter ?? 0
        if my > opp { return .win }
        if my < opp { return .lose }
        return .draw
    }

    private var svgaResource: String {
        switch result {
        case .win:  return "pk-result-win"
        case .lose: return "pk-result-loss"
        case .draw: return "pk-result-draw"
        }
    }

    var body: some View {
        Group {
            if visible {
                PKSVGAPlayerView(resource: svgaResource,
                                 loops: 1,
                                 onFinish: handleFinish)
                    .id(playNonce)
                    .frame(width: 300, height: 300)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text(resultA11yText))
            }
        }
        .onChange(of: store.state) { newState in
            if newState == .punishing && !hasPlayed {
                hasPlayed = true
                playNonce &+= 1
                withAnimation(.easeIn(duration: 0.15)) { visible = true }
            } else if newState != .punishing {
                hasPlayed = false
                visible = false
            }
        }
    }

    private func handleFinish() {
        // SVGA 播完淡出（clearsAfterStop=true 会自动清帧，无需 stopAnimation）
        withAnimation(.easeOut(duration: 0.4)) { visible = false }
    }

    // MARK: - Result

    private enum Result { case win, lose, draw }

    private var resultA11yText: String {
        switch result {
        case .win:  return L10n.PK.resultWin
        case .lose: return L10n.PK.resultLose
        case .draw: return L10n.PK.resultDraw
        }
    }
}
