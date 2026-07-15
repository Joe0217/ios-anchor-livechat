import SwiftUI

/// L 里程碑：首次每日开启匹配的规则弹窗（对齐 H5 c-goMatch.vue `showRulePopup`）。
///
/// - 展示：规则正文 4 段 + 底部"Agree"按钮
/// - **10s 倒计时**：Agree 按钮初始 disabled，倒计时结束后可点；期间显示 `Agree (Ns)`
/// - 用户点 Agree → 走 `onAgree` closure（生产：MatchStore.openMatch → 更新 ruleAgreedDate）
/// - 不允许点空白区域关闭（`.interactiveDismissDisabled`）
///
/// 挂载：CGoMatchButton 点击时判 `MatchStore.shared.isFirstMatchToday` == true → 弹本 sheet
struct MatchRulePopup: View {
    let onAgree: () -> Void

    @State private var countdown: Int = 10
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.matchRuleTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 12) {
                ruleLine(L10n.matchRuleDetail1)
                ruleLine(L10n.matchRuleDetail2)
                ruleLine(L10n.matchRuleDetail3)
                ruleLine(L10n.matchRuleDetail4)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            Button(action: {
                guard countdown <= 0 else { return }
                timerTask?.cancel()
                onAgree()
            }) {
                Text(countdown > 0 ? "\(L10n.matchRuleAgree) (\(countdown)s)" : L10n.matchRuleAgree)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        Capsule().fill(
                            countdown > 0
                                ? AnyShapeStyle(Theme.Palette.cardFill)
                                : AnyShapeStyle(Theme.Gradients.matchMarqueeBg)
                        )
                    )
                    .opacity(countdown > 0 ? 0.6 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(countdown > 0)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear { startCountdown() }
        .onDisappear { timerTask?.cancel() }
    }

    private func ruleLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.Palette.matchMarqueeReceiver)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startCountdown() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown -= 1
            }
        }
    }
}

#Preview {
    MatchRulePopup(onAgree: {})
}
