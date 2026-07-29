import SwiftUI

/// PK 顶部比分卡（对齐 H5 audienceHud.vue，等待/进行中复用同一结构）
///
/// 视觉对齐 H5：
/// - 标题 "Battle Team" + ? 规则按钮
/// - 领先方文案："Red/Blue Leading +XXK"（对齐 audienceHud.vue 的 leadingTeam + leadingDeltaText）
/// - 红蓝对抗进度条（clamp 20-80% 避免极端分数动画跑出可视区）
/// - 倒计时 mm:ss 紧贴进度条上方（dir=ltr 语义 · SwiftUI 数字默认 LTR）
/// - 红蓝分数取整 Math.round 与安卓 Long 口径对齐
struct PartyBattleRunningHud: View {
    enum Appearance: Equatable {
        case selecting
        case running
    }

    @ObservedObject var store: PartyBattleStore
    let appearance: Appearance
    let onRuleTap: (() -> Void)?

    init(
        store: PartyBattleStore,
        appearance: Appearance = .running,
        onRuleTap: (() -> Void)? = nil
    ) {
        self.store = store
        self.appearance = appearance
        self.onRuleTap = onRuleTap
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            progressWithScores
                .padding(.top, -20)
        }
        .padding(.horizontal, 8)
        // 77pt 固定 HUD 内为标题与进度条预留 10pt 间距，不能再额外占用垂直内边距。
        .padding(.vertical, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selectingCardGradient)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Text(L10n.Party.Battle.team)
                .font(.system(size: 14, weight: .bold))
                .italic()
                .foregroundColor(.white)
            if let onRuleTap = onRuleTap {
                Button(action: onRuleTap) {
                    Image("partyPkRule")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            leadingTeamText
        }
    }

    /// 领先方文案（对齐 H5 audienceHud.vue :101-110）
    @ViewBuilder
    private var leadingTeamText: some View {
        let delta = leadingDelta
        if delta > 0 {
            HStack(spacing: 3) {
                if leadingTeam == 1 {
                    Text(L10n.Party.Battle.giftTabRed).font(.caption2).bold().foregroundColor(Color(red: 1.0, green: 0.15, blue: 0.7))
                } else if leadingTeam == 2 {
                    Text(L10n.Party.Battle.giftTabBlue).font(.caption2).bold().foregroundColor(Color(red: 0.05, green: 0.43, blue: 1.0))
                }
                Text(L10n.Party.Battle.leading).font(.caption2).foregroundColor(.white)
                Text(deltaText(delta)).font(.caption2).bold().foregroundColor(.yellow)
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(.white.opacity(0.08))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var progressWithScores: some View {
        VStack(spacing: 0) {
            // 倒计时底边与进度条顶边相接，和 H5 HUD 一致，不保留额外间距。
            countdownLabel

            GeometryReader { geo in
                ZStack {
                    progressBar
                    HStack {
                        scoreLabel(score: redInt, leadingIcon: true)
                        Spacer()
                        Spacer()
                        scoreLabel(score: blueInt, leadingIcon: false)
                    }
                    .padding(.horizontal, 12)

                    // 动图始终锚定红蓝进度的视觉分界线，而不是固定在进度条中心。
                    AnimatedGIFView(
                        name: progressAnimationName,
                        fileExtension: "webp",
                        fallbackImageName: "partyPkBattleMarker",
                        remoteURL: progressAnimationURL
                    )
                        .frame(width: 28, height: 28)
                        .position(x: geo.size.width * pkProgress / 100, y: geo.size.height / 2)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 20)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [Color(red: 1.0, green: 0.0, blue: 0.56), Color(red: 1.0, green: 0.24, blue: 0.77)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: geo.size.width * pkProgress / 100)
                Rectangle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.13, green: 0.60, blue: 0.99), Color(red: 0.0, green: 0.33, blue: 1.0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
            }
        }
        .frame(height: 20)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .overlay {
            Image("partyPkProgressOverlay")
                .resizable()
                .scaledToFill()
                .clipShape(Capsule())
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func scoreLabel(score: Int, leadingIcon: Bool) -> some View {
        HStack(spacing: 3) {
            if leadingIcon { pkLogo }
            Text("\(score)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 1.0, green: 0.90, blue: 0.0))
            if !leadingIcon { pkLogo }
        }
    }

    private var pkLogo: some View {
        Image("partyPkLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
    }

    private var countdownLabel: some View {
        Text(mmss(store.leftSec))
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(Color(red: 1.0, green: 0.90, blue: 0.0))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.48))
            .clipShape(UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 12,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: 12
            )))
            .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Computed（对齐 H5 audienceHud.vue :26-90）

    /// 红队分数取整（H5 Math.round，与安卓 Long 口径对齐）
    private var redInt: Int { Int(store.redScoreDisplay.rounded()) }
    private var blueInt: Int { Int(store.blueScoreDisplay.rounded()) }

    /// 领先方（按取整后比较，取整相同不显示领先标签）
    private var leadingTeam: Int? {
        if redInt > blueInt { return 1 }
        if blueInt > redInt { return 2 }
        return nil
    }

    /// 领先差值（基于取整分数）
    private var leadingDelta: Int { abs(redInt - blueInt) }

    /// 红队占比（clamp 20-80% 避免极端分数动画跑出可视区）
    private var pkProgress: Double {
        let total = store.redScoreDisplay + store.blueScoreDisplay
        guard total > 0 else { return 50 }
        let progress = store.redScoreDisplay / total * 100
        return min(max(progress, 20), 80)
    }

    /// 对齐 H5 audienceHud：中立用户固定展示领先动画；参战用户按自己队伍的分数关系判胜负。
    private var progressAnimationName: String {
        if store.redScoreDisplay == store.blueScoreDisplay { return "pk-progress-draw" }
        guard let myTeam = currentUserTeam else { return "pk-progress-win" }
        let redLeading = store.redScoreDisplay > store.blueScoreDisplay
        let isLeading = myTeam == 1 ? redLeading : !redLeading
        return isLeading ? "pk-progress-win" : "pk-progress-loss"
    }

    private var currentUserTeam: Int? {
        guard let uid = SessionStore.shared.user?.userId, uid > 0 else { return nil }
        let userId = Int64(uid)
        if store.redMembers.contains(where: { $0.uid == userId }) { return 1 }
        if store.blueMembers.contains(where: { $0.uid == userId }) { return 2 }
        return nil
    }

    private var progressAnimationURL: URL? {
        URL(string: "https://img.hnhily.link/appId/pk/\(progressAnimationName).webp")
    }

    /// K/M 差值格式化（对齐 audienceHud.vue :75-82）
    private func deltaText(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000 {
            return String(format: "%gM", (d / 1_000_000 * 100).rounded() / 100)
        }
        if d >= 1000 {
            return String(format: "%gK", (d / 1000 * 100).rounded() / 100)
        }
        return "\(n)"
    }

    private func mmss(_ sec: Int) -> String {
        let m = max(0, sec) / 60
        let s = max(0, sec) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var selectingCardGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.66, green: 0.0, blue: 0.42),
                Color(red: 0.46, green: 0.08, blue: 0.43),
                Color(red: 0.0, green: 0.35, blue: 0.50),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
