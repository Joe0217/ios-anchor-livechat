import SwiftUI

/// 虚拟道具特效开关弹窗（对齐 H5 liveSettingEffectSwitchPopup.vue）
///
/// 单一 Toggle 开关控制虚拟道具进场动画；纯本地 persist，无 API
struct VirtualPropsEffectSwitchPopup: View {
    @Binding var isPresented: Bool
    @ObservedObject var store: VirtualPropsStore

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.virtualPropsEffectSwitchTitle) {
            VStack(spacing: 16) {
                Text(L10n.virtualPropsEffectSwitchDescription)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)

                HStack {
                    Text(L10n.virtualPropsEffectEnable)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Toggle("", isOn: $store.effectEnabled)
                        .labelsHidden()
                        .tint(Color(hex: 0xFFE600))
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                PKPopupButton(title: L10n.liveRoomCloseA11y, style: .solidPurple) {
                    withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                }
                .padding(.horizontal, 40).padding(.top, 8)
            }
        }
    }
}
