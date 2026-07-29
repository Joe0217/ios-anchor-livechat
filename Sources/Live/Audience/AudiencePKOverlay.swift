import SwiftUI

/// 客态 PK Arena。视频 canvas 由宿主负责；此处严格复用主态的布局常量和进度/倒计时/Top3 组件。
struct AudiencePKOverlay: View {
    @ObservedObject var store: AudiencePKStore
    let onOpponentTap: (Int) -> Void
    let onRankTap: (PKRankSide) -> Void

    var body: some View {
        GeometryReader { geo in
            if let left = store.left, let right = store.right {
                ZStack(alignment: .top) {
                    opponentMuteIndicator
                        .padding(.trailing, 12)
                        .padding(.top, PKArenaLayout.topOffset + 32)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)

                    VStack(spacing: 0) {
                        PKBattleProgressBar(myPkValue: left.score, opponentPkValue: right.score)
                            .padding(.horizontal, 16)
                        PKBattleCountdown(remainingSeconds: store.remainingSeconds,
                                          isPunishment: isPunishing)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, PKArenaLayout.topOffset)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                    HStack {
                        Spacer(minLength: 0)
                        Button { onOpponentTap(right.userId) } label: {
                            opponentNicknameChip(nickname: right.nickname, avatarURL: right.avatarURL)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(right.nickname))
                    }
                    .padding(.top, PKArenaLayout.topOffset + PKArenaLayout.videoHeight - 32)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                    VStack(spacing: 0) {
                        Spacer().frame(height: PKArenaLayout.topOffset + PKArenaLayout.videoHeight + 4)
                        PKBattleTop3Contributors(myTop3: left.top3,
                                                 opponentTop3: right.top3,
                                                 onTapSide: onRankTap)
                            .frame(height: 32)
                        Spacer(minLength: 0)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                    AudiencePKEffects(store: store)
                        .frame(width: 220, height: 220)
                        .padding(.top, PKArenaLayout.topOffset + 40)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }
            }
        }
    }

    private var isPunishing: Bool {
        if case .punishing = store.phase { return true }
        return false
    }

    private var opponentMuteIndicator: some View {
        Image(systemName: store.isOpponentMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .font(.system(size: 12))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Color.black.opacity(0.4), in: Circle())
            .accessibilityLabel(Text(store.isOpponentMuted ? L10n.PK.opponentUnmute : L10n.PK.opponentMute))
    }

    private func opponentNicknameChip(nickname: String, avatarURL: String?) -> some View {
        HStack(spacing: 6) {
            AvatarView(urlString: avatarURL, size: 24, kind: .user, disablesTap: true)
            Text(nickname)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .frame(width: 118, alignment: .leading)
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20, bottomLeading: 20))
                .fill(Color.black.opacity(0.4))
        )
    }
}

private struct AudiencePKEffects: View {
    @ObservedObject var store: AudiencePKStore
    @State private var showResult = false
    @State private var showLastFive = false
    @State private var hasShownLastFive = false

    var body: some View {
        Group {
            if store.isPreparing {
                PKSVGAPlayerView(resource: "pk-preparing-countdown", loops: 1)
                    .frame(width: 200, height: 200)
                    .allowsHitTesting(false)
            } else if showResult {
                PKSVGAPlayerView(resource: resultResource, loops: 1) { showResult = false }
                    .frame(width: 220, height: 220)
                    .allowsHitTesting(false)
            } else if showLastFive {
                PKSVGAPlayerView(resource: "pk-countdown-5s", loops: 1) { showLastFive = false }
                    .frame(width: 160, height: 160)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: store.phase) { phase in
            if case .punishing = phase { showResult = true }
            if phase == .idle { hasShownLastFive = false; showResult = false }
        }
        .onChange(of: store.remainingSeconds) { seconds in
            guard store.phase == .battling, !store.isPreparing,
                  !hasShownLastFive, (1...5).contains(seconds) else { return }
            hasShownLastFive = true
            showLastFive = true
        }
    }

    private var resultResource: String {
        guard case .punishing(let winner) = store.phase else { return "pk-result-draw" }
        switch winner {
        case 1: return "pk-result-win"
        case 2: return "pk-result-loss"
        default: return "pk-result-draw"
        }
    }
}
