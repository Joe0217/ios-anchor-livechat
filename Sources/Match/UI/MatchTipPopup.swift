import SwiftUI

/// L 里程碑：10 分钟未开启匹配的运营提示弹窗（对齐 H5 c-goMatch.vue showMatchPopup）。
///
/// 展示：
/// - 中心图标（复用 matchButtonOn）
/// - 标题："Turn on matching to receive calls faster and earn more."
/// - Go Match 按钮（gradient 主 CTA）
/// - 底部"今日不再提醒" checkbox（用户勾选后当日不再弹）
struct MatchTipPopup: View {
    let onGoMatch: () -> Void
    let onNoReminder: () -> Void
    let onClose: () -> Void

    @State private var noReminderChecked: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack(alignment: .topTrailing) {
                VStack(spacing: 16) {
                    Image("matchButtonOn")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60, height: 60)
                        .accessibilityHidden(true)

                    Text(L10n.matchTipTitle)
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)

                    Button(action: onGoMatch) {
                        Text(L10n.matchTipGoMatch)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Capsule().fill(Theme.Gradients.matchMarqueeBg))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)

                    Button(action: {
                        noReminderChecked.toggle()
                        if noReminderChecked { onNoReminder() }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: noReminderChecked ? "checkmark.square.fill" : "square")
                                .foregroundColor(noReminderChecked ? Theme.Palette.matchMarqueeReceiver : .white.opacity(0.6))
                                .frame(width: 16, height: 16)
                            Text(L10n.matchTipNoReminder)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0x5300A1), Color(hex: 0x3800A0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.4))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .padding(10)
                .accessibilityLabel(L10n.matchUserCardClose)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .background(Color.black.opacity(0.5).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

#Preview {
    MatchTipPopup(onGoMatch: {}, onNoReminder: {}, onClose: {})
}
