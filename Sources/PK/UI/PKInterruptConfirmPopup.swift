import SwiftUI

/// B-2 · PK 中断确认弹窗（对齐 H5 `pkInterruptConfirmPopup.vue`）。
///
/// - 视觉：中央 gradient card + 标题「Give up the PK?」+ 提示文字 + 双按钮（Give Up 灰紫 / Continue PK 品红渐变）
/// - 触发：inPK 态点击底部 PKEntryButton → 显示本弹窗
/// - Give Up：调 `PKStore.endPKActive()` 走 inPK → punishing 流程
/// - Continue：关闭弹窗保持 inPK
struct PKInterruptConfirmPopup: View {
    @Binding var isPresented: Bool
    let store: PKStore

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.PK.giveUpTitle) {
            VStack(spacing: 32) {
                Text(L10n.PK.giveUpConfirm)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                PKPopupButtonRow {
                    PKPopupButton(title: L10n.PK.giveUpAction, style: .solidPurple) {
                        Task { await store.endPKActive() }
                        withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                    }
                } right: {
                    PKPopupButton(title: L10n.PK.continuePK, style: .gradientPurpleToRed) {
                        withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                    }
                }
            }
        }
    }
}
