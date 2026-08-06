import SwiftUI

/// Room Mode 切换二次确认底部 sheet — 房主选中新模板后弹起。
///
/// 对齐 spec §1 §4 A1：切模板会让所有用户下麦，须要求房主二次确认；stateless，
/// onConfirm 由上层 View 调 PartyStore.switchRoomMode 完成真正的服务端请求。
struct PartyRoomModeConfirmSheet: View {
    let tempId: Int
    let tempName: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.Party.roomModeConfirmTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .padding(.top, 20)

            Text(L10n.Party.roomModeConfirmBody)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text(L10n.Party.roomModeConfirmCancel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            Capsule().fill(Color.white.opacity(0.12))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text(L10n.Party.roomModeConfirmSwitch)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .selfSizingSheetHeight(minHeight: 100, maxHeight: 300)
    }
}
