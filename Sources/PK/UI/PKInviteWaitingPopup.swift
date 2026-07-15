import SwiftUI

/// B-5 · 发出 PK 邀请后等待对方接受弹窗（对齐 H5 `pkInviteWaitingPopup.vue`）。
///
/// - 视觉：标题「Inviting to PK」+ 96x96 倒计时圆环（60s，H5 pk-invite-countdown-bg 视觉近似）
///   + 副标题「Waiting PK acceptance」+ 单按钮「Cancel PK Invitation」（品红渐变）
/// - 显示时机：`PKStore.state == .inviting` 且 `invitedAnchors` 非空
/// - 数据：`inviteRemainingSeconds` 用作倒计时读数
/// - Cancel：调 `PKStore.cancelInvite()` 取消所有邀请
struct PKInviteWaitingPopup: View {
    @ObservedObject var store: PKStore
    @Binding var isPresented: Bool

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.PK.invitingTitle) {
            VStack(spacing: 16) {
                // 96x96 倒计时圆环（近似 H5 pk-invite-countdown-bg webp）
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 6)
                        .frame(width: 96, height: 96)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(LinearGradient(colors: [Color(hex: 0x8515FF),
                                                        Color(hex: 0xE40132)],
                                              startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 96, height: 96)
                        .animation(.linear(duration: 0.3), value: store.inviteRemainingSeconds)
                    Text(String(format: L10n.PK.countdownSecondsFormat, max(0, store.inviteRemainingSeconds)))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: Color(hex: 0x8515FF), radius: 2, y: 1)
                }
                .padding(.top, 8)

                Text(L10n.PK.waitingAcceptance)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                PKPopupButton(title: L10n.PK.cancelInvitation, style: .gradientPurpleToRed) {
                    Task { await store.cancelInvite() }
                    withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                }
                .padding(.top, 8)
            }
        }
        // v26（2026-07-15）：加 ClearBackground 让 fullScreenCover 背景透明，
        // 露出直播画面 + PKPopupCard 半透黑遮罩 = "普通弹窗"视觉（与 PKInvitedSheet 一致）
        .background(ClearFullScreenCoverBackground())
    }

    /// 60s → 1.0 → 0
    private var progress: CGFloat {
        max(0, min(1, CGFloat(store.inviteRemainingSeconds) / 60.0))
    }
}
