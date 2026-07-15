import SwiftUI

/// 派对房「Mic Application 开关首次切换协议确认」sheet — 对齐 H5
/// `livechat-h5/src/components/party/components/onOfOff-application-popup.vue`。
///
/// 房主首次开启/关闭排麦申请开关时弹出（本地 flag `autoEnterOnApplication /
/// autoEnterOffApplication` 为 false 时），二次同方向切换不再弹。
/// 视觉沿用 PartyRoomToolsSheet 深色底 + 紫粉渐变主按钮。
struct PartyMicApplicationSwitchConfirmSheet: View {
    /// true = 即将开启（switch On 语义），false = 即将关闭
    let enable: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                Text(enable
                     ? L10n.Party.micApplicationSwitchOnTitle
                     : L10n.Party.micApplicationSwitchOffTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                Text(enable
                     ? L10n.Party.micApplicationSwitchOnBody
                     : L10n.Party.micApplicationSwitchOffBody)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 24)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text(L10n.Party.cancel)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onConfirm) {
                        Text(L10n.Party.createConfirm)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                LinearGradient(
                                    colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .presentationDetents([.height(220)])
    }
}
