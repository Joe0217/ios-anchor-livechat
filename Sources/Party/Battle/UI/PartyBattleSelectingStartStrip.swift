import SwiftUI

/// SELECTING 阶段底部 Start / Countdown 行（对齐 H5 selectingStartStrip.vue 99 行）
///
/// 视觉结构：
/// - 房主/房管：全宽 46pt 设计稿切图大按钮
///   · 主行 "Start Ns"（Start 白色 + Ns 黄色）
///   · 副行 selectingHostTitle 半透白小字
///   · 紫红渐变背景（H5 用 pk-wait-bg.webp）
/// - 观众：黑色 45% 半透明胶囊 "Countdown Ns"
struct PartyBattleSelectingStartStrip: View {
    @ObservedObject var store: PartyBattleStore
    @State private var actionError: String?

    var body: some View {
        Group {
            if store.canManage {
                hostPill
            } else {
                audienceCountdown
            }
        }
        .overlay(alignment: .top) {
            if let actionError {
                Text(actionError)
                    .toastStyle(topInset: 0)
                    .transition(Toast.transition)
                    .offset(y: -36)
            }
        }
    }

    @ViewBuilder
    private var hostPill: some View {
        let left = max(0, store.leftSec)
        Button {
            actionError = nil
            Task {
                let started = await store.startNow()
                if !started {
                    await MainActor.run {
                        actionError = store.actionError ?? L10n.Party.Battle.startNowFailed
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text(L10n.Party.Battle.start)
                        .font(.system(size: 20, weight: .bold))
                        .italic()
                        .foregroundColor(.white)
                    Text("\(left)s")
                        .font(.system(size: 20, weight: .bold))
                        .italic()
                        .foregroundColor(.yellow)
                }
                Text(L10n.Party.Battle.selectingHostTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                CDNAssetImage("partyPkStartButton")
                    .resizable()
                    .scaledToFill()
            )
            .clipShape(Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var audienceCountdown: some View {
        let left = max(0, store.leftSec)
        HStack(spacing: 8) {
            Text(L10n.Party.Battle.countdown)
                .font(.headline).bold()
                .foregroundColor(.white)
            Text("\(left)s")
                .font(.headline).bold()
                .foregroundColor(.yellow)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
        .padding(.bottom, 12)
    }
}
