import SwiftUI

/// B-8 · PK 对战倒计时（对齐 H5 pkBattleViewCountdown.vue L26-38：`h-20 rounded-b-12 bg-black/40 px-8`）。
///
/// - 20pt 高胶囊 + 下圆角 12pt + 半透黑 40% 背景
/// - PK 阶段：黄字 `mm:ss`
/// - 惩罚阶段：黄字 `Punish mm:ss`（前缀 + 时间）
struct PKBattleCountdown: View {
    let remainingSeconds: Int
    let isPunishment: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isPunishment {
                Text(L10n.PK.punishLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFFE600))
            }
            Text(formatTime(remainingSeconds))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(Color(hex: 0xFFE600))
        }
        .padding(.horizontal, 10)  // H5 `px-8` = 8pt 但 iOS 视觉略紧
        .frame(height: 20)          // H5 `h-20` = 20pt
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 12,
                                                      bottomTrailing: 12))
                .fill(Color.black.opacity(0.4))
        )
        .accessibilityElement(children: .combine)
    }

    private func formatTime(_ s: Int) -> String {
        let mm = s / 60
        let ss = s % 60
        return String(format: "%d:%02d", mm, ss)
    }
}
