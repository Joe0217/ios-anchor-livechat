import SwiftUI

/// G 里程碑 spec §6 / M3-4：收到邀请 sheet（60s 倒计时 + Accept/Reject）。
struct PKInvitedSheet: View {
    @ObservedObject var store: PKStore

    var body: some View {
        if store.state == .invited, let info = store.receivedInvite {
            VStack(spacing: 20) {
                Spacer().frame(height: 8)
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(LinearGradient(colors: [.pink, .purple],
                                              startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: store.inviteRemainingSeconds)
                    Text("\(store.inviteRemainingSeconds)s")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)

                VStack(spacing: 4) {
                    Text(L10n.PK.invitedTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(info.nickname ?? "UID \(info.userId)")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("\(durationLabel(info.pkDuration))")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }

                HStack(spacing: 16) {
                    Button {
                        Task { await store.rejectInvite() }
                    } label: {
                        Text(L10n.PK.invitedReject)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.gray.opacity(0.7), in: Capsule())
                    }
                    Button {
                        Task { await store.acceptInvite() }
                    } label: {
                        Text(L10n.PK.invitedAccept)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(LinearGradient(colors: [.pink, .purple],
                                                      startPoint: .leading, endPoint: .trailing),
                                        in: Capsule())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.55))
        }
    }

    private var progress: CGFloat {
        guard store.inviteRemainingSeconds > 0 else { return 0 }
        return CGFloat(store.inviteRemainingSeconds) / 60.0
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
