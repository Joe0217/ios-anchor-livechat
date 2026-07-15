import SwiftUI

/// G 里程碑 spec §6 / M3-4：收到邀请 sheet（60s 倒计时 + Accept/Reject）。
///
/// **iteration 3（2026-07-06 PK 全套 UI 同步）**：视觉升级对齐 H5 `pkInviteReceivePopup.vue`：
/// - 顶部标题右侧加规则问号入口 → 弹 PKRulePopup（B-11 视觉占位）
/// - 保持 60s 圆环倒计时 + Accept/Reject 双按钮，视觉从 material 卡片改为 gradient card（复用 PKPopupCard）
struct PKInvitedSheet: View {
    @ObservedObject var store: PKStore
    @State private var showRulePopup: Bool = false
    /// isPresented 通过 store.state == .invited 隐式驱动；本 @State 只用于 PKPopupCard 传参 binding
    @State private var cardPresented: Bool = true

    var body: some View {
        if store.state == .invited, let info = store.receivedInvite {
            ZStack {
                // 复用 PKPopupCard 承载视觉，binding 用 cardPresented（值恒 true；关闭走 Reject 逻辑而非 X）
                PKPopupCard(
                    isPresented: $cardPresented,
                    title: L10n.PK.invitedTitle,
                    titleTrailing: {
                        AnyView(
                            Button {
                                showRulePopup = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white.opacity(0.85))
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(Text(L10n.PK.ruleTitle))
                        )
                    }
                ) {
                    invitedContent(info: info)
                }
                .overlay {
                    PKRulePopup(isPresented: $showRulePopup)
                }
            }
            // v26（2026-07-15）：fullScreenCover 挂载时加 ClearBackground 让底层透明，
            // 露出直播画面 + PKPopupCard 半透黑遮罩 = "普通弹窗"视觉（对齐 PKRulePopup 已验证 pattern）
            .background(ClearFullScreenCoverBackground())
            .onChange(of: cardPresented) { newVal in
                // 点击 PKPopupCard X 关闭 → 视为拒绝邀请（H5 pkInviteReceivePopup close-on-click-overlay=false，
                // 顶部 X 语义 = 拒绝）
                if !newVal {
                    Task { await store.rejectInvite() }
                    cardPresented = true   // reset 以便下一次 invited 时重新显示
                }
            }
        }
    }

    @ViewBuilder
    private func invitedContent(info: PKInviteInfo) -> some View {
        VStack(spacing: 20) {
            // 60s 倒计时圆环（对齐 H5 pk-invite-countdown-bg 视觉近似）
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

            // 邀请者昵称 + UID 徽章（对齐 H5 pkInviteReceivePopup L119-128）
            VStack(spacing: 8) {
                Text(info.nickname ?? "UID \(info.userId)")
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                HStack(spacing: 4) {
                    Text("ID:\(info.userId)")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                    if let country = info.countryId, !country.isEmpty {
                        Text(country)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.white.opacity(0.1),
                                        in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                }
            }

            // PK 时长（对齐 H5 L131-134：`PK time` + 黄色时长）
            HStack(spacing: 6) {
                Text(L10n.PK.inviteDurationLabel)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                Text(durationLabel(info.pkDuration))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFFE600))
            }

            // Reject / Accept 双按钮
            PKPopupButtonRow {
                PKPopupButton(title: L10n.PK.invitedReject, style: .solidPurple) {
                    Task { await store.rejectInvite() }
                }
            } right: {
                PKPopupButton(title: L10n.PK.invitedAccept, style: .gradientPurpleToRed) {
                    Task { await store.acceptInvite() }
                }
            }
        }
    }

    private var progress: CGFloat {
        max(0, min(1, CGFloat(store.inviteRemainingSeconds) / 60.0))
    }

    private func durationLabel(_ seconds: Int) -> String {
        switch seconds {
        case 180: return L10n.PK.inviteDuration3
        case 300: return L10n.PK.inviteDuration5
        case 600: return L10n.PK.inviteDuration10
        case 900: return L10n.PK.inviteDuration15
        default: return "\(seconds / 60) min"
        }
    }
}
