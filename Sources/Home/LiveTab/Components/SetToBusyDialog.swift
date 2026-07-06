import SwiftUI

/// "今日已设为忙碌"弹窗（对齐安卓 SetToBusyDialog）。
///
/// 触发：`hasExceededCallLimit` API 返回 `isLimitMet="1"`（触发点 3 处：点刷新 / 收到 attachType=37 / onResume 静默检查）
///
/// 双入口：
/// - **去直播**：安卓 `liveClick()` → 打开开播设置页（跨 tab，本次 TODO 占位）
/// - **去匹配**：安卓 `matchClick(true)` → 切到 Home Match 子 tab
///
/// 视觉沿用 OfflineConfirmDialog（紫色渐变 + 粉色边）保持全局弹窗风格一致。
struct SetToBusyDialog: View {
    let onGoLive: () -> Void
    let onGoMatch: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 20) {
                Text(L10n.setToBusyTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(L10n.setToBusyDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 12) {
                    // 去匹配（安卓 matchClick 左）
                    Button(action: onGoMatch) {
                        Text(L10n.setToBusyGoMatch)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Color.white.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // 去直播（安卓 liveClick 右，主行动）
                    Button(action: onGoLive) {
                        Text(L10n.setToBusyGoLive)
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
                    .stroke(Color(hex: 0xFA06F4).opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color(hex: 0xFA06F4).opacity(0.35), radius: 8, y: 2)
        }
    }
}
