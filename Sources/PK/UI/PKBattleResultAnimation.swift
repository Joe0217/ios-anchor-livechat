import SwiftUI

/// B-8 · PK 结果动画覆盖层（对齐 H5 `pkBattleViewResultAnimation.vue`）。
///
/// H5 用 SVGA 动画（pk-result-win / lose / draw）；iOS 侧无 SVGA 资源，用 SwiftUI 近似还原：
/// - 惩罚阶段开始瞬间显示（对齐 H5 `watch pkStore.isPunishing`）
/// - 105x105 中央圆盘 + 大字号 WIN/LOSE/DRAW + 缩放弹跳动画（0.6s scaleIn + hold + fadeOut）
/// - 结果判定：我方 pkCounter vs 对方 oppositePkCounter（大 = win / 小 = lose / 等 = draw）
/// - 触发方式：由父 view (PKArenaView) 监听 `store.state == .punishing` 触发一次 `show`
struct PKBattleResultAnimation: View {
    @ObservedObject var store: PKStore
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0
    @State private var hasPlayed: Bool = false

    private var result: Result {
        let my = store.scores?.pkCounter ?? 0
        let opp = store.scores?.oppositePkCounter ?? 0
        if my > opp { return .win }
        if my < opp { return .lose }
        return .draw
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(colorForResult.opacity(0.35))
                .frame(width: 105, height: 105)
                .overlay(
                    Circle().stroke(colorForResult, lineWidth: 3)
                )
            Text(textForResult)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(.white)
                .shadow(color: colorForResult, radius: 4)
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .allowsHitTesting(false)
        .onChange(of: store.state) { newState in
            if newState == .punishing && !hasPlayed {
                hasPlayed = true
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                    scale = 1.0
                    opacity = 1.0
                }
                // hold 1.4s → fade
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    withAnimation(.easeOut(duration: 0.4)) {
                        opacity = 0
                    }
                }
            } else if newState != .punishing {
                hasPlayed = false
                scale = 0.4
                opacity = 0
            }
        }
    }

    // MARK: - Result

    private enum Result { case win, lose, draw }

    private var textForResult: String {
        switch result {
        case .win:  return L10n.PK.resultWin
        case .lose: return L10n.PK.resultLose
        case .draw: return L10n.PK.resultDraw
        }
    }

    private var colorForResult: Color {
        switch result {
        case .win:  return Color(hex: 0xFFD700)   // 金
        case .lose: return Color(hex: 0xE40132)   // 红
        case .draw: return Color(hex: 0x00B8FF)   // 蓝
        }
    }
}
