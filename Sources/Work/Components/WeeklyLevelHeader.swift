import SwiftUI

/// 顶部周等级区：头像 + 等级徽章 + 分数 + 彩虹进度条 + 段位刻度 + Detail。
struct WeeklyLevelHeader: View {
    @ObservedObject var vm: WorkViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                avatar
                levelBadge
                Spacer(minLength: 0)
            }

            scoreLine

            HStack(alignment: .center, spacing: 10) {
                rainbowBar
                OutlineChevronPill(title: L10n.workDetail)
            }

            tierRow
        }
    }

    // MARK: - 头像（暂无资源，渲染渐变环 + 占位）
    private var avatar: some View {
        Circle()
            .fill(Theme.Palette.cardFill)
            .frame(width: 48, height: 48)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .overlay {
                Circle().strokeBorder(Theme.Gradients.avatarRing, lineWidth: 2.5)
            }
            .accessibilityHidden(true)
    }

    // MARK: - 等级徽章
    private var levelBadge: some View {
        HStack(spacing: 6) {
            Text(L10n.workWeeklyLevel)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(vm.weeklyLevel)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Theme.Palette.accentYellow)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.Gradients.levelBadge)
        .clipShape(Capsule())
    }

    // MARK: - 分数行
    private var scoreLine: some View {
        // "Score:" 与括号说明为次要灰，主分数高亮白 —— 拆两段本地化避免整句硬编码。
        // 用 Text 插值组合而非 `+` 拼接；片段着色用 foregroundColor（iOS 16 下唯一返回 Text 的变体）。
        let prefix = Text(L10n.workScorePrefix).foregroundColor(Theme.Palette.textSecondary)
        let score = Text("\(vm.score)").foregroundColor(.white).bold()
        let need = Text(String(format: L10n.workNeedMoreFormat, vm.scoreToNextLevel))
            .foregroundColor(Theme.Palette.textSecondary)
        return Text("\(prefix)\(score) \(need)")
            .font(Theme.Typography.score)
    }

    // MARK: - 彩虹进度条（段位光谱，装饰性）
    private var rainbowBar: some View {
        Capsule()
            .fill(Theme.Gradients.rainbow)
            .frame(height: 7)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    // MARK: - 段位刻度
    private var tierRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(vm.tiers.enumerated()), id: \.offset) { index, tier in
                Text(tier)
                    .font(Theme.Typography.tier)
                    .foregroundStyle(color(for: index))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 段位着色：取光谱对应色；当前等级用满色，其余略降透明度。
    private func color(for index: Int) -> Color {
        let spectrum = Theme.Gradients.tierSpectrum
        let base = spectrum[min(index, spectrum.count - 1)]
        let isCurrent = vm.tiers[index] == vm.weeklyLevel
        return isCurrent ? base : base.opacity(0.55)
    }
}
