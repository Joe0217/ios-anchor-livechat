import SwiftUI

/// G 里程碑 spec §6 / M3-6：惩罚态遮罩（120s 倒计时 + End Punish；半透明不全屏盖）。
struct PKPunishingOverlay: View {
    @ObservedObject var store: PKStore

    var body: some View {
        if store.state == .punishing {
            VStack(spacing: 0) {
                Spacer().frame(height: 80)
                HStack(spacing: 12) {
                    Image(systemName: "hourglass.bottomhalf.filled")
                        .foregroundStyle(.orange)
                    Text(L10n.PK.punishingTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(formatTime(store.punishRemainingSeconds))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(store.punishRemainingSeconds <= 5 ? .red : .white)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))

                Spacer()
                Button {
                    Task { await store.endPunishActive() }
                } label: {
                    Text(L10n.PK.punishingEnd)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 10)
                        .background(.gray.opacity(0.7), in: Capsule())
                }
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func formatTime(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}
