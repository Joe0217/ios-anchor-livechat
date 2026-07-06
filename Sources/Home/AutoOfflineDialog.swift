import SwiftUI

/// 长时间无操作自动置离线弹窗（对齐 H5 App.vue useDynamicInactivityTimer）。
///
/// **视觉**：紫色渐变卡 + 粉色发光边（复用 OfflineConfirmDialog / SetToBusyDialog 风格）
/// **交互**：
/// - 单按钮 "Go Online" → onGoOnline（setUserSetOnline(true) + 重启计时）
/// - 背景 dim 点关闭 → onDismiss（保持离线态，不重启计时）
struct AutoOfflineDialog: View {
    let onGoOnline: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // dim 遮罩，点击关闭（保持离线态）
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 20) {
                Text(L10n.autoOfflineTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(L10n.autoOfflineMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)

                // 单按钮 "Go Online"（对齐 H5 showConfirmDialog showCancelButton: false）
                Button(action: onGoOnline) {
                    Text(L10n.autoOfflineGoOnline)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(width: 319)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x5300A1), Color(hex: 0x3800A0)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: 0xFA06F4, opacity: 0.5), lineWidth: 1)
            )
            .shadow(color: Color(hex: 0xFA06F4).opacity(0.35), radius: 8, y: 2)
        }
    }
}
