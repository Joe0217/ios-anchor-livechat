import SwiftUI

/// G 里程碑 spec §6 / M3-6：惩罚态遮罩（仅 End Punish 按钮；半透明不全屏盖）。
///
/// 2026-07-07 v2：删掉顶部倒计时显示（hourglass + Punishing + mm:ss）—— 与
/// [PKArenaView](PKArenaView.swift) 的 `PKBattleCountdown(isPunishment:true)` 显示 punishRemainingSeconds
/// 重复，用户反馈"punish 时上方多了个倒计时"。倒计时由 progressBar 下方 Countdown 单一负责，
/// 本 overlay 只承担 "End Punish 按钮" 业务功能。
struct PKPunishingOverlay: View {
    @ObservedObject var store: PKStore

    var body: some View {
        if store.state == .punishing {
            VStack(spacing: 0) {
                Spacer()
                Button {
                    Task { await store.endPunishActive() }
                } label: {
                    Text(L10n.PK.punishingEnd)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 10)
                        .background(.gray.opacity(0.7), in: Capsule())
                }
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
