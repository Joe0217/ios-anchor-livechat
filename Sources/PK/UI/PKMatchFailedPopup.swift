import SwiftUI

/// B-4 · PK 匹配失败弹窗（对齐 H5 `pkMatchFailedPopup.vue`）。
///
/// - 视觉：标题「No match found temporarily」+ 两行提示文字 + 单按钮「Initiate PK」（品红渐变）
/// - 触发：`PKStore.matching` 态超时后（后端 push / QUICK+RETRY 全失败）→ LiveRoomView 观察 state 变化打开
/// - Initiate PK：关闭本弹窗 + 打开 PKInviteSheet（指定邀请）
struct PKMatchFailedPopup: View {
    @Binding var isPresented: Bool
    /// 点击「Initiate PK」时触发：关闭本弹窗 + 由父 view 打开 PKInviteSheet
    let onInitiate: () -> Void

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.PK.matchFailedTitle) {
            VStack(spacing: 12) {
                Text(L10n.PK.matchFailedHint1)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text(L10n.PK.matchFailedHint2)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Spacer().frame(height: 20)
                PKPopupButton(title: L10n.PK.matchFailedInitiate, style: .gradientPurpleToRed) {
                    withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                    onInitiate()
                }
            }
        }
    }
}
