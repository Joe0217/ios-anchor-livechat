import SwiftUI

/// 强制结束 PK 二次确认弹窗（对齐 H5 forceEndConfirm.vue）
///
/// 视觉结构：橙色 warn 图标 + 标题/描述 + 红 vs 蓝比分对卡 + 胜方提示 + Cancel/Confirm 双胶囊
struct PartyBattleForceEndConfirm: View {
    @ObservedObject var store: PartyBattleStore
    @Environment(\.dismiss) private var dismiss
    @State private var actionError: String?

    var body: some View {
        ZStack {
            bgGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.top, 10)

                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 44))

                Text(L10n.Party.Battle.forceEndTitle)
                    .font(.title3).bold()
                    .foregroundColor(.white)
                    .padding(.top, 20)

                Text(L10n.Party.Battle.forceEndDesc)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                    .padding(.horizontal, 8)

                scoreRow.padding(.top, 20)

                willWinText.padding(.top, 6)

                HStack(spacing: 14) {
                    cancelButton
                    confirmButton
                }
                .padding(.top, 20)
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if let actionError {
                Text(actionError)
                    .toastStyle(topInset: 8)
                    .transition(Toast.transition)
            }
        }
    }

    @ViewBuilder
    private var scoreRow: some View {
        HStack(spacing: 4) {
            teamScoreCard(color: redColor, label: L10n.Party.Battle.redTeam, score: redScore)
            CDNAssetImage("partyPkBattleMarker")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .padding(.horizontal, 4)
            teamScoreCard(color: blueColor, label: L10n.Party.Battle.blueTeam, score: blueScore)
        }
    }

    @ViewBuilder
    private func teamScoreCard(color: Color, label: String, score: Int) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption).foregroundColor(color)
            Text("\(score)")
                .font(.subheadline).foregroundColor(.white)
        }
        .frame(width: 100, height: 48)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var willWinText: some View {
        HStack(spacing: 3) {
            switch leadingTeam {
            case 1:
                Text(L10n.Party.Battle.forceEndWill(L10n.Party.Battle.redTeam))
                    .font(.subheadline).bold().foregroundColor(redColor)
            case 2:
                Text(L10n.Party.Battle.forceEndWill(L10n.Party.Battle.blueTeam))
                    .font(.subheadline).bold().foregroundColor(blueColor)
            default:
                Text(L10n.Party.Battle.forceEndTied)
                    .font(.subheadline).foregroundColor(.white.opacity(0.85))
            }
        }
    }

    @ViewBuilder
    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text(L10n.Party.Battle.cancel)
                .font(.subheadline).bold()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color(red: 0.30, green: 0.0, blue: 0.76))
                .clipShape(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var confirmButton: some View {
        Button {
            actionError = nil
            Task {
                let ended = await store.forceEnd()
                if ended {
                    await MainActor.run { dismiss() }
                } else {
                    await MainActor.run {
                        actionError = store.actionError ?? L10n.Party.Battle.alreadyEnded
                    }
                }
            }
        } label: {
            HStack {
                if store.forceEnding {
                    ProgressView().tint(.white)
                }
                Text(L10n.Party.Battle.confirm)
                    .font(.subheadline).bold()
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(pillGradient)
            .clipShape(Capsule())
            .opacity(store.forceEnding ? 0.6 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.forceEnding)
    }

    // MARK: - Computed

    private var redScore: Int { Int((store.redScoreDisplay).rounded()) }
    private var blueScore: Int { Int((store.blueScoreDisplay).rounded()) }
    private var leadingTeam: Int? {
        if redScore > blueScore { return 1 }
        if blueScore > redScore { return 2 }
        return nil
    }

    // MARK: - Style

    private let redColor = Color(red: 1.0, green: 0.15, blue: 0.7)
    private let blueColor = Color(red: 0.05, green: 0.43, blue: 1.0)

    private var bgGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.09, blue: 0.35),
                Color(red: 0.11, green: 0.06, blue: 0.30),
                Color(red: 0.07, green: 0.04, blue: 0.16),
            ],
            startPoint: .topTrailing, endPoint: .bottomLeading
        )
    }

    private var pillGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.52, green: 0.08, blue: 1.0), Color(red: 0.89, green: 0.00, blue: 0.20)],
            startPoint: .leading, endPoint: .trailing
        )
    }
}
