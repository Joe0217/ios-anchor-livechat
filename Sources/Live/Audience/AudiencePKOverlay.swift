import SwiftUI

/// 客态 PK 覆盖层：分数、倒计时、双方资料和 Top3。视频 canvas 由宿主负责，避免 UIKit 渲染层
/// 因 SwiftUI overlay 重建而丢帧。
struct AudiencePKOverlay: View {
    @ObservedObject var store: AudiencePKStore
    let onOpponentTap: (Int) -> Void
    let onRankTap: (PKRankSide) -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                scoreBar
                if let left = store.left, let right = store.right {
                    HStack(alignment: .top) {
                        anchorSummary(left, alignment: .leading)
                        Spacer(minLength: 16)
                        VStack(spacing: 2) {
                            Text(timeText)
                                .font(.system(size: 13, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                            if case .punishing = store.phase {
                                Image(systemName: "flag.checkered")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(hex: 0xFFBB02))
                            }
                        }
                        Spacer(minLength: 16)
                        Button { onOpponentTap(right.userId) } label: {
                            anchorSummary(right, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(right.nickname))
                    }
                    PKBattleTop3Contributors(myTop3: left.top3,
                                             opponentTop3: right.top3,
                                             onTapSide: onRankTap)
                }
            }
            .padding(8)
            .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))

            AudiencePKEffects(store: store)
        }
    }

    private var scoreBar: some View {
        GeometryReader { proxy in
            let leftScore = max(0, store.left?.score ?? 0)
            let rightScore = max(0, store.right?.score ?? 0)
            let total = leftScore + rightScore
            let ratio = total == 0 ? 0.5 : CGFloat(leftScore) / CGFloat(total)
            HStack(spacing: 0) {
                Color(hex: 0xF35B93).frame(width: proxy.size.width * ratio)
                Color(hex: 0x6A8DFF).frame(width: proxy.size.width * (1 - ratio))
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }

    private func anchorSummary(_ anchor: AudiencePKStore.Anchor,
                               alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(anchor.nickname)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(anchor.score)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: 110, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var timeText: String {
        let seconds = max(0, store.remainingSeconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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
