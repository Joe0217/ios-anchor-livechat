import SwiftUI

/// L 里程碑 #3d：未露脸倒计时弹窗（5s 内检测不到脸 → 关匹配走 blocked）。
/// 对齐 H5 c-goMatch.vue showNoFacePopup + startNoFaceCountdown。
struct MatchNoFacePopup: View {
    /// 用户主动 dismiss（5s 内检测到脸 or 手动关闭）
    let onDismiss: () -> Void

    @State private var countdown: Int = 5
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                // 倒计时数字
                Text("\(countdown)")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 80, height: 80)
            .background(
                Circle()
                    .stroke(Theme.Palette.matchMarqueeBorderStart, lineWidth: 3)
                    .rotationEffect(.degrees(-90))
            )

            Text(L10n.matchFaceNotDetectedTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)

            Text(L10n.matchFaceNotDetectedContent)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: onDismiss) {
                Text(L10n.matchUserCardClose)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 200, height: 40)
                    .background(Capsule().fill(Theme.Palette.cardFill))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.7).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { startCountdown() }
        .onDisappear { timerTask?.cancel() }
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

/// L 里程碑 #3d：移除匹配弹窗（未露脸倒计时结束 → 已关匹配 → 展示确认）。
/// 对齐 H5 c-goMatch.vue showExitMatchPopup。
struct MatchExitPopup: View {
    let onOK: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Text(L10n.matchExitTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 24)

                Text(L10n.matchExitContent)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button(action: onOK) {
                    Text(L10n.matchRuleAgree)  // 复用"Agree"作为 OK
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Capsule().fill(Theme.Gradients.matchMarqueeBg))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(width: 319)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x5300A1), Color(hex: 0x3800A0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.5).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

#Preview("no face") {
    MatchNoFacePopup(onDismiss: {})
}

#Preview("exit") {
    MatchExitPopup(onOK: {})
}
