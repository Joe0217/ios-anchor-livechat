import SwiftUI

/// 单任务行。设计稿视觉分 3 分支:
///
/// - **simple** (Total Points 内):任务名 + (progress/target) + 💎+reward,**纯堆叠无卡片**
/// - **progress** (Active Tycoon Task 内):深色内嵌卡 + 任务名 + 灰描述 + 粉紫→红进度条 + 右侧 💎 X/Y
/// - **actionable** (Live stream 内):深色内嵌卡 + 任务名 + Claim/Go 按钮 + 灰描述 + 进度 + **独立深色底 bar**(💎+reward)
///
/// 多档 tier (Weekly revenue) 由 [TaskWeeklyTierBar] 承载,不走本组件。
struct TaskTierRow: View {
    let task: TaskItemVO
    let displayMode: DisplayMode
    let isClaimingTier: (Int) -> Bool
    let isClaimingAll: Bool
    let onClaim: (Int) -> Void
    let onClaimAll: () -> Void

    enum DisplayMode { case simple, progress, actionable }

    var body: some View {
        switch displayMode {
        case .simple:      simpleRow
        case .progress:    progressRow
        case .actionable:  actionableRow
        }
    }

    // MARK: - Simple(Total Points):纯堆叠

    private var simpleRow: some View {
        let tier = task.currentTier
        let target = tier?.threshold ?? 0
        let reward = tier?.rewardValue ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            taskTitle
            Text("(\(task.progress)/\(target))")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 4) {
                rewardIcon(for: tier)
                Text("+\(reward)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFFCC00))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Progress(Active Tycoon Task):深色内嵌卡 + 进度条 + 💎 X/Y
    // 外层加 `.frame(maxWidth: .infinity)` 让内嵌卡宽度铺满父 VStack,避免居中显示

    private var progressRow: some View {
        let target = task.currentTier?.threshold ?? 0
        let ratio: CGFloat = target > 0 ? min(1, CGFloat(task.progress) / CGFloat(target)) : 0
        return VStack(alignment: .leading, spacing: 8) {
            taskTitle
            if let desc = task.taskDesc, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 8)
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * ratio, height: 8)
                    }
                }
                .frame(height: 8)
                HStack(spacing: 4) {
                    rewardIcon(for: task.currentTier)
                    Text("\(task.progress)/\(target)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .fixedSize()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x1E1230))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actionable(Live stream):Claim/Go 按钮 + 独立底 bar
    // 外层加 `.frame(maxWidth: .infinity)` 让内嵌卡宽度铺满父 VStack

    private var actionableRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    taskTitle
                    if let desc = task.taskDesc, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(2)
                    }
                    let target = task.currentTier?.threshold ?? 0
                    Text("(\(task.progress)/\(target))")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 12)
                claimOrGoButton
            }

            // 底部独立深黑奖励 bar
            let reward = task.currentTier?.rewardValue ?? 0
            HStack(spacing: 6) {
                Spacer()
                rewardIcon(for: task.currentTier)
                Text("+\(reward)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFFCC00))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x1E1230))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var claimOrGoButton: some View {
        if let tier = task.tiers.first(where: { $0.isClaimable }) {
            Button {
                onClaimAll()
            } label: {
                HStack(spacing: 4) {
                    if isClaimingTier(tier.tier) || isClaimingAll {
                        ProgressView().scaleEffect(0.6).tint(.white)
                    }
                    Text(L10n.taskTierClaim)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(
                    LinearGradient(colors: [Color(hex: 0xF640DC), Color(hex: 0x8515FF)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isClaimingTier(tier.tier) || isClaimingAll)
        } else {
            // H5：全部已领与未达标都不可点击，但仅全部已领时显示 Claimed。
            Text(!task.tiers.isEmpty && task.tiers.allSatisfy(\.isClaimed) ? L10n.taskTierClaimed : L10n.taskTierClaim)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    // MARK: - 通用钻石 icon(对齐 H5 主播端金橙钻切图)

    private func rewardIcon(for tier: TaskTierVO?) -> some View {
        let iconName: String
        switch tier?.rewardType {
        case 2: iconName = "homeRankDiamondPurple"
        case 6: iconName = "homeRankIntegral"
        default: iconName = "diamondYellow"
        }
        return CDNAssetImage(iconName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
    }

    private var taskTitle: some View {
        HStack(spacing: 6) {
            Text(task.taskName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            if task.derivedHasRedDot {
                Circle().fill(Color(hex: 0xFF3B30)).frame(width: 7, height: 7)
            }
        }
    }

}
