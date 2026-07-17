import SwiftUI

/// 多档水平 tier 进度条。对齐设计稿 **Weekly revenue in party rooms** 底部布局:
/// - 顶部一排 threshold 数字(1.2k / 7.5k / 13k / 28k / 59k)
/// - 中间粉红渐变横线,叠加 5 个档位圆点(未达灰 / 当前粉黄环 / 可领黄)
/// - 底部一排 钻石+奖励值(+180 / +1400 / ...)
///
/// **节点定位策略**:档位位置**平均分配**进度条宽度(x = index / (count - 1)),
/// 不按 threshold 数值比例(1.2k 到 59k 差 50 倍,按比例前 4 档会挤在最左侧)。
/// 进度条填充长度按"已达到的最大 tier 索引"派生,与档位位置一致。
struct TaskWeeklyTierBar: View {
    let task: TaskItemVO
    let isClaimingTier: (Int) -> Bool
    let onClaim: (Int) -> Void

    /// 按 tier 顺序(升序 threshold)派生的档位数组
    private var sortedTiers: [TaskTierVO] {
        task.tiers.sorted { $0.threshold < $1.threshold }
    }

    private var tierCount: Int { sortedTiers.count }

    /// 已达到的最大 tier 索引(progress ≥ threshold);-1 表示未达任何档。
    private var reachedIndex: Int {
        var idx = -1
        for (i, t) in sortedTiers.enumerated() where task.progress >= t.threshold {
            idx = i
        }
        return idx
    }

    /// 进度条填充比:填到 reachedIndex 对应档位的 x 位置(与档位对齐,视觉一致)
    private var progressRatio: CGFloat {
        guard tierCount > 1, reachedIndex >= 0 else { return 0 }
        return CGFloat(reachedIndex) / CGFloat(tierCount - 1)
    }

    /// 单档 x 位置:平均分配进度条宽度
    private func xRatio(index: Int) -> CGFloat {
        guard tierCount > 1 else { return 0 }
        return CGFloat(index) / CGFloat(tierCount - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶部 threshold 数字行(等距)—— 内左右 padding 20pt 让最左/最右档位数字不超出卡片边界
            GeometryReader { geo in
                let inset: CGFloat = 20
                let usable = max(0, geo.size.width - inset * 2)
                ZStack(alignment: .leading) {
                    ForEach(Array(sortedTiers.enumerated()), id: \.element.tier) { i, t in
                        Text(formatK(t.threshold))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                            .position(x: inset + usable * xRatio(index: i), y: 8)
                    }
                }
            }
            .frame(height: 16)

            // 中间进度轨道 + 圆点(等距,同 inset)
            GeometryReader { geo in
                let inset: CGFloat = 20
                let usable = max(0, geo.size.width - inset * 2)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: usable, height: 4)
                        .offset(x: inset)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(hex: 0xF640DC), Color(hex: 0xE40132)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: usable * progressRatio, height: 4)
                        .offset(x: inset)

                    ForEach(Array(sortedTiers.enumerated()), id: \.element.tier) { i, t in
                        tierDot(t)
                            .position(x: inset + usable * xRatio(index: i), y: 2)
                    }
                }
            }
            .frame(height: 4)
            .padding(.vertical, 6)

            // 底部 reward chip 行(等距,同 inset;内容超边界通过 HStack 内 fixedSize 收敛)
            GeometryReader { geo in
                let inset: CGFloat = 20
                let usable = max(0, geo.size.width - inset * 2)
                ZStack(alignment: .leading) {
                    ForEach(Array(sortedTiers.enumerated()), id: \.element.tier) { i, t in
                        HStack(spacing: 3) {
                            Image("coins")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 12, height: 12)
                            Text("+\(t.rewardValue)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xF9991A))
                        }
                        .fixedSize()
                        .position(x: inset + usable * xRatio(index: i), y: 10)
                    }
                }
            }
            .frame(height: 20)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func tierDot(_ t: TaskTierVO) -> some View {
        // 3 态切图:已领用 current(粉黄环)/ 可领用 claimable(粉紫圆)/ 未达用 locked(深紫圆)
        let imageName: String = t.isClaimed
            ? "taskTierDotCurrent"
            : (t.isClaimable ? "taskTierDotClaimable" : "taskTierDotLocked")
        Button {
            guard t.isClaimable else { return }
            onClaim(t.tier)
        } label: {
            Image(imageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .overlay {
                    if isClaimingTier(t.tier) {
                        ProgressView().scaleEffect(0.4).tint(.white)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!t.isClaimable || isClaimingTier(t.tier))
    }

    /// 数字缩略:1200 → "1.2k",7500 → "7.5k",59000 → "59k"
    private func formatK(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let v = Double(n) / 1000.0
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(v))k"
        }
        return String(format: "%.1fk", v)
    }
}
