import SwiftUI

/// B-3 · 惩罚态断开连线确认弹窗（对齐 H5 `pkDisconnectConfirmPopup.vue`）。
///
/// - 视觉：标题「PK Ended」 + 对手头像圆环（68x68，蓝色 3pt 描边）+ 对手昵称 + 单按钮「Disconnect Live」
/// - 触发：punishing 态点击底部 PKEntryButton → 显示本弹窗
/// - Disconnect：调 `PKStore.endPunishActive()` 走 punishing → idle 流程
struct PKDisconnectConfirmPopup: View {
    @Binding var isPresented: Bool
    let store: PKStore

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.PK.pkEndedTitle) {
            VStack(spacing: 24) {
                // 对手头像（68x68，H5 border-3 border-#69BCFF 蓝色描边 + 白色内边）
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 68, height: 68)
                    Circle()
                        .stroke(Color(hex: 0x69BCFF), lineWidth: 3)
                        .frame(width: 62, height: 62)
                    // AvatarView 尺寸 = 60 落在 3+2 pt 描边内侧
                    AvatarView(urlString: nil, size: 56, kind: .user)
                }
                .padding(.top, 4)
                Text(store.ctx?.oppositeNickname ?? "—")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
                PKPopupButton(title: L10n.PK.disconnectAction, style: .gradientPurpleToRed) {
                    Task { await store.endPunishActive() }
                    withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                }
            }
        }
    }
}
